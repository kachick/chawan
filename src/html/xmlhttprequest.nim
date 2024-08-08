import std/options
import std/strutils
import std/tables

import chagashi/decoder
import html/catom
import html/dom
import html/event
import html/script
import io/promise
import js/domexception
import loader/headers
import loader/loader
import loader/request
import loader/response
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/quickjs
import monoucha/tojs
import types/opt
import types/url
import utils/twtstr

type
  XMLHttpRequestResponseType = enum
    xhrtUnknown = ""
    xhrtArraybuffer = "arraybuffer"
    xhrtBlob = "blob"
    xhrtDocument = "document"
    xhrtJSON = "json"
    xhrtText = "text"

  XMLHttpRequestState = enum
    xhrsUnsent = (0u16, "UNSENT")
    xhrsOpened = (1u16, "OPENED")
    xhrsHeadersReceived = (2u16, "HEADERS_RECEIVED")
    xhrsLoading = (3u16, "LOADING")
    xhrsDone = (4u16, "DONE")

  XMLHttpRequestFlag = enum
    xhrfSend, xhrfUploadListener, xhrfSync, xhrfUploadComplete, xhrfTimedOut

  XMLHttpRequestEventTarget = ref object of EventTarget

  XMLHttpRequestUpload = ref object of XMLHttpRequestEventTarget

  XMLHttpRequest = ref object of XMLHttpRequestEventTarget
    readyState: XMLHttpRequestState
    upload {.jsget.}: XMLHttpRequestUpload
    flags: set[XMLHttpRequestFlag]
    requestMethod: HttpMethod
    requestURL: URL
    headers: Headers
    response: Response
    responseType {.jsget.}: XMLHttpRequestResponseType
    timeout {.jsget.}: uint32

  ProgressEvent = ref object of Event
    lengthComputable {.jsget.}: bool
    loaded {.jsget.}: uint32
    total {.jsget.}: uint32

  ProgressEventInit = object of EventInit
    lengthComputable: bool
    loaded: uint32
    total: uint32

jsDestructor(XMLHttpRequestEventTarget)
jsDestructor(XMLHttpRequestUpload)
jsDestructor(XMLHttpRequest)
jsDestructor(ProgressEvent)

func newXMLHttpRequest(): XMLHttpRequest {.jsctor.} =
  let upload = XMLHttpRequestUpload()
  return XMLHttpRequest(
    upload: upload,
    headers: newHeaders()
  )

proc newProgressEvent(ctype: CAtom; init = ProgressEventInit()): ProgressEvent
    {.jsctor.} =
  let event = ProgressEvent(
    ctype: ctype,
    lengthComputable: init.lengthComputable,
    loaded: init.loaded,
    total: init.total
  )
  Event(event).innerEventCreationSteps(init)
  return event

func readyState(this: XMLHttpRequest): uint16 {.jsfget.} =
  return uint16(this.readyState)

proc parseMethod(s: string): DOMResult[HttpMethod] =
  return case s.toLowerAscii()
  of "get": ok(hmGet)
  of "delete": ok(hmDelete)
  of "head": ok(hmHead)
  of "options": ok(hmOptions)
  of "patch": ok(hmPatch)
  of "post": ok(hmPost)
  of "put": ok(hmPut)
  of "connect", "trace", "track":
    errDOMException("Forbidden method", "SecurityError")
  else:
    errDOMException("Invalid method", "SyntaxError")

#TODO the standard says that no async should be treated differently from
# undefined. idk if (and where) this actually matters.
proc open(ctx: JSContext; this: XMLHttpRequest; httpMethod, url: string;
    async = true; username = ""; password = ""): Err[DOMException] {.jsfunc.} =
  let httpMethod = ?parseMethod(httpMethod)
  let global = ctx.getGlobal()
  let x = parseURL(url, some(global.document.baseURL))
  if x.isNone:
    return errDOMException("Invalid URL", "SyntaxError")
  let parsedURL = x.get
  if not async and ctx.getWindow() != nil and
      (this.timeout != 0 or this.responseType != xhrtUnknown):
    return errDOMException("Today's horoscope: don't go outside",
      "InvalidAccessError")
  #TODO terminate fetch controller
  this.flags.excl(xhrfSend)
  this.flags.excl(xhrfUploadListener)
  if async:
    this.flags.excl(xhrfSync)
  else:
    this.flags.incl(xhrfSync)
  this.requestMethod = httpMethod
  this.headers = newHeaders()
  this.response = makeNetworkError()
  this.requestURL = parsedURL
  #TODO response object, received bytes
  if this.readyState != xhrsOpened:
    this.readyState = xhrsOpened
    global.fireEvent(satReadystatechange, this)
  return ok()

