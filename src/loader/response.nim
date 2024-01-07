import std/streams
import std/unicode

import bindings/quickjs
import io/promise
import js/error
import js/javascript
import loader/headers
import loader/request
import types/blob
import types/url

import chakasu/charset
import chakasu/decoderstream
import chakasu/encoderstream

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
    GUARD_IMMUTABLE = "immutable"
    GUARD_REQUEST = "request"
    GUARD_REQUEST_NO_CORS = "request-no-cors"
    GUARD_RESPONSE = "response"
    GUARD_NONE = "none"

  Response* = ref object
    responseType* {.jsget: "type".}: ResponseType
    res*: int
    fd*: int
    body*: Stream
    bodyUsed* {.jsget.}: bool
    contentType*: string
    status* {.jsget.}: uint16
    headers* {.jsget.}: Headers
    headersGuard: HeadersGuard
    redirect*: Request
    url*: URL #TODO should be urllist?
    unregisterFun*: proc()
    bodyRead*: Promise[string]
    charset*: Charset
    internalMessage*: string # should NOT be exposed to JS!

jsDestructor(Response)

proc newResponse*(res: int, request: Request, fd = -1, stream: Stream = nil):
    Response =
  return Response(
    res: res,
    url: request.url,
    body: stream,
    bodyRead: Promise[string](),
    fd: fd
  )

func makeNetworkError*(): Response =
  #TODO use "create" function
  #TODO headers immutable
  return Response(
    res: 0,
    responseType: TYPE_ERROR,
    status: 0,
    headers: newHeaders(),
    headersGuard: GUARD_IMMUTABLE
  )

proc error(): Response {.jsstfunc: "Response".} =
  return makeNetworkError()

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
    response.body.close()

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
    let cs = if response.charset == CHARSET_UNKNOWN:
      CHARSET_UTF_8
    else:
      response.charset
    if cs == CHARSET_UTF_8 and s.validateUtf8() == -1:
      ok(s)
    else:
      let ss = newStringStream(s)
      let ds = newDecoderStream(ss, cs)
      let es = newEncoderStream(ds, CHARSET_UTF_8)
      return ok(es.readAll())
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
  return bodyRead.then(proc(s: string): JSResult[Blob] =
    if s.len == 0:
      return ok(newBlob(nil, 0, response.contentType, nil))
    GC_ref(s)
    let deallocFun = proc() =
      GC_unref(s)
    let blob = newBlob(unsafeAddr s[0], s.len, response.contentType, deallocFun)
    ok(blob))

proc json(ctx: JSContext, this: Response): Promise[JSResult[JSValue]]
    {.jsfunc.} =
  return this.text().then(proc(s: JSResult[string]): JSResult[JSValue] =
    let s = ?s
    return ok(JS_ParseJSON(ctx, cstring(s), cast[csize_t](s.len),
      cstring"<input>")))

proc addResponseModule*(ctx: JSContext) =
  ctx.registerType(Response)
