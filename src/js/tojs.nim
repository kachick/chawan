import options
import tables
import unicode

import bindings/quickjs
import io/promise
import js/arraybuffer
import js/dict
import js/error
import js/opaque
import js/typeptr
import types/opt

# Convert Nim types to the corresponding JavaScript type.
# This does not work with var objects.
proc toJS*(ctx: JSContext, s: string): JSValue
proc toJS*(ctx: JSContext, r: Rune): JSValue
proc toJS*(ctx: JSContext, n: int64): JSValue
proc toJS*(ctx: JSContext, n: int32): JSValue
proc toJS*(ctx: JSContext, n: int): JSValue
proc toJS*(ctx: JSContext, n: uint16): JSValue
proc toJS*(ctx: JSContext, n: uint32): JSValue
proc toJS*(ctx: JSContext, n: uint64): JSValue
proc toJS*(ctx: JSContext, n: SomeFloat): JSValue
proc toJS*(ctx: JSContext, b: bool): JSValue
proc toJS*[U, V](ctx: JSContext, t: Table[U, V]): JSValue
proc toJS*(ctx: JSContext, opt: Option): JSValue
proc toJS*[T, E](ctx: JSContext, opt: Result[T, E]): JSValue
proc toJS*(ctx: JSContext, s: seq): JSValue
proc toJS*(ctx: JSContext, e: enum): JSValue
proc toJS*(ctx: JSContext, j: JSValue): JSValue
proc toJS*[T](ctx: JSContext, promise: Promise[T]): JSValue
proc toJS*[T, E](ctx: JSContext, promise: Promise[Result[T, E]]): JSValue
proc toJS*(ctx: JSContext, promise: EmptyPromise): JSValue
proc toJS*(ctx: JSContext, obj: ref object): JSValue
proc toJS*(ctx: JSContext, err: JSError): JSValue
proc toJS*(ctx: JSContext, f: JSCFunction): JSValue

# Convert Nim types to the corresponding JavaScript type, with knowledge of
# the parent object.
# This supports conversion of var object types.
#
# The idea here is to allow conversion of var objects to quasi-reference types
# by saving a pointer to their ancestor and incrementing/decrementing the
# ancestor's reference count instead.
proc toJSP*(ctx: JSContext, parent: ref object, child: var object): JSValue
proc toJSP*(ctx: JSContext, parent: ptr object, child: var object): JSValue

# Avoid accidentally calling toJSP on objects that we have explicit toJS
# converters for.
template makeToJSP(typ: untyped) =
  template toJSP*(ctx: JSContext, parent: ref object, child: var typ): JSValue =
    toJS(ctx, child)
  template toJSP*(ctx: JSContext, parent: ptr object, child: var typ): JSValue =
    toJS(ctx, child)
makeToJSP(Table)
makeToJSP(Option)
makeToJSP(Result)
makeToJSP(JSValue)
makeToJSP(JSDict)

proc defineProperty(ctx: JSContext, this: JSValue, name: string,
    prop: JSValue, flags = cint(0)) =
  if JS_DefinePropertyValueStr(ctx, this, cstring(name), prop, flags) <= 0:
    raise newException(Defect, "Failed to define property string: " & name)

proc defineProperty*[T](ctx: JSContext, this: JSValue, name: string, prop: T,
    flags = cint(0)) =
  defineProperty(ctx, this, name, toJS(ctx, prop), flags)

proc definePropertyE*[T](ctx: JSContext, this: JSValue, name: string,
    prop: T) =
  defineProperty(ctx, this, name, prop, JS_PROP_ENUMERABLE)

proc definePropertyCWE*[T](ctx: JSContext, this: JSValue, name: string,
    prop: T) =
  defineProperty(ctx, this, name, prop, JS_PROP_C_W_E)

proc toJS*(ctx: JSContext, s: cstring): JSValue =
  return JS_NewString(ctx, s)

proc toJS*(ctx: JSContext, s: string): JSValue =
  return toJS(ctx, cstring(s))

proc toJS*(ctx: JSContext, r: Rune): JSValue =
  return toJS(ctx, $r)

proc toJS*(ctx: JSContext, n: int32): JSValue =
  return JS_NewInt32(ctx, n)