proc checkOpened(this: XMLHttpRequest): DOMResult[void] =
  if this.readyState != xhrsOpened:
    return errDOMException("ready state was expected to be `opened'",
      "InvalidStateError")
  ok()

proc checkSendFlag(this: XMLHttpRequest): DOMResult[void] =
  if xhrfSend in this.flags:
    return errDOMException("`send' flag is set", "InvalidStateError")
  ok()

proc setRequestHeader(this: XMLHttpRequest; name, value: string):
    DOMResult[void] {.jsfunc.} =
  ?this.checkOpened()
  ?this.checkSendFlag()
  if not name.isValidHeaderName() or not value.isValidHeaderValue():
    return errDOMException("Invalid header name or value", "SyntaxError")
  if isForbiddenRequestHeader(name, value):
    return ok()
  this.headers.table[name.toHeaderCase()] = @[value]
  ok()

proc fireProgressEvent(window: Window; target: EventTarget; name: StaticAtom;
    loaded, length: uint32) =
  let event = newProgressEvent(window.factory.toAtom(name), ProgressEventInit(
    loaded: loaded,
    total: length,
    lengthComputable: length != 0
  ))
  discard window.jsctx.dispatch(target, event)

# Forward declaration hack
var windowFetch*: proc(window: Window; input: JSValue;
  init = RequestInit(window: JS_UNDEFINED)): JSResult[FetchPromise]
  {.nimcall.} = nil

proc errorSteps(window: Window; this: XMLHttpRequest; name: StaticAtom) =
  this.readyState = xhrsDone
  this.response = makeNetworkError()
  this.flags.excl(xhrfSend)
  #TODO sync?
  window.fireEvent(satReadystatechange, this)
  if xhrfUploadComplete notin this.flags:
    this.flags.incl(xhrfUploadComplete)
    if xhrfUploadListener in this.flags:
      window.fireProgressEvent(this.upload, name, 0, 0)
      window.fireProgressEvent(this.upload, satLoadend, 0, 0)
  window.fireProgressEvent(this, name, 0, 0)
  window.fireProgressEvent(this, satLoadend, 0, 0)

proc handleErrors(window: Window; this: XMLHttpRequest): DOMException =
  if xhrfSend notin this.flags:
    return nil
  if xhrfTimedOut in this.flags:
    window.errorSteps(this, satTimeout)
    if xhrfSync in this.flags:
      return newDOMException("XHR timed out", "TimeoutError")
  elif rfAborted in this.response.flags:
    window.errorSteps(this, satAbort)
    if xhrfSync in this.flags:
      return newDOMException("XHR aborted", "AbortError")
  elif this.response.responseType == rtError:
    window.errorSteps(this, satError)
    if xhrfSync in this.flags:
      return newDOMException("Network error in XHR", "NetworkError")
  return nil

proc send(ctx: JSContext; this: XMLHttpRequest; body = JS_NULL): DOMResult[void]
    {.jsfunc.} =
  ?this.checkOpened()
  ?this.checkSendFlag()
  var body = body
  if this.requestMethod in {hmGet, hmHead}:
    body = JS_NULL
  let request = newRequest(this.requestURL, this.requestMethod, this.headers)
  if not JS_IsNull(body):
    var document: Document = nil
    if ctx.fromJS(body, document).isSome:
      request.body = RequestBody(
        t: rbtString,
        s: document.serializeFragment().toValidUTF8() # replace surrogates
      )
    #TODO else...
    if "Content-Type" in this.headers:
      request.headers["Content-Type"].setContentTypeAttr("charset", "UTF-8")
    elif document != nil:
      request.headers["Content-Type"] = "text/html;charset=UTF-8"
  let jsRequest = JSRequest(
    #TODO unsafe request flag, client, cors credentials mode,
    # use-url-credentials, initiator type
    request: request,
    mode: rmCors,
    credentialsMode: cmSameOrigin,
  )
  if JS_IsNull(body):
    this.flags.incl(xhrfUploadComplete)
  else:
    this.flags.excl(xhrfUploadComplete)
  this.flags.excl(xhrfTimedOut)
  this.flags.incl(xhrfSend)
  let window = ctx.getWindow()
  if xhrfSync notin this.flags: # async
    window.fireProgressEvent(this, satLoadstart, 0, 0)
    let v = ctx.toJS(jsRequest)
    let p = window.windowFetch(v)
    JS_FreeValue(ctx, v)
    if p.isSome:
      p.get.then(proc(res: JSResult[Response]) =
        if res.isNone:
          this.response = makeNetworkError()
          discard window.handleErrors(this)
          return
        let response = res.get
        this.response = response
        this.readyState = xhrsHeadersReceived
        window.fireEvent(satReadystatechange, this)
      )
  else: # sync
    discard #TODO
  ok()

