import std/macros
import std/options
import std/strutils
import std/tables
import std/unicode

import bindings/quickjs
import io/promise
import js/arraybuffer
import js/dict
import js/error
import js/opaque
import js/tojs
import types/opt

proc fromJS*[T](ctx: JSContext, val: JSValue): JSResult[T]

func isInstanceOfNonGlobal(ctx: JSContext, val: JSValue, class: string): bool =
  let ctxOpaque = ctx.getOpaque()
  var classid = JS_GetClassID(val)
  let tclassid = ctxOpaque.creg[class]
  var found = false
  while true:
    if classid == tclassid:
      found = true
      break
    ctxOpaque.parents.withValue(classid, val):
      classid = val[]
    do:
      classid = 0 # not defined by Chawan; assume parent is Object.
    if classid == 0:
      break
  return found

func isInstanceOfGlobal(ctx: JSContext, val: JSValue, class: string): bool =
  let ctxOpaque = ctx.getOpaque()
  #TODO gparent only works for a single level. (But this is not really a
  # problem right now, because our global objects have at most one inheritance
  # level.)
  if ctx.isGlobal(class) or ctxOpaque.creg[class] == ctxOpaque.gparent:
    # undefined -> global
    if JS_IsUndefined(val):
      return true
    if JS_IsObject(val):
      let global = JS_GetGlobalObject(ctx)
      let p0 = JS_VALUE_GET_PTR(global)
      let p1 = JS_VALUE_GET_PTR(val)
      JS_FreeValue(ctx, global)
      if p0 == p1:
        return true
  return false

func isInstanceOf*(ctx: JSContext, val: JSValue, class: string): bool =
  return ctx.isInstanceOfGlobal(val, class) or
    ctx.isInstanceOfNonGlobal(val, class)

func toString(ctx: JSContext, val: JSValue): Opt[string] =
  var plen: csize_t
  let outp = JS_ToCStringLen(ctx, addr plen, val) # cstring
  if outp != nil:
    var ret = newString(plen)
    if plen != 0:
      prepareMutation(ret)
      copyMem(addr ret[0], outp, plen)
    result = ok(ret)
    JS_FreeCString(ctx, outp)

func fromJSString(ctx: JSContext, val: JSValue): JSResult[string] =
  var plen: csize_t
  let outp = JS_ToCStringLen(ctx, addr plen, val) # cstring
  if outp == nil:
    return err()
  var ret = newString(plen)
  if plen != 0:
    prepareMutation(ret)
    copyMem(addr ret[0], outp, plen)
  JS_FreeCString(ctx, outp)
  return ok(ret)

func fromJSString2(ctx: JSContext, val: JSValue): JSResult[JSString] =
  return ok(JS_VALUE_GET_STRING(val))

func fromJSInt[T: SomeInteger](ctx: JSContext, val: JSValue):
    JSResult[T] =
  when T is int:
    # Always int32, so we don't risk 32-bit only breakage.
    # If int64 is needed, specify it explicitly.
    var ret: int32
    if JS_ToInt32(ctx, addr ret, val) < 0:
      return err()
    return ok(int(ret))
  elif T is uint:
    var ret: uint32
    if JS_ToUint32(ctx, addr ret, val) < 0:
      return err()
    return ok(uint(ret))
  elif T is int32:
    var ret: int32
    if JS_ToInt32(ctx, addr ret, val) < 0:
      return err()
    return ok(ret)
  elif T is int64:
    var ret: int64
    if JS_ToInt64(ctx, addr ret, val) < 0:
      return err()
    return ok(ret)
  elif T is uint32:
    var ret: uint32
    if JS_ToUint32(ctx, addr ret, val) < 0:
      return err()
    return ok(ret)
  elif T is uint64:
    var ret: uint32
    if JS_ToUint32(ctx, addr ret, val) < 0:
      return err()
    return ok(cast[uint64](ret))

proc fromJSFloat[T: SomeFloat](ctx: JSContext, val: JSValue):
    JSResult[T] =
  var f64: float64
  if JS_ToFloat64(ctx, addr f64, val) < 0:
    return err()
  return ok(cast[T](f64))

