import options
import streams
import strutils
import tables

import bindings/quickjs
import io/headers
import js/javascript
import types/formdata
import types/url

type
  HttpMethod* = enum
    HTTP_CONNECT = "CONNECT"
    HTTP_DELETE = "DELETE"
    HTTP_GET = "GET"
    HTTP_HEAD = "HEAD"
    HTTP_OPTIONS = "OPTIONS"
    HTTP_PATCH = "PATCH"
    HTTP_POST = "POST"
    HTTP_PUT = "PUT"
    HTTP_TRACE = "TRACE"

  RequestMode* = enum
    NO_CORS = "no-cors"
    SAME_ORIGIN = "same-origin"
    CORS = "cors"
    NAVIGATE = "navigate"
    WEBSOCKET = "websocket"

  RequestDestination* = enum
    NO_DESTINATION = ""
    AUDIO = "audio"
    AUDIOWORKLET = "audioworklet"
    DOCUMENT = "document"
    EMBED = "embed"
    FONT = "font"
    FRAME = "frame"
    IFRAME = "iframe"
    IMAGE = "image"
    MANIFEST = "manifest"
    OBJECT = "object"
    PAINTWORKLET = "paintworklet"
    REPORT = "report"
    SCRIPT = "script"
    SERVICEWORKER = "serviceworker"
    SHAREDWORKER = "sharedworker"
    STYLE = "style"
    TRACK = "track"
    WORKER = "worker"
    XSLT = "xslt"

  CredentialsMode* = enum
    SAME_ORIGIN = "same-origin"
    OMIT = "omit"
    INCLUDE = "include"

  CORSAttribute* = enum
    NO_CORS = "no-cors"
    ANONYMOUS = "anonymous"
    USE_CREDENTIALS = "use-credentials"

type
  Request* = ref RequestObj
  RequestObj* = object
    httpmethod*: HttpMethod
    url*: Url
    headers* {.jsget.}: Headers
    body*: Opt[string]
    multipart*: Opt[FormData]
    referer*: URL
    mode* {.jsget.}: RequestMode
    destination* {.jsget.}: RequestDestination
    credentialsMode* {.jsget.}: CredentialsMode
    proxy*: URL #TODO do something with this
 
  ReadableStream* = ref object of Stream
    isource*: Stream
    buf: string
    isend: bool

jsDestructor(Request)

proc js_url(this: Request): string {.jsfget: "url".} =
  return $this.url

#TODO pretty sure this is incorrect
proc js_referrer(this: Request): string {.jsfget: "referrer".} =
  if this.referer != nil:
    return $this.referer
  return ""

iterator pairs*(headers: Headers): (string, string) =
  for k, vs in headers.table:
    for v in vs:
      yield (k, v)

proc rsReadData(s: Stream, buffer: pointer, bufLen: int): int =
  var s = ReadableStream(s)
  if s.atEnd:
    return 0
  while s.buf.len < bufLen:
    var len: int
    s.isource.read(len)
    if len == 0:
      result = s.buf.len
      copyMem(buffer, addr(s.buf[0]), result)
      s.buf = s.buf.substr(result)
      s.isend = true
      return
    var nbuf: string
    s.isource.readStr(len, nbuf)
    s.buf &= nbuf
  assert s.buf.len >= bufLen
  result = bufLen
  copyMem(buffer, addr(s.buf[0]), result)
  s.buf = s.buf.substr(result)
  if s.buf.len == 0:
    var len: int
    s.isource.read(len)
    if len == 0:
      s.isend = true
    else:
      s.isource.readStr(len, s.buf)

proc rsAtEnd(s: Stream): bool =
  ReadableStream(s).isend

proc rsClose(s: Stream) = {.cast(tags: [WriteIOEffect]).}: #TODO TODO TODO ew.
  var s = ReadableStream(s)
  if s.isend: return
  s.buf = ""
  while true:
    var len: int
    s.isource.read(len)
    if len == 0:
      s.isend = true
      break
    s.isource.setPosition(s.isource.getPosition() + len)

proc newReadableStream*(isource: Stream): ReadableStream =
  new(result)
  result.isource = isource
  result.readDataImpl = rsReadData
  result.atEndImpl = rsAtEnd
  result.closeImpl = rsClose
  var len: int
  result.isource.read(len)
  if len == 0:
    result.isend = true
  else:
    result.isource.readStr(len, result.buf)

