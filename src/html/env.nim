import std/selectors

import bindings/quickjs
import html/catom
import html/chadombuilder
import html/dom
import html/event
import html/formdata
import html/script
import html/xmlhttprequest
import io/filestream
import io/promise
import js/base64
import js/console
import js/domexception
import js/encoding
import js/error
import js/intl
import js/javascript
import js/jstypes
import js/timeout
import loader/headers
import loader/loader
import loader/request
import loader/response
import types/blob
import types/url
import types/winattrs

# NavigatorID
proc appCodeName(navigator: ptr Navigator): string {.jsfget.} = "Mozilla"
proc appName(navigator: ptr Navigator): string {.jsfget.} = "Netscape"
proc appVersion(navigator: ptr Navigator): string {.jsfget.} = "5.0 (Windows)"
proc platform(navigator: ptr Navigator): string {.jsfget.} = "Win32"
proc product(navigator: ptr Navigator): string {.jsfget.} = "Gecko"
proc productSub(navigator: ptr Navigator): string {.jsfget.} = "20100101"
proc userAgent(navigator: ptr Navigator): string {.jsfget.} =
  #TODO TODO TODO this should be configurable
  "chawan"
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

# Screen
proc availWidth(screen: ptr Screen): int64 {.jsfget.} =
  #TODO this is a fingerprinting vector, but users should be able to allow it
  # selectively
  # for now just return something standard-ish
  80 * 9
proc availHeight(screen: ptr Screen): int64 {.jsfget.} =
  #TODO see above
  24 * 18
proc width(screen: ptr Screen): int64 {.jsfget.} =
  screen.availWidth
proc height(screen: ptr Screen): int64 {.jsfget.} =
  screen.availHeight
proc colorDepth(screen: ptr Screen): int64 {.jsfget.} = 24
proc pixelDepth(screen: ptr Screen): int64 {.jsfget.} = screen.colorDepth

proc addNavigatorModule(ctx: JSContext) =
  ctx.registerType(Navigator)
  ctx.registerType(PluginArray)
  ctx.registerType(MimeTypeArray)
  ctx.registerType(Screen)

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
proc outerWidth(window: Window): int64 {.jsfget.} =
  (addr window.screen).availWidth
proc outerHeight(window: Window): int64 {.jsfget.} =
  (addr window.screen).availHeight
proc devicePixelRatio(window: Window): float64 {.jsfget.} = 1

proc setLocation(window: Window, s: string): Err[JSError]
    {.jsfset: "location".} =
  window.document.setLocation(s)

func getWindow(window: Window): Window {.jsuffget: "window".} =
  return window

#TODO [Replaceable]
func getSelf(window: Window): Window {.jsfget: "self".} =
  return window

#TODO [Replaceable]
func getFrames(window: Window): Window {.jsfget: "frames".} =
  return window

func getTop(window: Window): Window {.jsuffget: "top".} =
  return window #TODO frames?

#TODO [Replaceable]
func getParent(window: Window): Window {.jsfget: "parent".} =
  return window #TODO frames?

proc atob(window: Window, data: string): DOMResult[NarrowString] {.jsfunc.} =
  return atob(data)

proc btoa(ctx: JSContext, window: Window, data: JSValue): DOMResult[string]
    {.jsfunc.} =
  return btoa(ctx, data)

proc getComputedStyle(window: Window, element: Element,
    pseudoElt = none(Element)): JSResult[CSSStyleDeclaration] {.jsfunc.} =
  #TODO implement this properly
  return ok(element.style)

proc addScripting*(window: Window; selector: Selector[int]) =
  let rt = newJSRuntime()
  let ctx = rt.newJSContext()
  window.jsrt = rt
  window.jsctx = ctx
  window.importMapsAllowed = true
  window.timeouts = newTimeoutState(
    selector = selector,
    jsctx = ctx,
    err = window.console.err,
    evalJSFree = (proc(src, file: string) =
      let ret = window.jsctx.eval(src, file, JS_EVAL_TYPE_GLOBAL)
      if JS_IsException(ret):
        window.console.log("Exception in document", $window.document.url,
          window.jsctx.getExceptionMsg())
      else:
        JS_FreeValue(ctx, ret)
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

proc newWindow*(scripting, images: bool, selector: Selector[int],
    attrs: WindowAttributes, factory: CAtomFactory,
    navigate: proc(url: URL) = nil, loader = none(FileLoader)): Window =
  let err = newDynFileStream(stderr)
  let window = Window(
    attrs: attrs,
    console: newConsole(err),
    navigator: Navigator(),
    loader: loader,
    images: images,
    settings: EnvironmentSettings(
      scripting: scripting
    ),
    navigate: navigate,
    factory: factory
  )
  window.location = window.newLocation()
  if scripting:
    window.addScripting(selector)
  return window