macro fromJSTupleBody(a: tuple) =
  let len = a.getType().len - 1
  let done = ident("done")
  result = newStmtList(quote do:
    var `done`: bool)
  for i in 0..<len:
    result.add(quote do:
      let next = JS_Call(ctx, next_method, it, 0, nil)
      if JS_IsException(next):
        return err()
      defer: JS_FreeValue(ctx, next)
      let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[DONE])
      if JS_IsException(doneVal):
        return err()
      defer: JS_FreeValue(ctx, doneVal)
      `done` = ?fromJS[bool](ctx, doneVal)
      if `done`:
        JS_ThrowTypeError(ctx, "Too few arguments in sequence (got %d, expected %d)", `i`, `len`)
        return err()
      let valueVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[VALUE])
      if JS_IsException(valueVal):
        return err()
      defer: JS_FreeValue(ctx, valueVal)
      let genericRes = fromJS[typeof(`a`[`i`])](ctx, valueVal)
      if genericRes.isErr: # exception
        return err()
      `a`[`i`] = genericRes.get
    )
    if i == len - 1:
      result.add(quote do:
        let next = JS_Call(ctx, next_method, it, 0, nil)
        if JS_IsException(next):
          return err()
        defer: JS_FreeValue(ctx, next)
        let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[DONE])
        `done` = ?fromJS[bool](ctx, doneVal)
        var i = `i`
        # we're emulating a sequence, so we must query all remaining parameters too:
        while not `done`:
          inc i
          let next = JS_Call(ctx, next_method, it, 0, nil)
          if JS_IsException(next):
            return err()
          defer: JS_FreeValue(ctx, next)
          let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[DONE])
          if JS_IsException(doneVal):
            return err()
          defer: JS_FreeValue(ctx, doneVal)
          `done` = ?fromJS[bool](ctx, doneVal)
          if `done`:
            let msg = "Too many arguments in sequence (got " & $i &
              ", expected " & $`len` & ")"
            return err(newTypeError(msg))
          JS_FreeValue(ctx, JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[VALUE]))
      )

proc fromJSTuple[T: tuple](ctx: JSContext, val: JSValue): JSResult[T] =
  let itprop = JS_GetProperty(ctx, val, ctx.getOpaque().sym_refs[ITERATOR])
  if JS_IsException(itprop):
    return err()
  defer: JS_FreeValue(ctx, itprop)
  let it = JS_Call(ctx, itprop, val, 0, nil)
  if JS_IsException(it):
    return err()
  defer: JS_FreeValue(ctx, it)
  let next_method = JS_GetProperty(ctx, it, ctx.getOpaque().str_refs[NEXT])
  if JS_IsException(next_method):
    return err()
  defer: JS_FreeValue(ctx, next_method)
  var x: T
  fromJSTupleBody(x)
  return ok(x)

proc fromJSSeq[T](ctx: JSContext, val: JSValue): JSResult[seq[T]] =
  let itprop = JS_GetProperty(ctx, val, ctx.getOpaque().sym_refs[ITERATOR])
  if JS_IsException(itprop):
    return err()
  defer: JS_FreeValue(ctx, itprop)
  let it = JS_Call(ctx, itprop, val, 0, nil)
  if JS_IsException(it):
    return err()
  defer: JS_FreeValue(ctx, it)
  let next_method = JS_GetProperty(ctx, it, ctx.getOpaque().str_refs[NEXT])
  if JS_IsException(next_method):
    return err()
  defer: JS_FreeValue(ctx, next_method)
  var s = newSeq[T]()
  while true:
    let next = JS_Call(ctx, next_method, it, 0, nil)
    if JS_IsException(next):
      return err()
    defer: JS_FreeValue(ctx, next)
    let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[DONE])
    if JS_IsException(doneVal):
      return err()
    defer: JS_FreeValue(ctx, doneVal)
    let done = ?fromJS[bool](ctx, doneVal)
    if done:
      break
    let valueVal = JS_GetProperty(ctx, next, ctx.getOpaque().str_refs[VALUE])
    if JS_IsException(valueVal):
      return err()
    defer: JS_FreeValue(ctx, valueVal)
    let genericRes = fromJS[typeof(s[0])](ctx, valueVal)
    if genericRes.isNone: # exception
      return err()
    s.add(genericRes.get)
  return ok(s)