func newRequest*(url: URL, httpmethod = HTTP_GET, headers = newHeaders(),
    body = opt(string), multipart = opt(FormData), mode = RequestMode.NO_CORS,
    credentialsMode = CredentialsMode.SAME_ORIGIN,
    destination = RequestDestination.NO_DESTINATION, proxy: URL = nil): Request =
  return Request(
    url: url,
    httpmethod: httpmethod,
    headers: headers,
    body: body,
    multipart: multipart,
    mode: mode,
    credentialsMode: credentialsMode,
    destination: destination,
    proxy: proxy
  )

func newRequest*(url: URL, httpmethod = HTTP_GET,
    headers: seq[(string, string)] = @[], body = opt(string),
    multipart = opt(FormData), mode = RequestMode.NO_CORS, proxy: URL = nil):
    Request =
  let hl = newHeaders()
  for pair in headers:
    let (k, v) = pair
    hl.table[k] = @[v]
  return newRequest(url, httpmethod, hl, body, multipart, mode, proxy = proxy)

func createPotentialCORSRequest*(url: URL, destination: RequestDestination, cors: CORSAttribute, fallbackFlag = false): Request =
  var mode = if cors == NO_CORS:
    RequestMode.NO_CORS
  else:
    RequestMode.CORS
  if fallbackFlag and mode == NO_CORS:
    mode = SAME_ORIGIN
  let credentialsMode = if cors == ANONYMOUS:
    CredentialsMode.SAME_ORIGIN
  else: CredentialsMode.INCLUDE
  return newRequest(url, destination = destination, mode = mode, credentialsMode = credentialsMode)

#TODO init as an actual dictionary
func newRequest*[T: string|Request](ctx: JSContext, resource: T,
    init = none(JSValue)): Result[Request, JSError] {.jsctor.} =
  when T is string:
    let url = ?newURL(resource)
    if url.username != "" or url.password != "":
      return err(newTypeError("Input URL contains a username or password"))
    var httpMethod = HTTP_GET
    var headers = newHeaders()
    let referer: URL = nil
    var credentials = CredentialsMode.SAME_ORIGIN
    var body: Opt[string]
    var multipart: Opt[FormData]
    var proxyUrl: URL #TODO?
    let fallbackMode = opt(RequestMode.CORS)
  else:
    let url = resource.url
    var httpMethod = resource.httpMethod
    var headers = resource.headers.clone()
    let referer = resource.referer
    var credentials = resource.credentialsMode
    var body = resource.body
    var multipart = resource.multipart
    var proxyUrl = resource.proxy #TODO?
    let fallbackMode = opt(RequestMode)
    #TODO window
  var mode = fallbackMode.get(RequestMode.NO_CORS)
  let destination = NO_DESTINATION
  #TODO origin, window
  if init.isSome:
    let init = init.get
    httpMethod = fromJS[HttpMethod](ctx,
      JS_GetPropertyStr(ctx, init, "method")).get(HTTP_GET)
    let bodyProp = JS_GetPropertyStr(ctx, init, "body")
    if not JS_IsNull(bodyProp) and not JS_IsUndefined(bodyProp):
      # ????
      multipart = opt(fromJS[FormData](ctx, bodyProp))
      if multipart.isNone:
        body = opt(fromJS[string](ctx, bodyProp))
    #TODO inputbody
    if (multipart.isSome or body.isSome) and
        httpMethod in {HTTP_GET, HTTP_HEAD}:
      return err(newTypeError("HEAD or GET Request cannot have a body."))
    let jheaders = JS_GetPropertyStr(ctx, init, "headers")
    headers.fill(ctx, jheaders)
    credentials = fromJS[CredentialsMode](ctx, JS_GetPropertyStr(ctx, init,
      "credentials")).get(credentials)
    mode = fromJS[RequestMode](ctx, JS_GetPropertyStr(ctx, init, "mode"))
      .get(mode)
    #TODO find a standard compatible way to implement this
    let proxyUrlProp = JS_GetPropertyStr(ctx, init, "proxyUrl")
    proxyUrl = fromJS[URL](ctx, proxyUrlProp).get(nil)
  return ok(Request(
    url: url,
    httpmethod: httpmethod,
    headers: headers,
    body: body,
    multipart: multipart,
    mode: mode,
    credentialsMode: credentials,
    destination: destination,
    proxy: proxyUrl,
    referer: referer
  ))

func credentialsMode*(attribute: CORSAttribute): CredentialsMode =
  case attribute
  of NO_CORS, ANONYMOUS:
    return SAME_ORIGIN
  of USE_CREDENTIALS:
    return INCLUDE

proc addRequestModule*(ctx: JSContext) =
  ctx.registerType(Request)
