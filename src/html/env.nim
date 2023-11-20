import selectors
import streams

import bindings/quickjs
import display/winattrs
import html/chadombuilder
import html/dom
import html/event
import io/promise
import js/base64
import js/console
import js/domexception
import js/encoding
import js/error
import js/intl
import js/javascript
import js/strings
import js/timeout
import loader/headers
import loader/loader
import loader/request
import loader/response
import types/blob
import types/url
import xhr/formdata
import xhr/xmlhttprequest

# NavigatorID
proc appCodeName(navigator: ptr Navigator): string {.jsfget.} = "Mozilla"
proc appName(navigator: ptr Navigator): string {.jsfget.} = "Netscape"
proc appVersion(navigator: ptr Navigator): string {.jsfget.} = "5.0 (Windows)"
proc platform(navigator: ptr Navigator): string {.jsfget.} = "Win32"
proc product(navigator: ptr Navigator): string {.jsfget.} = "Gecko"
proc productSub(navigator: ptr Navigator): string {.jsfget.} = "20100101"
proc userAgent(navigator: ptr Navigator): string {.jsfget.} = "chawan" #TODO TODO TODO this should be configurable
proc vendor(navigator: ptr Navigator): string {.jsfget.} = ""
proc vendorSub(navigator: ptr Navigator): string {.jsfget.} = ""
proc taintEnabled(navigator: ptr Navigator): bool {.jsfget.} = false
proc oscpu(navigator: ptr Navigator): string {.jsfget.} = "Windows NT 10.0"

# NavigatorLanguage
proc language(navigator: ptr Navigator): string {.jsfget.} = "en-US"
proc languages(navigator: ptr Navigator): seq[string] {.jsfget.} = @["en-US"] #TODO frozen array?

# NavigatorOnline
proc onLine(navigator: ptr Navigator): bool {.jsfget.} =
  true # at the very least, the terminal is on-line :)

#TODO NavigatorContentUtils

# NavigatorCookies
# "this website needs cookies to be enabled to function correctly"
# It's probably better to lie here.
proc cookieEnabled(navigator: ptr Navigator): bool {.jsfget.} = true

# NavigatorPlugins
proc pdfViewerEnabled(navigator: ptr Navigator): bool {.jsfget.} = false
proc javaEnabled(navigator: ptr Navigator): bool {.jsfunc.} = false
proc namedItem(pluginArray: ptr PluginArray): string {.jsfunc.} = ""
proc namedItem(mimeTypeArray: ptr MimeTypeArray): string {.jsfunc.} = ""
proc item(pluginArray: ptr PluginArray): JSValue {.jsfunc.} = JS_NULL
proc length(pluginArray: ptr PluginArray): uint32 {.jsfget.} = 0
proc item(mimeTypeArray: ptr MimeTypeArray): JSValue {.jsfunc.} = JS_NULL
proc length(mimeTypeArray: ptr MimeTypeArray): uint32 {.jsfget.} = 0
proc getter(pluginArray: ptr PluginArray, i: int): Option[JSValue] {.jsgetprop.} = discard
proc getter(mimeTypeArray: ptr MimeTypeArray, i: int): Option[JSValue] {.jsgetprop.} = discard

proc addNavigatorModule(ctx: JSContext) =
  ctx.registerType(Navigator)
  ctx.registerType(PluginArray)
  ctx.registerType(MimeTypeArray)

proc fetch[T: Request|string](window: Window, req: T, init = none(RequestInit)):
    JSResult[FetchPromise] {.jsfunc.} =
  if window.loader.isSome:
    let req = ?newRequest(window.jsctx, req, init)
    return ok(window.loader.get.fetch(req))

proc setTimeout[T: JSValue|string](window: Window, handler: T,
    timeout = 0i32): int32 {.jsfunc.} =
  return window.timeouts.setTimeout(handler, timeout)

proc setInterval[T: JSValue|string](window: Window, handler: T,
    interval = 0i32): int32 {.jsfunc.} =
  return window.timeouts.setInterval(handler, interval)

proc clearTimeout(window: Window, id: int32) {.jsfunc.} =
  window.timeouts.clearTimeout(id)

proc clearInterval(window: Window, id: int32) {.jsfunc.} =
  window.timeouts.clearInterval(id)

proc screenX(window: Window): int64 {.jsfget.} = 0
proc screenY(window: Window): int64 {.jsfget.} = 0
proc screenLeft(window: Window): int64 {.jsfget.} = 0
proc screenTop(window: Window): int64 {.jsfget.} = 0
#TODO outerWidth, outerHeight
proc devicePixelRatio(window: Window): float64 {.jsfget.} = 1

proc setLocation(window: Window, s: string): Err[JSError]
    {.jsfset: "location".} =
  window.document.setLocation(s)

proc getWindow(window: Window): Window {.jsuffget: "window".} =
  return window

proc getSelf(window: Window): Window {.jsfget: "self".} =
  return window

proc getFrames(window: Window): Window {.jsfget: "frames".} =
  return window

proc atob(window: Window, data: string): DOMResult[NarrowString] {.jsfunc.} =
  return atob(data)

proc btoa(window: Window, data: JSString): DOMResult[string] {.jsfunc.} =
  return btoa(data)

proc getComputedStyle(window: Window, element: Element,
    pseudoElt = none(Element)): JSResult[CSSStyleDeclaration] {.jsfunc.} =
  #TODO implement this properly
  return ok(element.style)

proc addScripting*(window: Window, selector: Selector[int]) =
  let rt = newJSRuntime()
  let ctx = rt.newJSContext()
  window.jsrt = rt
  window.jsctx = ctx
  window.timeouts = newTimeoutState(
    selector = selector,
    jsctx = ctx,
    err = window.console.err,
    evalJSFree = (proc(src, file: string) =
      let ret = window.jsctx.eval(src, file, JS_EVAL_TYPE_GLOBAL)
      if JS_IsException(ret):
        let ss = newStringStream()
        window.jsctx.writeException(ss)
        ss.setPosition(0)
        window.console.log("Exception in document", $window.document.url,
          ss.readAll())
    )
  )
  var global = JS_GetGlobalObject(ctx)
  ctx.addEventModule()
  let eventTargetCID = ctx.getClass("EventTarget")
  ctx.registerType(Window, asglobal = true, parent = eventTargetCID)
  ctx.setGlobal(global, window)
  JS_FreeValue(ctx, global)
  ctx.addDOMExceptionModule()
  ctx.addConsoleModule()
  ctx.addNavigatorModule()
  ctx.addDOMModule()
  ctx.addURLModule()
  ctx.addHTMLModule()
  ctx.addIntlModule()
  ctx.addBlobModule()
  ctx.addFormDataModule()
  ctx.addXMLHttpRequestModule()
  ctx.addHeadersModule()
  ctx.addRequestModule()
  ctx.addResponseModule()
  ctx.addEncodingModule()

proc runJSJobs*(window: Window) =
  window.jsrt.runJSJobs(window.console.err)

proc newWindow*(scripting: bool, selector: Selector[int],
    attrs: WindowAttributes, navigate: proc(url: URL) = nil,
    loader = none(FileLoader)): Window =
  let err = newFileStream(stderr)
  let window = Window(
    attrs: attrs,
    console: newConsole(err),
    navigator: Navigator(),
    loader: loader,
    settings: EnvironmentSettings(
      scripting: scripting
    ),
    navigate: navigate
  )
  window.location = window.newLocation()
  if scripting:
    window.addScripting(selector)
  return window
