import std/strutils
import std/tables

import chagashi/charset
import chagashi/decoder
import io/promise
import io/socketstream
import loader/headers
import loader/request
import monoucha/javascript
import monoucha/jserror
import monoucha/quickjs
import types/blob
import types/opt
import types/url
import utils/mimeguess
import utils/twtstr

type
  ResponseType* = enum
    TYPE_DEFAULT = "default"
    TYPE_BASIC = "basic"
    TYPE_CORS = "cors"
    TYPE_ERROR = "error"
    TYPE_OPAQUE = "opaque"
    TYPE_OPAQUEREDIRECT = "opaqueredirect"

  #TODO fully implement headers guards
  HeadersGuard* = enum
    hgImmutable = "immutable"
    hgRequest = "request"
    hgRequestNoCors = "request-no-cors"
    hgResponse = "response"
    hgNone = "none"

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
    bodyRead*: Promise[string]
    internalMessage*: string # should NOT be exposed to JS!
    outputId*: int

jsDestructor(Response)

proc newResponse*(res: int; request: Request; stream: SocketStream): Response =
  return Response(
    res: res,
    url: request.url,
    body: stream,
    bodyRead: Promise[string](),
    outputId: -1
  )

func makeNetworkError*(): Response {.jsstfunc: "Response.error".} =
  #TODO use "create" function
  #TODO headers immutable
  return Response(
    res: 0,
    responseType: TYPE_ERROR,
    status: 0,
    headers: newHeaders(),
    headersGuard: hgImmutable
  )

func sok(response: Response): bool {.jsfget: "ok".} =
  return response.status in 200u16 .. 299u16

func surl(response: Response): string {.jsfget: "url".} =
  if response.responseType == TYPE_ERROR:
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

func getContentType*(this: Response): string =
  if "Content-Type" in this.headers.table:
    let header = this.headers.table["Content-Type"][0].toLowerAscii()
    return header.until(';').strip()
  # also use DefaultGuess for container, so that local mime.types cannot
  # override buffer mime.types
  return DefaultGuess.guessContentType(this.url.pathname)

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
  let bodyRead = response.bodyRead
  response.bodyRead = nil
  return bodyRead.then(proc(s: string): JSResult[string] =
    let charset = response.getCharset(CHARSET_UTF_8)
    #TODO this is inefficient
    # maybe add a JS type that turns a seq[char] into JS strings
    ok(s.decodeAll(charset))
  )

proc blob*(response: Response): Promise[JSResult[Blob]] {.jsfunc.} =
  if response.bodyRead == nil:
    let p = newPromise[JSResult[Blob]]()
    let err = JSResult[Blob]
      .err(newTypeError("Body has already been consumed"))
    p.resolve(err)
    return p
  let bodyRead = response.bodyRead
  response.bodyRead = nil
  let contentType = response.getContentType()
  return bodyRead.then(proc(s: string): JSResult[Blob] =
    if s.len == 0:
      return ok(newBlob(nil, 0, contentType, nil))
    GC_ref(s)
    let deallocFun = proc() =
      GC_unref(s)
    let blob = newBlob(unsafeAddr s[0], s.len, contentType, deallocFun)
    ok(blob))

proc json(ctx: JSContext; this: Response): Promise[JSResult[JSValue]]
    {.jsfunc.} =
  return this.text().then(proc(s: JSResult[string]): JSResult[JSValue] =
    let s = ?s
    return ok(JS_ParseJSON(ctx, cstring(s), cast[csize_t](s.len),
      cstring"<input>")))

proc addResponseModule*(ctx: JSContext) =
  ctx.registerType(Response)
