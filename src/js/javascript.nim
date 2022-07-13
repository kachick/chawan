import options

import bindings/quickjs

export
  JS_NULL, JS_UNDEFINED, JS_FALSE, JS_TRUE, JS_EXCEPTION, JS_UNINITIALIZED

export
  JS_EVAL_TYPE_GLOBAL,
  JS_EVAL_TYPE_MODULE,
  JS_EVAL_TYPE_DIRECT,
  JS_EVAL_TYPE_INDIRECT,
  JS_EVAL_TYPE_MASK,
  JS_EVAL_FLAG_SHEBANG,
  JS_EVAL_FLAG_STRICT,
  JS_EVAL_FLAG_STRIP,
  JS_EVAL_FLAG_COMPILE_ONLY

export JSRuntime, JSContext, JSValue

type
  JSObject* = object
    ctx*: JSContext
    val*: JSValue

  JSContextOpaque* = object
    err*: string

func newJSRuntime*(): JSRuntime =
  result = JS_NewRuntime()

proc newJSContext*(rt: JSRuntime): JSContext =
  result = JS_NewContext(rt)
  let opaque = cast[ptr JSContextOpaque](alloc0(sizeof(JSContextOpaque)))
  opaque.err = ""
  JS_SetContextOpaque(result, opaque)

func getJSObject*(ctx: JSContext, v: JSValue): JSObject =
  result.ctx = ctx
  result.val = v

func getJSObject*(ctx: JSContext, argv: ptr JSValue, i: int): JSObject =
  getJSObject(ctx, cast[ptr JSValue](cast[int](argv) + i * sizeof(JSValue))[])

func newJSObject*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_NewObject(ctx)

func newJSCFunction*(ctx: JSContext, name: string, fun: JSCFunction, argc: int): JSObject =
  result.ctx = ctx
  result.val = JS_NewCFunction(ctx, fun, cstring(name), argc)

func getGlobalObject*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_GetGlobalObject(ctx)

func getException*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_GetException(ctx)

func getProperty*(obj: JSObject, s: string): JSObject =
  result.ctx = obj.ctx
  result.val = JS_GetPropertyStr(obj.ctx, obj.val, cstring(s));

func getOpaque*(ctx: JSContext): ptr JSContextOpaque =
  return cast[ptr JSContextOpaque](JS_GetContextOpaque(ctx))

func toString*(obj: JSObject): Option[string] =
  var plen: int
  let outp = JS_ToCStringLen(obj.ctx, addr plen, obj.val) # cstring
  if outp != nil:
    var ret = newString(plen)
    for i in 0..<plen:
      ret[i] = outp[i]
    result = some(ret)
    JS_FreeCString(obj.ctx, outp) # refc

func `$`*(obj: JSObject): string =
  return obj.toString().get("")

func isUndefined*(obj: JSObject): bool = JS_IsUndefined(obj.val)
func isException*(obj: JSObject): bool = JS_IsException(obj.val)

proc setProperty*(obj: JSObject, name: string, prop: JSObject) =
  discard JS_SetPropertyStr(obj.ctx, obj.val, cstring(name), prop.val)

proc setFunctionProperty*(obj: JSObject, name: string, fun: JSCFunction) =
  obj.setProperty(name, obj.ctx.newJSCFunction(name, fun, 1))
  #  (proc(ctx: JSContext, obj: JSValue, argc: int, argv: ptr JSValue): JSValue {.cdecl.} =
  #    var invoc: seq[JSValue]
  #    for i in 0..<argc:
  #      let arg = cast[ptr JSValue](cast[int](argv) + i * sizeof(JSValue))[]
  #      invoc.add(arg)
  #    return fun(JSObject(ctx: ctx, qjs: obj), invoc)
  #), cstring(name), 1))

proc free*(ctx: JSContext) =
  JS_FreeContext(ctx)

proc free*(rt: JSRuntime) =
  JS_FreeRuntime(rt)

proc free*(obj: JSObject) =
  JS_FreeValue(obj.ctx, obj.val)

proc eval*(ctx: JSContext, s: string, file: string, eval_flags: int): JSObject =
  result.ctx = ctx
  result.val = JS_Eval(ctx, cstring(s), s.len, cstring(file), eval_flags)
