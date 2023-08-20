import selectors
import streams

import html/chadombuilder
import html/dom
import html/event
import io/headers
import io/loader
import io/promise
import io/request
import io/response
import io/window
import js/exception
import js/intl
import js/javascript
import js/timeout
import types/blob
import types/url
import xhr/formdata
import xhr/xmlhttprequest

# NavigatorID
proc appCodeName(navigator: Navigator): string {.jsfget.} = "Mozilla"
proc appName(navigator: Navigator): string {.jsfget.} = "Netscape"
proc appVersion(navigator: Navigator): string {.jsfget.} = "5.0 (Windows)"
proc platform(navigator: Navigator): string {.jsfget.} = "Win32"
proc product(navigator: Navigator): string {.jsfget.} = "Gecko"
proc productSub(navigator: Navigator): string {.jsfget.} = "20100101"
proc userAgent(navigator: Navigator): string {.jsfget.} = "chawan" #TODO TODO TODO this should be configurable
proc vendor(navigator: Navigator): string {.jsfget.} = ""
proc vendorSub(navigator: Navigator): string {.jsfget.} = ""
proc taintEnabled(navigator: Navigator): bool {.jsfget.} = false
proc oscpu(navigator: Navigator): string {.jsfget.} = "Windows NT 10.0"

# NavigatorLanguage
proc language(navigator: Navigator): string {.jsfget.} = "en-US"
proc languages(navigator: Navigator): seq[string] {.jsfget.} = @["en-US"] #TODO frozen array?

# NavigatorOnline
proc onLine(navigator: Navigator): bool {.jsfget.} =
  true # at the very least, the terminal is on-line :)

#TODO NavigatorContentUtils

# NavigatorCookies
# "this website needs cookies to be enabled to function correctly"
# It's probably better to lie here.
proc cookieEnabled(navigator: Navigator): bool {.jsfget.} = true

# NavigatorPlugins
proc pdfViewerEnabled(navigator: Navigator): bool {.jsfget.} = false
proc javaEnabled(navigator: Navigator): bool {.jsfunc.} = false
proc namedItem(pluginArray: PluginArray): string {.jsfunc.} = ""
proc namedItem(mimeTypeArray: MimeTypeArray): string {.jsfunc.} = ""
proc item(pluginArray: PluginArray): JSValue {.jsfunc.} = JS_NULL
proc length(pluginArray: PluginArray): int {.jsfget.} = 0
proc item(mimeTypeArray: MimeTypeArray): JSValue {.jsfunc.} = JS_NULL
proc length(mimeTypeArray: MimeTypeArray): int {.jsfget.} = 0
proc getter(pluginArray: PluginArray, i: int): Option[JSValue] {.jsgetprop.} = discard
proc getter(mimeTypeArray: MimeTypeArray, i: int): Option[JSValue] {.jsgetprop.} = discard

proc addNavigatorModule(ctx: JSContext) =
  ctx.registerType(Navigator)
  ctx.registerType(PluginArray)
  ctx.registerType(MimeTypeArray)

proc fetch(window: Window, req: Request): FetchPromise {.jsfunc.} =
  if window.loader.isSome:
    return window.loader.get.fetch(req)

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

proc setLocation(window: Window, s: string): Err[DOMException]
    {.jsfset: "location".} =
  window.document.setLocation(s)

proc getWindow(window: Window): Window {.jsuffget: "window".} =
  return window

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
  ctx.registerType(Window, asglobal = true)
  ctx.setGlobal(global, window)
  JS_FreeValue(ctx, global)
  ctx.addDOMExceptionModule()
  ctx.addconsoleModule()
  ctx.addNavigatorModule()
  ctx.addEventModule()
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

proc runJSJobs*(window: Window) =
  window.jsrt.runJSJobs(window.console.err)

proc newWindow*(scripting: bool, selector: Selector[int],
    attrs: WindowAttributes, navigate: proc(url: URL) = nil,
    loader = none(FileLoader)): Window =
  let window = Window(
    attrs: attrs,
    console: console(err: newFileStream(stderr)),
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