proc fromJSSet[T](ctx: JSContext, val: JSValue): Opt[set[T]] =
  let itprop = JS_GetProperty(ctx, val, ctx.getOpaque().sym_refs[ITERATOR])
  if JS_IsException(itprop):
    return err()
  defer: JS_FreeValue(ctx, itprop)
  let it = JS_Call(ctx, itprop, val, 0, nil)
  if JS_IsException(it):
    return err()
  defer: JS_FreeValue(ctx, it)
  let next_method = JS_GetProperty(ctx, it, ctx.getOpaque().str_refs[NEXT])
  if JS_IsException(next_method):
    return err()
  defer: JS_FreeValue(ctx, next_method)
  var s: set[T]
  while true:
    let next = JS_Call(ctx, next_method, it, 0, nil)
    if JS_IsException(next):
      return err()
    defer: JS_FreeValue(ctx, next)
    let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().done)
    if JS_IsException(doneVal):
      return err()
    defer: JS_FreeValue(ctx, doneVal)
    let done = ?fromJS[bool](ctx, doneVal)
    if done:
      break
    let valueVal = JS_GetProperty(ctx, next, ctx.getOpaque().value)
    if JS_IsException(valueVal):
      return err()
    defer: JS_FreeValue(ctx, valueVal)
    let genericRes = ?fromJS[typeof(s.items)](ctx, valueVal)
    s.incl(genericRes)
  return ok(s)

proc fromJSTable[A, B](ctx: JSContext, val: JSValue): JSResult[Table[A, B]] =
  if not JS_IsObject(val):
    return err(newTypeError("object expected"))
  var ptab: ptr UncheckedArray[JSPropertyEnum]
  var plen: uint32
  let flags = cint(JS_GPN_STRING_MASK)
  if JS_GetOwnPropertyNames(ctx, addr ptab, addr plen, val, flags) == -1:
    # exception
    return err()
  defer:
    for i in 0 ..< plen:
      JS_FreeAtom(ctx, ptab[i].atom)
    js_free(ctx, ptab)
  var res = Table[A, B]()
  for i in 0 ..< plen:
    let atom = ptab[i].atom
    let k = JS_AtomToValue(ctx, atom)
    defer: JS_FreeValue(ctx, k)
    let kn = ?fromJS[A](ctx, k)
    let v = JS_GetProperty(ctx, val, atom)
    defer: JS_FreeValue(ctx, v)
    let vn = ?fromJS[B](ctx, v)
    res[kn] = vn
  return ok(res)

#TODO varargs
proc fromJSFunction1*[T, U](ctx: JSContext, val: JSValue):
    proc(x: U): JSResult[T] =
  #TODO this leaks memory!
  let dupval = JS_DupValue(ctx, JS_DupValue(ctx, val)) # save
  return proc(x: U): JSResult[T] =
    var arg1 = toJS(ctx, x)
    #TODO exceptions?
    let ret = JS_Call(ctx, dupval, JS_UNDEFINED, 1, addr arg1)
    result = fromJS[T](ctx, ret)
    JS_FreeValue(ctx, ret)

proc isErrType(rt: NimNode): bool =
  let rtType = rt[0]
  let errType = getTypeInst(Err)
  return errType.sameType(rtType) and rtType.sameType(errType)

# unpack brackets
proc getRealTypeFun(x: NimNode): NimNode =
  var x = x.getTypeImpl()
  while true:
    if x.kind == nnkBracketExpr and x.len == 2:
      x = x[1].getTypeImpl()
      continue
    break
  return x

macro unpackReturnType(f: typed) =
  var x = f.getRealTypeFun()
  let params = x.findChild(it.kind == nnkFormalParams)
  let rv = params[0]
  if rv.isErrType():
    return quote do: void
  let rvv = rv[1]
  return quote do: `rvv`

macro unpackArg0(f: typed) =
  var x = f.getRealTypeFun()
  let params = x.findChild(it.kind == nnkFormalParams)
  let rv = params[1]
  doAssert rv.kind == nnkIdentDefs
  let rvv = rv[1]
  return quote do: `rvv`

