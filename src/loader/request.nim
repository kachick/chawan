import std/options
import std/strutils
import std/tables

import html/script
import loader/headers
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/jstypes
import monoucha/quickjs
import types/blob
import types/formdata
import types/opt
import types/referrer
import types/url

type
  HttpMethod* = enum
    hmGet = "GET"
    hmConnect = "CONNECT"
    hmDelete = "DELETE"
    hmHead = "HEAD"
    hmOptions = "OPTIONS"
    hmPatch = "PATCH"
    hmPost = "POST"
    hmPut = "PUT"
    hmTrace = "TRACE"

  RequestMode* = enum
    rmNoCors = "no-cors"
    rmSameOrigin = "same-origin"
    rmCors = "cors"
    rmNavigate = "navigate"
    rmWebsocket = "websocket"

  CORSAttribute* = enum
    caNoCors = "no-cors"
    caAnonymous = "anonymous"
    caUseCredentials = "use-credentials"

type
  RequestOriginType* = enum
    rotClient, rotOrigin

  RequestOrigin* = object
    case t*: RequestOriginType
    of rotClient: discard
    of rotOrigin:
      origin*: Origin

  RequestWindowType* = enum
    rwtClient, rwtNoWindow, rwtWindow

  RequestWindow* = object
    case t*: RequestWindowType
    of rwtClient, rwtNoWindow: discard
    of rwtWindow:
      window*: EnvironmentSettings

  Request* = ref object
    httpMethod*: HttpMethod
    url*: URL
    headers*: Headers
    body*: Option[string]
    multipart*: Option[FormData]
    referrer*: URL
    proxy*: URL #TODO do something with this
    # when set to true, the loader will not write data from the body (not
    # headers!) into the output until a resume is received.
    suspended*: bool

  JSRequest* = ref object
    request*: Request
    mode* {.jsget.}: RequestMode
    destination* {.jsget.}: RequestDestination
    credentialsMode* {.jsget.}: CredentialsMode
    origin*: RequestOrigin
    window*: RequestWindow
    client*: Option[EnvironmentSettings]

jsDestructor(JSRequest)

func headers(this: JSRequest): Headers {.jsfget.} =
  return this.request.headers

func url(this: JSRequest): URL =
  return this.request.url

proc jsUrl(this: JSRequest): string {.jsfget: "url".} =
  return $this.url

#TODO pretty sure this is incorrect
proc jsReferrer(this: JSRequest): string {.jsfget: "referrer".} =
  if this.request.referrer != nil:
    return $this.request.referrer
  return ""

iterator pairs*(headers: Headers): (string, string) =
  for k, vs in headers.table:
    for v in vs:
      yield (k, v)

func newRequest*(url: URL; httpMethod = hmGet; headers = newHeaders();
    body = none(string); multipart = none(FormData); proxy: URL = nil;
    referrer: URL = nil; suspended = false): Request =
  return Request(
    url: url,
    httpMethod: httpMethod,
    headers: headers,
    body: body,
    multipart: multipart,
    referrer: referrer,
    proxy: proxy,
    suspended: suspended
  )

func createPotentialCORSRequest*(url: URL; destination: RequestDestination;
    cors: CORSAttribute; fallbackFlag = false): JSRequest =
  var mode = if cors == caNoCors:
    rmNoCors
  else:
    rmCors
  if fallbackFlag and mode == rmNoCors:
    mode = rmSameOrigin
  let credentialsMode = if cors == caAnonymous: cmSameOrigin else: cmInclude
  return JSRequest(
    request: newRequest(url),
    destination: destination,
    mode: mode,
    credentialsMode: credentialsMode
  )

