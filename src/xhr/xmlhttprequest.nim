import std/options
import std/strutils

import html/event
import js/domexception
import js/javascript
import loader/headers
import loader/request
import loader/response
import types/url

type
  XMLHttpRequestResponseType = enum
    TYPE_UNKNOWN = ""
    TYPE_ARRAYBUFFER = "arraybuffer"
    TYPE_BLOB = "blob"
    TYPE_DOCUMENT = "document"
    TYPE_JSON = "json"
    TYPE_TEXT = "text"

  XMLHttpRequestState = enum
    UNSENT = 0u16
    OPENED = 1u16
    HEADERS_RECEIVED = 2u16
    LOADING = 3u16
    DONE = 4u16

  XMLHttpRequestFlag = enum
    SEND_FLAG, UPLOAD_LISTENER_FLAG, SYNC_FLAG

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
    responseType {.jsget.}: XMLHttpRequestResponseType

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
  of "get": ok(HTTP_GET)
  of "delete": ok(HTTP_DELETE)
  of "head": ok(HTTP_HEAD)
  of "options": ok(HTTP_OPTIONS)
  of "patch": ok(HTTP_PATCH)
  of "post": ok(HTTP_POST)
  of "put": ok(HTTP_PUT)
  of "connect", "trace", "track":
    err(newDOMException("Forbidden method", "SecurityError"))
  else:
    err(newDOMException("Invalid method", "SyntaxError"))

proc open(this: XMLHttpRequest, httpMethod, url: string): Err[DOMException]
    {.jsfunc.} =
  let httpMethod = ?parseMethod(httpMethod)
  let x = parseURL(url)
  if x.isNone:
    return err(newDOMException("Invalid URL", "SyntaxError"))
  let parsedURL = x.get
  #TODO async, username, password arguments
  let async = true
  #TODO if async is false... probably just throw.
  #TODO terminate fetch controller
  this.flags.excl(SEND_FLAG)
  this.flags.excl(UPLOAD_LISTENER_FLAG)
  #TODO set if not async
  if async:
    this.flags.excl(SYNC_FLAG)
  else:
    this.flags.incl(SYNC_FLAG)
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
