import std/options
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

  RequestBodyType* = enum
    rbtNone, rbtString, rbtMultipart, rbtOutput

  RequestBody* = object
    case t*: RequestBodyType
    of rbtNone:
      discard
    of rbtString:
      s*: string
    of rbtMultipart:
      multipart*: FormData
    of rbtOutput:
      outputId*: int

  Request* = ref object
    httpMethod*: HttpMethod
    url*: URL
    headers*: Headers
    body*: RequestBody
    referrer*: URL
    proxy*: URL #TODO do something with this

  JSRequest* = ref object
    request*: Request
    mode* {.jsget.}: RequestMode
    destination* {.jsget.}: RequestDestination
    credentialsMode* {.jsget.}: CredentialsMode
    origin*: RequestOrigin
    window*: RequestWindow
    client*: Option[EnvironmentSettings]

jsDestructor(JSRequest)

proc contentLength*(body: RequestBody): int =
  case body.t
  of rbtNone: return 0
  of rbtString: return body.s.len
  of rbtMultipart: return body.multipart.calcLength()
  of rbtOutput: return 0

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
    body = RequestBody(); proxy: URL = nil; referrer: URL = nil): Request =
  return Request(
    url: url,
    httpMethod: httpMethod,
    headers: headers,
    body: body,
    referrer: referrer,
    proxy: proxy
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
  return errTypeError("Invalid body init type")

var getAPIBaseURLImpl*: proc(ctx: JSContext): URL {.noSideEffect, nimcall.}

proc newRequest*(ctx: JSContext; resource: JSValue; init = none(RequestInit)):
    JSResult[JSRequest] {.jsctor.} =
  defer:
    if init.isSome and init.get.window.isSome:
      JS_FreeValue(ctx, init.get.window.get)
  let headers = newHeaders(hgRequest)
  var fallbackMode = opt(rmCors)
  var window = RequestWindow(t: rwtClient)
  var body = RequestBody()
  var credentials = cmSameOrigin
  var httpMethod = hmGet
  var referrer: URL = nil
  var url: URL = nil
  if JS_IsString(resource):
    let s = ?fromJS[string](ctx, resource)
    url = ?parseJSURL(s, option(ctx.getAPIBaseURLImpl()))
  else:
    let resource = ?fromJS[JSRequest](ctx, resource)
    url = resource.url
    httpMethod = resource.request.httpMethod
    headers.table = resource.headers.table
    referrer = resource.request.referrer
    credentials = resource.credentialsMode
    body = resource.request.body
    fallbackMode = opt(RequestMode)
    window = resource.window
  if url.username != "" or url.password != "":
    return errTypeError("Input URL contains a username or password")
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
      of bitFormData:
        body = RequestBody(t: rbtMultipart, multipart: ibody.formData)
      of bitString:
        body = RequestBody(t: rbtString, s: ibody.str)
      else: discard #TODO
      if httpMethod in {hmGet, hmHead}:
        return errTypeError("HEAD or GET Request cannot have a body.")
    if init.headers.isSome:
      ?headers.fill(init.headers.get)
    if init.credentials.isSome:
      credentials = init.credentials.get
    if init.mode.isSome:
      mode = init.mode.get
  if mode == rmNoCors:
    headers.guard = hgRequestNoCors
  return ok(JSRequest(
    request: newRequest(
      url,
      httpMethod,
      headers,
      body,
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
