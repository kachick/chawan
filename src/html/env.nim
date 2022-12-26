import html/dom
import html/htmlparser
import io/loader
import js/javascript
import types/url

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
proc onLine(navigator: Navigator): bool {.jsfget.} = true # none of your business :)

#TODO NavigatorContentUtils

# NavigatorCookies
# "this website needs cookies to be enabled to function correctly"
# I'll take your incorrectly functioning website over the tracking any day.
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

#func `$`(window: Window): string {.jsfunc.} =
#  "[object Window]"

proc newWindow*(scripting: bool, loader = none(FileLoader)): Window =
  result = Window(
    console: console(),
    navigator: Navigator(),
    loader: loader,
    settings: EnvironmentSettings(
      scripting: scripting
    )
  )
  if scripting:
    let rt = newJSRuntime()
    let ctx = rt.newJSContext()
    result.jsrt = rt
    result.jsctx = ctx
    var global = JS_GetGlobalObject(ctx)
    ctx.registerType(Window, asglobal = true)
    ctx.setOpaque(global, result)
    ctx.setProperty(global, "window", global)
    JS_FreeValue(ctx, global)
    ctx.addconsoleModule()
    ctx.addNavigatorModule()
    ctx.addDOMModule()
    ctx.addURLModule()
    ctx.addHTMLModule()
