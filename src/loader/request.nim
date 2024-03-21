import std/options
import std/strutils
import std/tables

import bindings/quickjs
import js/error
import js/fromjs
import js/javascript
import js/jstypes
import loader/headers
import types/blob
import types/formdata
import types/referrer
import types/url

type
  HttpMethod* = enum
    HTTP_GET = "GET"
    HTTP_CONNECT = "CONNECT"
    HTTP_DELETE = "DELETE"
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
    JSON = "json"
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
    httpMethod*: HttpMethod
    url*: URL
    headers* {.jsget.}: Headers
    body*: Opt[string]
    multipart*: Opt[FormData]
    referrer*: URL
    mode* {.jsget.}: RequestMode
    destination* {.jsget.}: RequestDestination
    credentialsMode* {.jsget.}: CredentialsMode
    proxy*: URL #TODO do something with this
    # when set to true, the loader will not write data from the body (not
    # headers!) into the output until a resume is received.
    suspended*: bool
    # if defaultHeadersSet is set, then loader will not set default headers
    # for the request if it was received from the pager. (this is used when
    # starting requests for new buffers.)
    defaultHeadersSet*: bool

jsDestructor(Request)

proc js_url(this: Request): string {.jsfget: "url".} =
  return $this.url

#TODO pretty sure this is incorrect
proc js_referrer(this: Request): string {.jsfget: "referrer".} =
  if this.referrer != nil:
    return $this.referrer
  return ""

iterator pairs*(headers: Headers): (string, string) =
  for k, vs in headers.table:
    for v in vs:
      yield (k, v)

func newRequest*(url: URL; httpMethod = HTTP_GET; headers = newHeaders();
    body = opt(string); multipart = opt(FormData); mode = RequestMode.NO_CORS;
    credentialsMode = CredentialsMode.SAME_ORIGIN;
    destination = RequestDestination.NO_DESTINATION; proxy: URL = nil;
    referrer: URL = nil; suspended = false): Request =
  return Request(
    url: url,
    httpMethod: httpMethod,
    headers: headers,
    body: body,
    multipart: multipart,
    mode: mode,
    credentialsMode: credentialsMode,
    destination: destination,
    referrer: referrer,
    proxy: proxy,
    suspended: suspended
  )

func newRequest*(url: URL, httpMethod = HTTP_GET,
    headers: seq[(string, string)] = @[], body = opt(string),
    multipart = opt(FormData), mode = RequestMode.NO_CORS, proxy: URL = nil):
    Request =
  let hl = newHeaders()
  for pair in headers:
    let (k, v) = pair
    hl.table[k] = @[v]
  return newRequest(
    url,
    httpMethod,
    hl,
    body,
    multipart,
    mode,
    proxy = proxy
  )

func createPotentialCORSRequest*(url: URL, destination: RequestDestination,
    cors: CORSAttribute, fallbackFlag = false): Request =
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

type
  BodyInitType = enum
    BODY_INIT_BLOB, BODY_INIT_FORM_DATA, BODY_INIT_URL_SEARCH_PARAMS,
    BODY_INIT_STRING

  BodyInit = object
    #TODO ReadableStream, BufferSource
    case t: BodyInitType
    of BODY_INIT_BLOB:
      blob: Blob
    of BODY_INIT_FORM_DATA:
      formData: FormData
    of BODY_INIT_URL_SEARCH_PARAMS:
      searchParams: URLSearchParams
    of BODY_INIT_STRING:
      str: string

  RequestInit* = object of JSDict
    #TODO aliasing in dicts
    `method`: HttpMethod # default: GET
    headers: Opt[HeadersInit]
    body: Opt[BodyInit]
    referrer: Opt[string]
    referrerPolicy: Opt[ReferrerPolicy]
    credentials: Opt[CredentialsMode]
    proxyUrl: URL
    mode: Opt[RequestMode]

proc fromJSBodyInit(ctx: JSContext, val: JSValue): JSResult[BodyInit] =
  if JS_IsUndefined(val) or JS_IsNull(val):
    return err(nil)
  block formData:
    let x = fromJS[FormData](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: BODY_INIT_FORM_DATA, formData: x.get))
  block blob:
    let x = fromJS[Blob](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: BODY_INIT_BLOB, blob: x.get))
  block searchParams:
    let x = fromJS[URLSearchParams](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: BODY_INIT_URL_SEARCH_PARAMS, searchParams: x.get))
  block str:
    let x = fromJS[string](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: BODY_INIT_STRING, str: x.get))
  return err(newTypeError("Invalid body init type"))

func newRequest*[T: string|Request](ctx: JSContext, resource: T,
    init = none(RequestInit)): JSResult[Request] {.jsctor.} =
  when T is string:
    let url = ?newURL(resource)
    if url.username != "" or url.password != "":
      return err(newTypeError("Input URL contains a username or password"))
    var httpMethod = HTTP_GET
    var headers = newHeaders()
    let referrer: URL = nil
    var credentials = CredentialsMode.SAME_ORIGIN
    var body: Opt[string]
    var multipart: Opt[FormData]
    var proxyUrl: URL #TODO?
    let fallbackMode = opt(RequestMode.CORS)
  else:
    let url = resource.url
    var httpMethod = resource.httpMethod
    var headers = resource.headers.clone()
    let referrer = resource.referrer
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
    if mode == RequestMode.NAVIGATE:
      mode = RequestMode.SAME_ORIGIN
    #TODO flags?
    #TODO referrer
    let init = init.get
    httpMethod = init.`method`
    if init.body.isSome:
      let ibody = init.body.get
      case ibody.t
      of BODY_INIT_FORM_DATA:
        multipart = opt(ibody.formData)
      of BODY_INIT_STRING:
        body = opt(ibody.str)
      else:
        discard #TODO
      if httpMethod in {HTTP_GET, HTTP_HEAD}:
        return err(newTypeError("HEAD or GET Request cannot have a body."))
    if init.headers.isSome:
      headers.fill(init.headers.get)
    if init.credentials.isSome:
      credentials = init.credentials.get
    if init.mode.isSome:
      mode = init.mode.get
    #TODO find a standard compatible way to implement this
    proxyUrl = init.proxyUrl
  return ok(Request(
    url: url,
    httpMethod: httpMethod,
    headers: headers,
    body: body,
    multipart: multipart,
    mode: mode,
    credentialsMode: credentials,
    destination: destination,
    proxy: proxyUrl,
    referrer: referrer
  ))

func credentialsMode*(attribute: CORSAttribute): CredentialsMode =
  case attribute
  of NO_CORS, ANONYMOUS:
    return SAME_ORIGIN
  of USE_CREDENTIALS:
    return INCLUDE

proc addRequestModule*(ctx: JSContext) =
  ctx.registerType(Request)