#TODO abort

proc responseURL(this: XMLHttpRequest): string {.jsfget.} =
  return this.response.surl

proc status(this: XMLHttpRequest): uint16 {.jsfget.} =
  return this.response.status

proc statusText(this: XMLHttpRequest): string {.jsfget.} =
  return ""

proc getResponseHeader(this: XMLHttpRequest; name: string): string {.jsfunc.} =
  #TODO ?
  return this.response.headers.table.getOrDefault(name)[0]

#TODO getAllResponseHeaders

proc setResponseType(ctx: JSContext; this: XMLHttpRequest;
    value: XMLHttpRequestResponseType): Err[DOMException]
    {.jsfset: "responseType".} =
  let window = ctx.getWindow()
  if window == nil and value == xhrtDocument:
    return ok()
  if this.readyState in {xhrsLoading, xhrsDone}:
    return errDOMException("readyState must not be loading or done",
      "InvalidStateError")
  if window != nil and xhrfSync in this.flags:
    return errDOMException("responseType may not be set on synchronous XHR",
      "InvalidAccessError")
  this.responseType = value
  ok()

proc setTimeout(ctx: JSContext; this: XMLHttpRequest; value: uint32):
    Err[DOMException] {.jsfset: "timeout".} =
  if ctx.getWindow() != nil and xhrfSync in this.flags:
    return errDOMException("timeout may not be set on synchronous XHR",
      "InvalidAccessError")
  this.timeout = value
  ok()

# Event reflection

const ReflectMap = [
  cint(0): satLoadstart,
  satProgress,
  satAbort,
  satError,
  satLoad,
  satTimeout,
  satLoadend,
  satReadystatechange
]

proc jsReflectGet(ctx: JSContext; this: JSValue; magic: cint): JSValue
    {.cdecl.} =
  let val = toJS(ctx, $ReflectMap[magic])
  let atom = JS_ValueToAtom(ctx, val)
  var res = JS_NULL
  var desc: JSPropertyDescriptor
  if JS_GetOwnProperty(ctx, addr desc, this, atom) > 0:
    JS_FreeValue(ctx, desc.setter)
    JS_FreeValue(ctx, desc.getter)
    res = JS_GetProperty(ctx, this, atom)
  JS_FreeValue(ctx, val)
  JS_FreeAtom(ctx, atom)
  return res

proc jsReflectSet(ctx: JSContext; this, val: JSValue; magic: cint): JSValue
    {.cdecl.} =
  if JS_IsFunction(ctx, val):
    let atom = ReflectMap[magic]
    var target: EventTarget
    assert ctx.fromJS(this, target).isSome
    ctx.definePropertyC(this, "on" & $atom, JS_DupValue(ctx, val))
    #TODO I haven't checked but this might also be wrong
    doAssert ctx.addEventListener(target, ctx.toAtom(atom), val).isSome
  return JS_DupValue(ctx, val)

func xhretGetSet(): seq[TabGetSet] =
  result = @[]
  for i, it in ReflectMap:
    if it == satReadystatechange:
      break
    result.add(TabGetSet(
      name: "on" & $it,
      get: jsReflectGet,
      set: jsReflectSet,
      magic: int16(i)
    ))

proc addXMLHttpRequestModule*(ctx: JSContext) =
  let eventTargetCID = ctx.getClass("EventTarget")
  let eventCID = ctx.getClass("Event")
  const getset0 = xhretGetSet()
  let xhretCID = ctx.registerType(XMLHttpRequestEventTarget, eventTargetCID,
    hasExtraGetSet = true, extraGetSet = getset0)
  ctx.registerType(XMLHttpRequestUpload, xhretCID)
  ctx.registerType(ProgressEvent, eventCID)
  const getset1 = [TabGetSet(
    name: "onreadystatechange",
    get: jsReflectGet,
    set: jsReflectSet,
    magic: int16(ReflectMap.high)
  )]
  let xhrCID = ctx.registerType(XMLHttpRequest, xhretCID, hasExtraGetSet = true,
    extraGetSet = getset1)
  ctx.defineConsts(xhrCID, XMLHttpRequestState, uint16)