proc fromJSFunction[T](ctx: JSContext, val: JSValue):
    JSResult[T] =
  #TODO all args...
  if not JS_IsFunction(ctx, val):
    return err(newTypeError("function expected"))
  return ok(
    fromJSFunction1[
      typeof(unpackReturnType(T)),
      typeof(unpackArg0(T))
    ](ctx, val))

template optionType[T](o: type Option[T]): auto =
  T

# wrap
proc fromJSOption[T](ctx: JSContext, val: JSValue): JSResult[Option[T]] =
  if JS_IsUndefined(val):
    #TODO what about null?
    return err()
  let res = ?fromJS[T](ctx, val)
  return ok(option(res))

# wrap
proc fromJSOpt[T](ctx: JSContext, val: JSValue): JSResult[T] =
  if JS_IsUndefined(val):
    #TODO what about null?
    return err()
  let res = fromJS[T.valType](ctx, val)
  if res.isErr:
    return ok(opt(T.valType))
  return ok(opt(res.get))

proc fromJSBool(ctx: JSContext, val: JSValue): JSResult[bool] =
  let ret = JS_ToBool(ctx, val)
  if ret == -1: # exception
    return err()
  if ret == 0:
    return ok(false)
  return ok(true)

proc fromJSEnum[T: enum](ctx: JSContext, val: JSValue): JSResult[T] =
  if JS_IsException(val):
    return err()
  let s = ?toString(ctx, val)
  try:
    return ok(parseEnum[T](s))
  except ValueError:
    return err(newTypeError("`" & s &
      "' is not a valid value for enumeration " & $T))

proc fromJSPObj0(ctx: JSContext, val: JSValue, t: string):
    JSResult[pointer] =
  if JS_IsException(val):
    return err(nil)
  if JS_IsNull(val):
    return ok(nil)
  if ctx.isInstanceOfGlobal(val, t):
    return ok(?getGlobalOpaque0(ctx, val))
  if not JS_IsObject(val):
    return err(newTypeError("Value is not an object"))
  if not isInstanceOfNonGlobal(ctx, val, t):
    let errmsg = t & " expected"
    JS_ThrowTypeError(ctx, cstring(errmsg))
    return err(newTypeError(errmsg))
  let classid = JS_GetClassID(val)
  let op = JS_GetOpaque(val, classid)
  return ok(op)

proc fromJSObject[T: ref object](ctx: JSContext, val: JSValue): JSResult[T] =
  return ok(cast[T](?fromJSPObj0(ctx, val, $T)))

proc fromJSVoid(ctx: JSContext, val: JSValue): JSResult[void] =
  if JS_IsException(val):
    #TODO maybe wrap or something
    return err()
  return ok()

proc fromJSDict[T: JSDict](ctx: JSContext, val: JSValue): JSResult[T] =
  if not JS_IsUndefined(val) and not JS_IsNull(val) and not JS_IsObject(val):
    return err(newTypeError("Dictionary is not an object"))
  #TODO throw on missing required values
  var d: T
  if JS_IsObject(val):
    for k, v in d.fieldPairs:
      let esm = JS_GetPropertyStr(ctx, val, k)
      if not JS_IsUndefined(esm):
        v = ?fromJS[typeof(v)](ctx, esm)
  return ok(d)

proc fromJSArrayBuffer(ctx: JSContext, val: JSValue): JSResult[JSArrayBuffer] =
  var len: csize_t
  let p = JS_GetArrayBuffer(ctx, addr len, val)
  if p == nil:
    return err()
  let abuf = JSArrayBuffer(
    len: len,
    p: cast[ptr UncheckedArray[uint8]](p)
  )
  return ok(abuf)

proc fromJSArrayBufferView(ctx: JSContext, val: JSValue):
    JSResult[JSArrayBufferView] =
  var offset: csize_t
  var nmemb: csize_t
  var nsize: csize_t
  let jsbuf = JS_GetTypedArrayBuffer(ctx, val, addr offset, addr nmemb,
    addr nsize)
  let abuf = ?fromJSArrayBuffer(ctx, jsbuf)
  let view = JSArrayBufferView(
    abuf: abuf,
    offset: offset,
    nmemb: nmemb,
    nsize: nsize
  )
  return ok(view)