type
  BodyInitType = enum
    bitBlob, bitFormData, bitUrlSearchParams, bitString

  BodyInit = object
    #TODO ReadableStream, BufferSource
    case t: BodyInitType
    of bitBlob:
      blob: Blob
    of bitFormData:
      formData: FormData
    of bitUrlSearchParams:
      searchParams: URLSearchParams
    of bitString:
      str: string

  RequestInit* = object of JSDict
    #TODO aliasing in dicts
    `method`: HttpMethod # default: GET
    headers: Option[HeadersInit]
    body: Option[BodyInit]
    referrer: Option[string]
    referrerPolicy: Option[ReferrerPolicy]
    credentials: Option[CredentialsMode]
    proxyUrl: URL
    mode: Option[RequestMode]
    window: Option[JSValue]

proc fromJSBodyInit(ctx: JSContext; val: JSValue): JSResult[BodyInit] =
  if JS_IsUndefined(val) or JS_IsNull(val):
    return err(nil)
  block formData:
    let x = fromJS[FormData](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: bitFormData, formData: x.get))
  block blob:
    let x = fromJS[Blob](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: bitBlob, blob: x.get))
  block searchParams:
    let x = fromJS[URLSearchParams](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: bitUrlSearchParams, searchParams: x.get))
  block str:
    let x = fromJS[string](ctx, val)
    if x.isSome:
      return ok(BodyInit(t: bitString, str: x.get))
  return err(newTypeError("Invalid body init type"))

func newRequest*[T: string|JSRequest](ctx: JSContext; resource: T;
    init = none(RequestInit)): JSResult[JSRequest] {.jsctor.} =
  defer:
    if init.isSome and init.get.window.isSome:
      JS_FreeValue(ctx, init.get.window.get)
  when T is string:
    let url = ?newURL(resource)
    if url.username != "" or url.password != "":
      return err(newTypeError("Input URL contains a username or password"))
    var httpMethod = hmGet
    var headers = newHeaders()
    let referrer: URL = nil
    var credentials = cmSameOrigin
    var body: Option[string]
    var multipart: Option[FormData]
    var proxyUrl: URL #TODO?
    let fallbackMode = opt(rmCors)
    var window = RequestWindow(t: rwtClient)
  else:
    let url = resource.url
    var httpMethod = resource.request.httpMethod
    var headers = resource.headers.clone()
    let referrer = resource.request.referrer
    var credentials = resource.credentialsMode
    var body = resource.request.body
    var multipart = resource.request.multipart
    var proxyUrl = resource.request.proxy #TODO?
    let fallbackMode = none(RequestMode)
    var window = resource.window
  var mode = fallbackMode.get(rmNoCors)
  let destination = rdNone
  #TODO origin, window
  if init.isSome: #TODO spec wants us to check if it's "not empty"...
    let init = init.get
    if init.window.isSome:
      if not JS_IsNull(init.window.get):
        return errTypeError("Expected window to be null")
      window = RequestWindow(t: rwtNoWindow)
    if mode == rmNavigate:
      mode = rmSameOrigin
    #TODO flags?
    #TODO referrer
    httpMethod = init.`method`
    if init.body.isSome:
      let ibody = init.body.get
      case ibody.t
      of bitFormData: multipart = some(ibody.formData)
      of bitString: body = some(ibody.str)
      else: discard #TODO
      if httpMethod in {hmGet, hmHead}:
        return errTypeError("HEAD or GET Request cannot have a body.")
    if init.headers.isSome:
      headers.fill(init.headers.get)
    if init.credentials.isSome:
      credentials = init.credentials.get
    if init.mode.isSome:
      mode = init.mode.get
    #TODO find a standard compatible way to implement this
    proxyUrl = init.proxyUrl
  return ok(JSRequest(
    request: newRequest(
      url,
      httpMethod,
      headers,
      body,
      multipart,
      proxy = proxyUrl,
      referrer = referrer
    ),
    mode: mode,
    credentialsMode: credentials,
    destination: destination,
    window: window
  ))

func credentialsMode*(attribute: CORSAttribute): CredentialsMode =
  case attribute
  of caNoCors, caAnonymous:
    return cmSameOrigin
  of caUseCredentials:
    return cmInclude

proc addRequestModule*(ctx: JSContext) =
  ctx.registerType(JSRequest, name = "Request")
