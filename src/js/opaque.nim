import tables

import bindings/quickjs
import js/error

type
  JSSymbolRefs* = enum
    ITERATOR = "iterator"
    ASYNC_ITERATOR = "asyncIterator"
    TO_STRING_TAG = "toStringTag"

  JSStrRefs* = enum
    DONE = "done"
    VALUE = "value"
    NEXT = "next"

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
    sym_refs*: array[JSSymbolRefs, JSAtom]
    str_refs*: array[JSStrRefs, JSAtom]
    Array_prototype_values*: JSValue
    Object_prototype_valueOf*: JSValue
    err_ctors*: array[JSErrorEnum, JSValue]

  JSRuntimeOpaque* = ref object
    plist*: Table[pointer, pointer] # Nim, JS
    flist*: seq[seq[JSCFunctionListEntry]]
    fins*: Table[JSClassID, proc(val: JSValue)]
    refmap*: Table[pointer, tuple[cref, cunref: (proc() {.closure.})]]

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

proc setOpaque*[T](ctx: JSContext, val: JSValue, opaque: T) =
  let rt = JS_GetRuntime(ctx)
  let rtOpaque = rt.getOpaque()
  let p = JS_VALUE_GET_PTR(val)
  rtOpaque.plist[cast[pointer](opaque)] = p
  JS_SetOpaque(val, cast[pointer](opaque))
