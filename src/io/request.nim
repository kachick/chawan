import options
import streams
import strutils
import tables

import bindings/quickjs
import js/javascript
import types/formdata
import types/url
import utils/twtstr

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

  Headers* = ref object
    table* {.jsget.}: Table[string, seq[string]]

proc js_url(this: Request): string {.jsfget: "url".} =
  return $this.url

proc js_referrer(this: Request): string {.jsfget: "referrer".} =
  return $this.referer

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

proc fill(headers: Headers, ctx: JSContext, val: JSValue) =
  if isSequence(ctx, val):
    let x = fromJS[seq[(string, string)]](ctx, val)
    if x.isSome:
      for (k, v) in x.get:
        if k in headers.table:
          headers.table[k].add(v)
        else:
          headers.table[k] = @[v]
  else:
    let x = fromJS[Table[string, string]](ctx, val)
    if x.isSome:
      for k, v in x.get:
        if k in headers.table:
          headers.table[k].add(v)
        else:
          headers.table[k] = @[v]

func newHeaders*(): Headers =
  new(result)

func newHeaders*(ctx: JSContext, obj = none(JSValue)): Headers {.jsctor.} =
  new(result)
  if obj.isSome:
    result.fill(ctx, obj.get)

func newHeaders*(table: Table[string, string]): Headers =
  new(result)
  for k, v in table:
    let k = k.toHeaderCase()
    if k in result.table:
      result.table[k].add(v)
    else:
      result.table[k] = @[v]

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

#TODO resource as Request
#TODO init as an actual dictionary
func newRequest*(ctx: JSContext, resource: string,
    init = none(JSValue)): Request {.jserr, jsctor.} =
  let x = parseURL(resource)
  if x.isNone:
    JS_ERR JS_TypeError, resource & " is not a valid URL."
  if x.get.username != "" or x.get.password != "":
    JS_ERR JS_TypeError, resource & " is not a valid URL."
  let url = x.get
  let fallbackMode = some(RequestMode.CORS) #TODO none if resource is request
  var httpMethod = HTTP_GET
  var body = opt(string)
  var credentials = CredentialsMode.SAME_ORIGIN
  var mode = fallbackMode.get(RequestMode.NO_CORS)
  let hl = newHeaders()
  var proxyUrl: Opt[URL]
  var multipart: Opt[FormData]
  #TODO fallback mode, origin, window, request mode, ...
  if init.isSome:
    let init = init.get
    httpMethod = fromJS[HttpMethod](ctx,
      JS_GetPropertyStr(ctx, init, "method")).get(HTTP_GET)
    let bodyProp = JS_GetPropertyStr(ctx, init, "body")
    if not JS_IsNull(bodyProp) and not JS_IsUndefined(bodyProp):
      # ????
      multipart = fromJS[FormData](ctx, bodyProp)
      if multipart.isNone:
        body = fromJS[string](ctx, bodyProp)
    #TODO inputbody
    if (multipart.isSome or body.isSome) and
        httpMethod in {HTTP_GET, HTTP_HEAD}:
      JS_ERR JS_TypeError, "HEAD or GET Request cannot have a body."
    let jheaders = JS_GetPropertyStr(ctx, init, "headers")
    hl.fill(ctx, jheaders)
    credentials = fromJS[CredentialsMode](ctx, JS_GetPropertyStr(ctx, init,
      "credentials")).get(credentials)
    mode = fromJS[RequestMode](ctx, JS_GetPropertyStr(ctx, init, "mode"))
      .get(mode)
    #TODO find a standard compatible way to implement this
    proxyUrl = fromJS[URL](ctx, JS_GetPropertyStr(ctx, init, "proxyUrl"))
  return newRequest(url, httpMethod, hl, body, multipart, mode, credentials,
    proxy = proxyUrl.get(nil))

proc add*(headers: var Headers, k, v: string) =
  let k = k.toHeaderCase()
  if k notin headers.table:
    headers.table[k] = @[v]
  else:
    headers.table[k].add(v)

proc `[]=`*(headers: var Headers, k, v: string) =
  headers.table[k.toHeaderCase()] = @[v]

func getOrDefault*(headers: Headers, k: string, default = ""): string =
  let k = k.toHeaderCase()
  if k in headers.table:
    headers.table[k][0]
  else:
    default

func credentialsMode*(attribute: CORSAttribute): CredentialsMode =
  case attribute
  of NO_CORS, ANONYMOUS:
    return SAME_ORIGIN
  of USE_CREDENTIALS:
    return INCLUDE

proc addRequestModule*(ctx: JSContext) =
  ctx.registerType(Request)
  ctx.registerType(Headers)