proc promiseThenCallback(ctx: JSContext, this_val: JSValue, argc: cint,
    argv: ptr JSValue, magic: cint, func_data: ptr JSValue): JSValue {.cdecl.} =
  let op = JS_GetOpaque(func_data[], JS_GetClassID(func_data[]))
  let p = cast[EmptyPromise](op)
  p.resolve()
  GC_unref(p)
  return JS_UNDEFINED

proc fromJSEmptyPromise(ctx: JSContext, val: JSValue): JSResult[EmptyPromise] =
  if not JS_IsObject(val):
    return err(newTypeError("Value is not an object"))
  #TODO I have a feeling this leaks memory in some cases :(
  var p = EmptyPromise()
  GC_ref(p)
  var tmp = JS_NewObject(ctx)
  JS_SetOpaque(tmp, cast[pointer](p))
  var fun = JS_NewCFunctionData(ctx, promiseThenCallback, 0, 0, 1, addr tmp)
  let res = JS_Invoke(ctx, val, ctx.getOpaque().str_refs[THEN], 1, addr fun)
  if JS_IsException(res):
    return err()
  return ok(p)

type FromJSAllowedT = (object and not (Result|Option|Table|JSValue|JSDict|
  JSArrayBuffer|JSArrayBufferView|JSUint8Array))

proc fromJS*[T](ctx: JSContext, val: JSValue): JSResult[T] =
  when T is string:
    return fromJSString(ctx, val)
  elif T is JSString:
    return fromJSString2(ctx, val)
  elif T is (proc):
    return fromJSFunction[T](ctx, val)
  elif T is Option:
    return fromJSOption[optionType(T)](ctx, val)
  elif T is Opt: # unwrap
    return fromJSOpt[T](ctx, val)
  elif T is seq:
    return fromJSSeq[typeof(result.get.items)](ctx, val)
  elif T is set:
    return fromJSSet[typeof(result.get.items)](ctx, val)
  elif T is tuple:
    return fromJSTuple[T](ctx, val)
  elif T is bool:
    return fromJSBool(ctx, val)
  elif typeof(result).valType is Table:
    return fromJSTable[typeof(result.get.keys),
      typeof(result.get.values)](ctx, val)
  elif T is SomeInteger:
    return fromJSInt[T](ctx, val)
  elif T is SomeFloat:
    return fromJSFloat[T](ctx, val)
  elif T is enum:
    return fromJSEnum[T](ctx, val)
  elif T is JSValue:
    return ok(val)
  elif T is EmptyPromise:
    return fromJSEmptyPromise(ctx, val)
  elif T is ref object:
    return fromJSObject[T](ctx, val)
  elif T is void:
    return fromJSVoid(ctx, val)
  elif T is JSDict:
    return fromJSDict[T](ctx, val)
  elif T is JSArrayBuffer:
    return fromJSArrayBuffer(ctx, val)
  elif T is JSArrayBufferView:
    return fromJSArrayBufferView(ctx, val)
  elif compiles(fromJS2(ctx, val, result)):
    fromJS2(ctx, val, result)
  else:
    static:
      error("Unrecognized type " & $T)

const JS_ATOM_TAG_INT = cuint(1u32 shl 31)

func JS_IsNumber*(v: JSAtom): JS_BOOL =
  return (cast[cuint](v) and JS_ATOM_TAG_INT) != 0

func fromJS*[T: string|uint32](ctx: JSContext, atom: JSAtom): Opt[T] =
  when T is SomeNumber:
    if JS_IsNumber(atom):
      return ok(T(cast[uint32](atom) and (not JS_ATOM_TAG_INT)))
  else:
    let val = JS_AtomToValue(ctx, atom)
    return toString(ctx, val)

proc fromJSPObj[T](ctx: JSContext, val: JSValue): JSResult[ptr T] =
  return cast[JSResult[ptr T]](fromJSPObj0(ctx, val, $T))

template fromJSP*[T](ctx: JSContext, val: JSValue): untyped =
  when T is FromJSAllowedT:
    fromJSPObj[T](ctx, val)
  else:
    fromJS[T](ctx, val)
