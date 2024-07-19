import std/strutils
import std/tables

import chagashi/charset
import chagashi/decoder
import img/bitmap
import io/posixstream
import io/promise
import io/socketstream
import loader/headers
import loader/request
import monoucha/javascript
import monoucha/jserror
import monoucha/quickjs
import types/blob
import types/color
import types/opt
import types/url
import utils/mimeguess
import utils/twtstr

type
  ResponseType* = enum
    rtDefault = "default"
    rtBasic = "basic"
    rtCors = "cors"
    rtError = "error"
    rtOpaque = "opaque"
    rtOpaquedirect = "opaqueredirect"

  #TODO fully implement headers guards
  HeadersGuard* = enum
    hgImmutable = "immutable"
    hgRequest = "request"
    hgRequestNoCors = "request-no-cors"
    hgResponse = "response"
    hgNone = "none"

  ResponseFlag* = enum
    rfAborted

  Response* = ref object
    responseType* {.jsget: "type".}: ResponseType
    res*: int
    body*: SocketStream
    bodyUsed* {.jsget.}: bool
    status* {.jsget.}: uint16
    headers* {.jsget.}: Headers
    headersGuard: HeadersGuard
    url*: URL #TODO should be urllist?
    unregisterFun*: proc()
    resumeFun*: proc(outputId: int)
    bodyRead*: EmptyPromise
    internalMessage*: string # should NOT be exposed to JS!
    outputId*: int
    onRead*: proc(response: Response) {.nimcall.}
    opaque*: RootRef
    flags*: set[ResponseFlag]

jsDestructor(Response)

proc newResponse*(res: int; request: Request; stream: SocketStream;
    outputId: int; status: uint16): Response =
  return Response(
    res: res,
    url: request.url,
    body: stream,
    bodyRead: EmptyPromise(),
    outputId: outputId,
    status: status
  )

func makeNetworkError*(): Response {.jsstfunc: "Response.error".} =
  #TODO use "create" function
  #TODO headers immutable
  return Response(
    res: 0,
    responseType: rtError,
    status: 0,
    headers: newHeaders(),
    headersGuard: hgImmutable,
    bodyUsed: true
  )

func sok(response: Response): bool {.jsfget: "ok".} =
  return response.status in 200u16 .. 299u16

func surl*(response: Response): string {.jsfget: "url".} =
  if response.responseType == rtError or response.url == nil:
    return ""
  return $response.url

#TODO: this should be a property of body
proc close*(response: Response) {.jsfunc.} =
  response.bodyUsed = true
  if response.unregisterFun != nil:
    response.unregisterFun()
  if response.body != nil:
    response.body.sclose()

func getCharset*(this: Response; fallback: Charset): Charset =
  if "Content-Type" notin this.headers.table:
    return fallback
  let header = this.headers.table["Content-Type"][0].toLowerAscii()
  let cs = header.getContentTypeAttr("charset").getCharset()
  if cs == CHARSET_UNKNOWN:
    return fallback
  return cs

func getContentType*(this: Response; fallback = "application/octet-stream"):
    string =
  if "Content-Type" in this.headers.table:
    let header = this.headers.table["Content-Type"][0].toLowerAscii()
    return header.until(';').strip()
  # also use DefaultGuess for container, so that local mime.types cannot
  # override buffer mime.types
  return DefaultGuess.guessContentType(this.url.pathname, fallback)

type TextOpaque = ref object of RootObj
  buf: string

const BufferSize = 4096

proc onReadText(response: Response) =
  let opaque = TextOpaque(response.opaque)
  while true:
    let olen = opaque.buf.len
    try:
      opaque.buf.setLen(olen + BufferSize)
      let n = response.body.recvData(addr opaque.buf[olen], BufferSize)
      opaque.buf.setLen(olen + n)
      if n == 0:
        break
    except ErrorAgain:
      opaque.buf.setLen(olen)
      break

proc resume*(response: Response) =
  response.resumeFun(response.outputId)
  response.resumeFun = nil

proc text*(response: Response): Promise[JSResult[string]] {.jsfunc.} =
  if response.body == nil:
    let p = newPromise[JSResult[string]]()
    p.resolve(JSResult[string].ok(""))
    return p
  if response.bodyUsed:
    let p = newPromise[JSResult[string]]()
    let err = JSResult[string]
      .err(newTypeError("Body has already been consumed"))
    p.resolve(err)
    return p
  let opaque = TextOpaque()
  response.opaque = opaque
  response.onRead = onReadText
  response.bodyUsed = true
  response.resume()
  return response.bodyRead.then(proc(): JSResult[string] =
    let charset = response.getCharset(CHARSET_UTF_8)
    ok(opaque.buf.decodeAll(charset))
  )

type BlobOpaque = ref object of RootObj
  p: pointer
  len: int
  size: int

proc onReadBlob(response: Response) =
  let opaque = BlobOpaque(response.opaque)
  while true:
    try:
      let targetLen = opaque.len + BufferSize
      if targetLen > opaque.size:
        opaque.size = targetLen
        opaque.p = realloc(opaque.p, targetLen)
      let p = cast[ptr UncheckedArray[uint8]](opaque.p)
      let n = response.body.recvData(addr p[opaque.len], BufferSize)
      opaque.len += n
      if n == 0:
        break
    except ErrorAgain:
      break

proc blob*(response: Response): Promise[JSResult[Blob]] {.jsfunc.} =
  if response.bodyUsed:
    let p = newPromise[JSResult[Blob]]()
    let err = JSResult[Blob].err(newTypeError("Body has already been consumed"))
    p.resolve(err)
    return p
  let opaque = BlobOpaque()
  response.opaque = opaque
  response.onRead = onReadBlob
  response.bodyUsed = true
  response.resume()
  let contentType = response.getContentType()
  return response.bodyRead.then(proc(): JSResult[Blob] =
    let p = realloc(opaque.p, opaque.len)
    opaque.p = nil
    if p == nil:
      return ok(newBlob(nil, 0, contentType, nil))
    ok(newBlob(p, opaque.len, contentType, deallocBlob))
  )

type BitmapOpaque = ref object of RootObj
  bmp: Bitmap
  idx: int

proc onReadBitmap(response: Response) =
  let opaque = BitmapOpaque(response.opaque)
  let bmp = opaque.bmp
  while true:
    try:
      let p = cast[ptr UncheckedArray[uint8]](addr bmp.px[0])
      let L = bmp.px.len * 4 - opaque.idx
      let n = response.body.recvData(addr p[opaque.idx], L)
      opaque.idx += n
      if n == 0:
        break
    except ErrorAgain:
      break

proc saveToBitmap*(response: Response; bmp: Bitmap): EmptyPromise =
  assert not response.bodyUsed
  let opaque = BitmapOpaque(bmp: bmp, idx: 0)
  let size = bmp.width * bmp.height
  bmp.px = cast[seq[RGBAColorBE]](newSeqUninitialized[uint32](size))
  response.opaque = opaque
  response.onRead = onReadBitmap
  response.bodyUsed = true
  response.resume()
  return response.bodyRead

proc json(ctx: JSContext; this: Response): Promise[JSResult[JSValue]]
    {.jsfunc.} =
  return this.text().then(proc(s: JSResult[string]): JSResult[JSValue] =
    let s = ?s
    return ok(JS_ParseJSON(ctx, cstring(s), csize_t(s.len), cstring"<input>"))
  )

proc addResponseModule*(ctx: JSContext) =
  ctx.registerType(Response)
