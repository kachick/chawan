import html/dom
import html/htmlparser
import io/loader
import js/javascript
import types/url

proc newWindow*(scripting: bool, loader = none(FileLoader)): Window =
  result = Window(
    console: console(),
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
    ctx.addDOMModule()
    ctx.addURLModule()
    ctx.addHTMLModule()