proc toJS*(ctx: JSContext, n: int64): JSValue =
  return JS_NewInt64(ctx, n)

# Always int32, so we don't risk 32-bit only breakage.
proc toJS*(ctx: JSContext, n: int): JSValue =
  return toJS(ctx, int32(n))

proc toJS*(ctx: JSContext, n: uint16): JSValue =
  return JS_NewUint32(ctx, uint32(n))

proc toJS*(ctx: JSContext, n: uint32): JSValue =
  return JS_NewUint32(ctx, n)

proc toJS*(ctx: JSContext, n: uint64): JSValue =
  #TODO this is incorrect
  return JS_NewFloat64(ctx, float64(n))

proc toJS*(ctx: JSContext, n: SomeFloat): JSValue =
  return JS_NewFloat64(ctx, float64(n))

proc toJS*(ctx: JSContext, b: bool): JSValue =
  return JS_NewBool(ctx, b)

proc toJS*[U, V](ctx: JSContext, t: Table[U, V]): JSValue =
  let obj = JS_NewObject(ctx)
  if not JS_IsException(obj):
    for k, v in t:
      definePropertyCWE(ctx, obj, k, v)
  return obj

proc toJS*(ctx: JSContext, opt: Option): JSValue =
  if opt.isSome:
    return toJS(ctx, opt.get)
  return JS_NULL

proc toJS[T, E](ctx: JSContext, opt: Result[T, E]): JSValue =
  if opt.isSome:
    when not (T is void):
      return toJS(ctx, opt.get)
    else:
      return JS_UNDEFINED
  else:
    when not (E is void):
      let res = toJS(ctx, opt.error)
      if not JS_IsNull(res):
        return JS_Throw(ctx, res)
    else:
      return JS_NULL

proc toJS(ctx: JSContext, s: seq): JSValue =
  let a = JS_NewArray(ctx)
  if not JS_IsException(a):
    for i in 0..s.high:
      let j = toJS(ctx, s[i])
      if JS_IsException(j):
        return j
      if JS_DefinePropertyValueInt64(ctx, a, int64(i), j,
          JS_PROP_C_W_E or JS_PROP_THROW) < 0:
        return JS_EXCEPTION
  return a

proc defineUnforgeable*(ctx: JSContext, this: JSValue) =
  if unlikely(JS_IsException(this)):
    return
  let ctxOpaque = ctx.getOpaque()
  let classid = JS_GetClassID(this)
  ctxOpaque.unforgeable.withValue(classid, uf):
    JS_SetPropertyFunctionList(ctx, this, addr uf[][0], cint(uf[].len))

proc toJSP0(ctx: JSContext, p, tp: pointer, needsref: var bool): JSValue =
  JS_GetRuntime(ctx).getOpaque().plist.withValue(p, obj):
    # a JSValue already points to this object.
    return JS_DupValue(ctx, JS_MKPTR(JS_TAG_OBJECT, obj[]))
  let ctxOpaque = ctx.getOpaque()
  let clazz = ctxOpaque.typemap[tp]
  let jsObj = JS_NewObjectClass(ctx, clazz)
  setOpaque(ctx, jsObj, p)
  # We are "constructing" a new JS object, so we must add unforgeable
  # properties here.
  defineUnforgeable(ctx, jsObj) # not an exception
  needsref = true
  if unlikely(ctxOpaque.htmldda == clazz):
    JS_SetIsHTMLDDA(ctx, jsObj)
  return jsObj

proc toJSRefObj(ctx: JSContext, obj: ref object): JSValue =
  if obj == nil:
    return JS_NULL
  let p = cast[pointer](obj)
  let tp = getTypePtr(obj)
  var needsref = false
  let val = toJSP0(ctx, p, tp, needsref)
  if needsref:
    GC_ref(obj)
  return val

proc toJS*(ctx: JSContext, obj: ref object): JSValue =
  return toJSRefObj(ctx, obj)

proc toJS(ctx: JSContext, e: enum): JSValue =
  return toJS(ctx, $e)

proc toJS(ctx: JSContext, j: JSValue): JSValue =
  return j

