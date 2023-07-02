import html/event
import js/javascript

type
  XMLHttpRequestResponseType = enum
    TYPE_UNKNOWN = ""
    TYPE_ARRAYBUFFER = "arraybuffer"
    TYPE_BLOB = "blob"
    TYPE_DOCUMENT = "document"
    TYPE_JSON = "json"
    TYPE_TEXT = "text"

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
    readyState {.jsget.}: uint16
    upload {.jsget.}: XMLHttpRequestUpload

jsDestructor(XMLHttpRequestEventTarget)
jsDestructor(XMLHttpRequestUpload)
jsDestructor(XMLHttpRequest)

func newXMLHttpRequest(): XMLHttpRequest {.jsctor.} =
  let upload = XMLHttpRequestUpload()
  return XMLHttpRequest(
    upload: upload
  )

proc open(this: XMLHttpRequest, httpMethod, url: string) {.jsfunc.} =
  discard #TODO implement

proc addXMLHttpRequestModule*(ctx: JSContext) =
  let eventTargetCID = ctx.getClass("EventTarget")
  let xhretCID = ctx.registerType(XMLHttpRequestEventTarget, eventTargetCID)
  ctx.registerType(XMLHttpRequestUpload, xhretCID)
  ctx.registerType(XMLHttpRequest, xhretCID)
