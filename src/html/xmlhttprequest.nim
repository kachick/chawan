import std/options
import std/strutils

import html/dom
import html/event
import js/domexception
import loader/headers
import loader/request
import loader/response
import monoucha/fromjs
import monoucha/javascript
import monoucha/quickjs
import types/opt
import types/url

type
  XMLHttpRequestResponseType = enum
    xhrtUnknown = ""
    xhrtArraybuffer = "arraybuffer"
    xhrtBlob = "blob"
    xhrtDocument = "document"
    xhrtJSON = "json"
    xhrtText = "text"

  XMLHttpRequestState = enum
    UNSENT = 0u16
    OPENED = 1u16
    HEADERS_RECEIVED = 2u16
    LOADING = 3u16
    DONE = 4u16

  XMLHttpRequestFlag = enum
    xhrfSend, xhrfUploadListener, xhrfSync

  XMLHttpRequestEventTarget = ref object of EventTarget
    onloadstart {.jsgetset.}: EventHandler
    onprogress {.jsgetset.}: EventHandler
    onabort {.jsgetset.}: EventHandler
    onerror {.jsgetset.}: EventHandler
    onload {.jsgetset.}: EventHandler
    ontimeout {.jsgetset.}: EventHandler
    onloadend {.jsgetset.}: EventHandler

  XMLHttpRequestUpload = ref object of XMLHttpRequestEventTarget

  XMLHttpRequest = ref object of XMLHttpRequestEventTarget
    onreadystatechange {.jsgetset.}: EventHandler
    readyState: XMLHttpRequestState
    upload {.jsget.}: XMLHttpRequestUpload
    flags: set[XMLHttpRequestFlag]
    requestMethod: HttpMethod
    requestURL: URL
    authorRequestHeaders: Headers
    response: Response
    responseType {.jsgetset.}: XMLHttpRequestResponseType

jsDestructor(XMLHttpRequestEventTarget)
jsDestructor(XMLHttpRequestUpload)
jsDestructor(XMLHttpRequest)

func newXMLHttpRequest(): XMLHttpRequest {.jsctor.} =
  let upload = XMLHttpRequestUpload()
  return XMLHttpRequest(
    upload: upload,
    authorRequestHeaders: newHeaders()
  )

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

proc open(ctx: JSContext; this: XMLHttpRequest; httpMethod, url: string):
    Err[DOMException] {.jsfunc.} =
  let httpMethod = ?parseMethod(httpMethod)
  let global = JS_GetGlobalObject(ctx)
  let window = fromJS[Window](ctx, global)
  JS_FreeValue(ctx, global)
  let x = if window.isSome:
    parseURL(url, some(window.get.document.baseURL))
  else:
    parseURL(url)
  if x.isNone:
    return errDOMException("Invalid URL", "SyntaxError")
  let parsedURL = x.get
  #TODO async, username, password arguments
  let async = true
  #TODO if async is false... probably just throw.
  #TODO terminate fetch controller
  this.flags.excl(xhrfSend)
  this.flags.excl(xhrfUploadListener)
  if async:
    this.flags.excl(xhrfSync)
  else:
    this.flags.incl(xhrfSync)
  this.requestMethod = httpMethod
  this.authorRequestHeaders = newHeaders()
  this.response = makeNetworkError()
  this.requestURL = parsedURL
  return ok()

proc addXMLHttpRequestModule*(ctx: JSContext) =
  let eventTargetCID = ctx.getClass("EventTarget")
  let xhretCID = ctx.registerType(XMLHttpRequestEventTarget, eventTargetCID)
  ctx.registerType(XMLHttpRequestUpload, xhretCID)
  let xhrCID = ctx.registerType(XMLHttpRequest, xhretCID)
  ctx.defineConsts(xhrCID, XMLHttpRequestState, uint16)