proc toJS(ctx: JSContext, promise: EmptyPromise): JSValue =
  var resolving_funcs: array[2, JSValue]
  let jsPromise = JS_NewPromiseCapability(ctx, addr resolving_funcs[0])
  if JS_IsException(jsPromise):
    return JS_EXCEPTION
  promise.then(proc() =
    var x = JS_UNDEFINED
    let res = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, addr x)
    JS_FreeValue(ctx, res)
    JS_FreeValue(ctx, resolving_funcs[0])
    JS_FreeValue(ctx, resolving_funcs[1]))
  return jsPromise

proc toJS[T](ctx: JSContext, promise: Promise[T]): JSValue =
  var resolving_funcs: array[2, JSValue]
  let jsPromise = JS_NewPromiseCapability(ctx, addr resolving_funcs[0])
  if JS_IsException(jsPromise):
    return JS_EXCEPTION
  promise.then(proc(x: T) =
    var x = toJS(ctx, x)
    let res = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, addr x)
    JS_FreeValue(ctx, res)
    JS_FreeValue(ctx, x)
    JS_FreeValue(ctx, resolving_funcs[0])
    JS_FreeValue(ctx, resolving_funcs[1]))
  return jsPromise

proc toJS[T, E](ctx: JSContext, promise: Promise[Result[T, E]]): JSValue =
  var resolving_funcs: array[2, JSValue]
  let jsPromise = JS_NewPromiseCapability(ctx, addr resolving_funcs[0])
  if JS_IsException(jsPromise):
    return JS_EXCEPTION
  promise.then(proc(x: Result[T, E]) =
    if x.isOk:
      let x = when T is void:
        JS_UNDEFINED
      else:
        toJS(ctx, x.get)
      let res = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, unsafeAddr x)
      JS_FreeValue(ctx, res)
      JS_FreeValue(ctx, x)
    else: # err
      let x = when E is void:
        JS_UNDEFINED
      else:
        toJS(ctx, x.error)
      let res = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, unsafeAddr x)
      JS_FreeValue(ctx, res)
      JS_FreeValue(ctx, x)
    JS_FreeValue(ctx, resolving_funcs[0])
    JS_FreeValue(ctx, resolving_funcs[1]))
  return jsPromise

proc toJS*(ctx: JSContext, err: JSError): JSValue =
  if err.e notin QuickJSErrors:
    return toJSRefObj(ctx, err)
  var msg = toJS(ctx, err.message)
  if JS_IsException(msg):
    return msg
  let ctor = ctx.getOpaque().err_ctors[err.e]
  let ret = JS_CallConstructor(ctx, ctor, 1, addr msg)
  JS_FreeValue(ctx, msg)
  return ret

proc toJS*(ctx: JSContext, f: JSCFunction): JSValue =
  return JS_NewCFunction(ctx, f, cstring"", 0)

proc toJS*(ctx: JSContext, abuf: JSArrayBuffer): JSValue =
  return JS_NewArrayBuffer(ctx, abuf.p, abuf.len, abuf.dealloc, nil, false)

proc toJS*(ctx: JSContext, u8a: JSUint8Array): JSValue =
  var jsabuf = toJS(ctx, u8a.abuf)
  let ctor = ctx.getOpaque().Uint8Array_ctor
  let ret = JS_CallConstructor(ctx, ctor, 1, addr jsabuf)
  JS_FreeValue(ctx, jsabuf)
  return ret

proc toJSP(ctx: JSContext, parent: ref object, child: var object): JSValue =
  let p = addr child
  # Save parent as the original ancestor for this tree.
  JS_GetRuntime(ctx).getOpaque().refmap[p] = (
    (proc() =
      GC_ref(parent)),
    (proc() =
      GC_unref(parent))
  )
  let tp = getTypePtr(child)
  var needsref = false
  let val = toJSP0(ctx, p, tp, needsref)
  if needsref:
    GC_ref(parent)
  return val

proc toJSP(ctx: JSContext, parent: ptr object, child: var object): JSValue =
  let p = addr child
  # Increment the reference count of parent's root ancestor, and save the
  # increment/decrement callbacks for the child as well.
  let rtOpaque = JS_GetRuntime(ctx).getOpaque()
  let ru = rtOpaque.refmap[parent]
  ru.cref()
  rtOpaque.refmap[p] = ru
  let tp = getTypePtr(child)
  return toJSP0(ctx, p, tp)
