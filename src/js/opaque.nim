import std/tables

import bindings/quickjs
import js/error
import types/opt

type
  JSSymbolRefs* = enum
    ITERATOR = "iterator"
    ASYNC_ITERATOR = "asyncIterator"
    TO_STRING_TAG = "toStringTag"

  JSStrRefs* = enum
    DONE = "done"
    VALUE = "value"
    NEXT = "next"
    PROTOTYPE = "prototype"
    THEN = "then"

  JSContextOpaque* = ref object
    creg*: Table[string, JSClassID]
    typemap*: Table[pointer, JSClassID]
    ctors*: Table[JSClassID, JSValue]
    parents*: Table[JSClassID, JSClassID]
    # Parent unforgeables are merged on class creation.
    # (i.e. to set all unforgeables on the prototype chain, it is enough to set)
    # `unforgeable[classid]'.)
    unforgeable*: Table[JSClassID, seq[JSCFunctionListEntry]]
    gclaz*: string
    gparent*: JSClassID
    sym_refs*: array[JSSymbolRefs, JSAtom]
    str_refs*: array[JSStrRefs, JSAtom]
    Array_prototype_values*: JSValue
    Object_prototype_valueOf*: JSValue
    Uint8Array_ctor*: JSValue
    Set_ctor*: JSValue
    err_ctors*: array[JSErrorEnum, JSValue]
    htmldda*: JSClassID # only one of these exists: document.all.

  JSFinalizerFunction* = proc(rt: JSRuntime, val: JSValue) {.nimcall.}

  JSRuntimeOpaque* = ref object
    plist*: Table[pointer, pointer] # Nim, JS
    flist*: seq[seq[JSCFunctionListEntry]]
    fins*: Table[JSClassID, JSFinalizerFunction]
    refmap*: Table[pointer, tuple[cref, cunref: (proc() {.closure.})]]
    destroying*: pointer

func newJSContextOpaque*(ctx: JSContext): JSContextOpaque =
  let opaque = JSContextOpaque()
  block: # get well-known symbols and other functions
    let global = JS_GetGlobalObject(ctx)
    block:
      let sym = JS_GetPropertyStr(ctx, global, "Symbol")
      for s in JSSymbolRefs:
        let name = $s
        let val = JS_GetPropertyStr(ctx, sym, cstring(name))
        assert JS_IsSymbol(val)
        opaque.sym_refs[s] = JS_ValueToAtom(ctx, val)
        JS_FreeValue(ctx, val)
      JS_FreeValue(ctx, sym)
      for s in JSStrRefs:
        let ss = $s
        opaque.str_refs[s] = JS_NewAtomLen(ctx, cstring(ss), csize_t(ss.len))
    block:
      let arrproto = JS_GetClassProto(ctx, JS_CLASS_ARRAY)
      opaque.Array_prototype_values = JS_GetPropertyStr(ctx, arrproto,
        "values")
      JS_FreeValue(ctx, arrproto)
    block:
      let objproto = JS_GetClassProto(ctx, JS_CLASS_OBJECT)
      opaque.Object_prototype_valueOf = JS_GetPropertyStr(ctx, objproto, "valueOf")
      JS_FreeValue(ctx, objproto)
    block:
      opaque.Set_ctor = JS_GetPropertyStr(ctx, global, "Set")
      assert not JS_IsException(opaque.Set_ctor)
    block:
      opaque.Uint8Array_ctor = JS_GetPropertyStr(ctx, global, "Uint8Array")
      assert not JS_IsException(opaque.Uint8Array_ctor)
    for e in JSErrorEnum:
      let s = $e
      let err = JS_GetPropertyStr(ctx, global, cstring(s))
      opaque.err_ctors[e] = err
    JS_FreeValue(ctx, global)
  return opaque

func getOpaque*(ctx: JSContext): JSContextOpaque =
  return cast[JSContextOpaque](JS_GetContextOpaque(ctx))

func getOpaque*(rt: JSRuntime): JSRuntimeOpaque =
  return cast[JSRuntimeOpaque](JS_GetRuntimeOpaque(rt))

func isGlobal*(ctx: JSContext, class: string): bool =
  assert class != ""
  return ctx.getOpaque().gclaz == class

proc setOpaque*(ctx: JSContext, val: JSValue, opaque: pointer) =
  let rt = JS_GetRuntime(ctx)
  let rtOpaque = rt.getOpaque()
  let p = JS_VALUE_GET_PTR(val)
  rtOpaque.plist[opaque] = p
  JS_SetOpaque(val, opaque)

# getOpaque, but doesn't work for global objects.
func getOpaque0*(val: JSValue): pointer =
  if JS_VALUE_GET_TAG(val) == JS_TAG_OBJECT:
    return JS_GetOpaque(val, JS_GetClassID(val))

func getGlobalOpaque0*(ctx: JSContext, val: JSValue = JS_UNDEFINED):
    Opt[pointer] =
  let global = JS_GetGlobalObject(ctx)
  if JS_IsUndefined(val) or val == global:
    let opaque = JS_GetOpaque(global, JS_CLASS_OBJECT)
    JS_FreeValue(ctx, global)
    return ok(opaque)
  JS_FreeValue(ctx, global)
  return err()

func getGlobalOpaque*(ctx: JSContext, T: typedesc, val: JSValue = JS_UNDEFINED): Opt[T] =
  return ok(cast[T](?getGlobalOpaque0(ctx, val)))

func getOpaque*(ctx: JSContext, val: JSValue, class: string): pointer =
  # Unfortunately, we can't change the global object's class.
  #TODO: or maybe we can, but I'm afraid of breaking something.
  # This needs further investigation.
  if ctx.isGlobal(class):
    let global = JS_GetGlobalObject(ctx)
    let opaque = JS_GetOpaque(global, JS_CLASS_OBJECT)
    JS_FreeValue(ctx, global)
    return opaque
  return getOpaque0(val)

func getOpaque*[T: ref object](ctx: JSContext, val: JSValue): T =
  cast[T](getOpaque(ctx, val, $T))
