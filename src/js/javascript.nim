import macros
import options
import streams
import strformat
import strutils
import tables

import bindings/quickjs

export options

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

  JSContextOpaque* = ref object
    creg: Table[string, JSClassID]
    typemap: Table[pointer, JSClassID]
    ctors: Table[JSClassID, JSValue] #TODO TODO TODO free these
    gclaz: string
    sym_iterator: JSAtom
    sym_asyncIterator: JSAtom
    sym_toStringTag: JSAtom
    done: JSAtom
    next: JSAtom
    value: JSAtom

  JSRuntimeOpaque* = ref object
    plist: Table[pointer, pointer]
    flist: seq[seq[JSCFunctionListEntry]]

  JSFunctionList* = openArray[JSCFunctionListEntry]

func getOpaque*(ctx: JSContext): JSContextOpaque =
  return cast[JSContextOpaque](JS_GetContextOpaque(ctx))

func getOpaque*(rt: JSRuntime): JSRuntimeOpaque =
  return cast[JSRuntimeOpaque](JS_GetRuntimeOpaque(rt))

var runtimes {.threadVar.}: seq[JSRuntime]

proc newJSRuntime*(): JSRuntime =
  result = JS_NewRuntime()
  runtimes.add(result)
  var opaque = new(JSRuntimeOpaque)
  GC_ref(opaque)
  JS_SetRuntimeOpaque(result, cast[pointer](opaque))

proc newJSContext*(rt: JSRuntime): JSContext =
  let ctx = JS_NewContext(rt)
  var opaque = new(JSContextOpaque)
  GC_ref(opaque)

  block:
    let global = JS_GetGlobalObject(ctx)
    block:
      let sym = JS_GetPropertyStr(ctx, global, "Symbol")
      block:
        let it = JS_GetPropertyStr(ctx, sym, "iterator")
        assert JS_IsSymbol(it)
        opaque.sym_iterator = JS_ValueToAtom(ctx, it)
        JS_FreeValue(ctx, it)
      block:
        let ait = JS_GetPropertyStr(ctx, sym, "asyncIterator")
        assert JS_IsSymbol(ait)
        opaque.sym_asyncIterator = JS_ValueToAtom(ctx, ait)
        JS_FreeValue(ctx, ait)
      block:
        let ait = JS_GetPropertyStr(ctx, sym, "toStringTag")
        assert JS_IsSymbol(ait)
        opaque.sym_toStringTag = JS_ValueToAtom(ctx, ait)
        JS_FreeValue(ctx, ait)
      block:
        let s = "done"
        opaque.done = JS_NewAtomLen(ctx, cstring(s), csize_t(s.len))
      block:
        let s = "value"
        opaque.value = JS_NewAtomLen(ctx, cstring(s), csize_t(s.len))
      block:
        let s = "next"
        opaque.next = JS_NewAtomLen(ctx, cstring(s), csize_t(s.len))
      JS_FreeValue(ctx, sym)
    JS_FreeValue(ctx, global)

  JS_SetContextOpaque(ctx, cast[pointer](opaque))
  return ctx

proc newJSContextRaw*(rt: JSRuntime): JSContext =
  result = JS_NewContextRaw(rt)

func getJSObject*(ctx: JSContext, v: JSValue): JSObject =
  result.ctx = ctx
  result.val = v

func getJSValue(ctx: JSContext, argv: ptr JSValue, i: int): JSValue {.inline.} =
  cast[ptr JSValue](cast[int](argv) + i * sizeof(JSValue))[]

func newJSObject*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_NewObject(ctx)

func newJSObject*(ctx: JSContext, cid: JSClassID): JSObject =
  result.ctx = ctx
  result.val = JS_NewObjectClass(ctx, cid)

func newJSObject*(ctx: JSContext, proto: JSObject): JSObject =
  result.ctx = ctx
  result.val = JS_NewObjectProto(ctx, proto.val)

func getClass*(ctx: JSContext, class: string): JSClassID =
  # This function *should* never fail.
  ctx.getOpaque().creg[class]

func getClassProto*(ctx: JSContext, cid: JSClassID): JSObject =
  return JSObject(ctx: ctx, val: JS_GetClassProto(ctx, cid))

func findClass*(ctx: JSContext, class: string): Option[JSClassID] =
  let opaque = ctx.getOpaque()
  if class in opaque.creg:
    return some(opaque.creg[class])
  return none(JSClassID)

func newJSObject*(ctx: JSContext, class: string): JSObject =
  result.ctx = ctx
  result.val = JS_NewObjectClass(ctx, ctx.getClass(class))

func newJSCFunction*(ctx: JSContext, name: string, fun: JSCFunction, argc: int = 0, proto = JS_CFUNC_generic, magic = 0): JSValue =
  return JS_NewCFunction2(ctx, fun, cstring(name), cint(argc), proto, cint(magic))

func getGlobalObject*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_GetGlobalObject(ctx)

func getException*(ctx: JSContext): JSObject =
  result.ctx = ctx
  result.val = JS_GetException(ctx)

func getProperty*(obj: JSObject, s: string): JSObject =
  result.ctx = obj.ctx
  result.val = JS_GetPropertyStr(obj.ctx, obj.val, cstring(s));

proc free*(ctx: var JSContext) =
  var opaque = ctx.getOpaque()
  if opaque != nil:
    JS_FreeAtom(ctx, opaque.sym_iterator)
    JS_FreeAtom(ctx, opaque.sym_asyncIterator)
    JS_FreeAtom(ctx, opaque.sym_toStringTag)
    JS_FreeAtom(ctx, opaque.done)
    JS_FreeAtom(ctx, opaque.next)
    GC_unref(opaque)
  JS_FreeContext(ctx)
  ctx = nil

proc free*(rt: var JSRuntime) =
  let opaque = rt.getOpaque()
  GC_unref(opaque)
  JS_FreeRuntime(rt)
  runtimes.del(runtimes.find(rt))
  rt = nil

proc free*(obj: JSObject) =
  JS_FreeValue(obj.ctx, obj.val)
  #TODO maybe? obj.val = JS_NULL

proc setOpaque*[T](obj: JSObject, opaque: T) =
  let rt = JS_GetRuntime(obj.ctx)
  let rtOpaque = rt.getOpaque()
  let p = JS_VALUE_GET_PTR(obj.val)
  let header = cast[ptr JSRefCountHeader](p)
  inc header.ref_count # add jsvalue reference
  rtOpaque.plist[cast[pointer](opaque)] = p
  JS_SetOpaque(obj.val, cast[pointer](opaque))

func isGlobal*(ctx: JSContext, class: string): bool =
  assert class != ""
  return ctx.getOpaque().gclaz == class

# A hack to retrieve a given val's class id.
func getClassID*(val: JSValue): JSClassID =
  const index = sizeof(cint) + # gc_ref_count
              sizeof(uint8) + # gc_mark
              sizeof(uint8) # bit field
  return cast[ptr uint16](cast[int](JS_VALUE_GET_PTR(val)) + index)[]

func getOpaque*(ctx: JSContext, val: JSValue, class: string): pointer =
  # Unfortunately, we can't change the global object's class.
  #TODO: or maybe we can, but I'm afraid of breaking something.
  # This needs further investigation.
  if ctx.isGlobal(class):
    let global = ctx.getGlobalObject()
    let opaque = JS_GetOpaque(global.val, 1) # JS_CLASS_OBJECT
    free(global)
    return opaque
  return JS_GetOpaque(val, val.getClassID())

func getOpaque*(obj: JSObject, class: string): pointer = getOpaque(obj.ctx, obj.val, class)

proc setInterruptHandler*(rt: JSRuntime, cb: JSInterruptHandler, opaque: pointer = nil) =
  JS_SetInterruptHandler(rt, cb, opaque)

func toString*(ctx: JSContext, val: JSValue): Option[string] =
  var plen: csize_t
  let outp = JS_ToCStringLen(ctx, addr plen, val) # cstring
  if outp != nil:
    var ret = newString(plen)
    for i in 0..<plen:
      ret[i] = outp[i]
    result = some(ret)
    JS_FreeCString(ctx, outp)

proc writeException*(ctx: JSContext, s: Stream) =
  let ex = JS_GetException(ctx)
  let str = toString(ctx, ex)
  if str.issome:
    s.write(str.get & '\n')
  let stack = JS_GetPropertyStr(ctx, ex, cstring("stack"));
  if not JS_IsUndefined(stack):
    let str = toString(ctx, stack)
    if str.issome:
      s.write(str.get)
  JS_FreeValue(ctx, stack)
  JS_FreeValue(ctx, ex)

func toString*(obj: JSObject): Option[string] = toString(obj.ctx, obj.val)

func `$`*(obj: JSObject): string =
  return obj.toString().get("")

func isUndefined*(obj: JSObject): bool = JS_IsUndefined(obj.val)
func isNull*(obj: JSObject): bool = JS_IsNull(obj.val)
func isException*(obj: JSObject): bool = JS_IsException(obj.val)
func isError*(obj: JSObject): bool = JS_IsError(obj.ctx, obj.val)

func isGlobal*(obj: JSObject): bool =
  let global = obj.ctx.getGlobalObject()
  result = JS_VALUE_GET_PTR(global.val) == JS_VALUE_GET_PTR(obj.val)

func isInstanceOf*(ctx: JSContext, obj: JSValue, class: string): bool =
  let clazz = ctx.getClass(class)
  if clazz in ctx.getOpaque().ctors:
    let ctor = ctx.getOpaque().ctors[clazz]
    if JS_IsInstanceOf(ctx, obj, ctor) == 1:
      return true
    return false #TODO handle exception?
  else:
    #TODO TODO TODO LegacyNoInterfaceObject has no constructor...
    return false

proc setProperty*(ctx: JSContext, val: JSValue, name: string, prop: JSValue) =
  if JS_SetPropertyStr(ctx, val, cstring(name), prop) <= 0:
    raise newException(Defect, "Failed to set property string: " & name)

proc setProperty*(ctx: JSContext, val: JSValue, name: string, fun: JSCFunction, argc: int = 0) =
  ctx.setProperty(val, name, ctx.newJSCFunction(name, fun, argc))

func newJSClass*(ctx: JSContext, cdef: JSClassDefConst, cctor: JSCFunction, funcs: JSFunctionList, nimt: pointer, parent: JSClassID, asglobal: bool, nointerface: bool): JSClassID {.discardable.} =
  let rt = JS_GetRuntime(ctx)
  discard JS_NewClassID(addr result)
  var ctxOpaque = ctx.getOpaque()
  var rtOpaque = rt.getOpaque()
  if JS_NewClass(rt, result, cdef) != 0:
    raise newException(Defect, "Failed to allocate JS class: " & $cdef.class_name)
  ctxOpaque.typemap[nimt] = result
  ctxOpaque.creg[$cdef.class_name] = result
  var proto: JSValue
  if parent != 0:
    let parentProto = JS_GetClassProto(ctx, parent)
    proto = JS_NewObjectProtoClass(ctx, parentProto, parent)
    JS_FreeValue(ctx, parentProto)
  else:
    proto = JS_NewObject(ctx)
  if funcs.len > 0:
    # We avoid funcs being GC'ed by putting the list in rtOpaque.
    # (QuickJS uses the pointer later.)
    #TODO maybe put them in ctxOpaque instead?
    rtOpaque.flist.add(@funcs)
    JS_SetPropertyFunctionList(ctx, proto, addr rtOpaque.flist[^1][0], cint(funcs.len))
  assert JS_SetProperty(ctx, proto, ctxOpaque.sym_toStringTag, JS_NewString(ctx, cdef.class_name)) == 1
  JS_SetClassProto(ctx, result, proto)
  if asglobal:
    let global = ctx.getGlobalObject()
    assert ctxOpaque.gclaz == ""
    ctxOpaque.gclaz = $cdef.class_name
    if JS_SetPrototype(ctx, global.val, proto) != 1:
      raise newException(Defect, "Failed to set global prototype: " & $cdef.class_name)
    free(global)
  if not nointerface:
    let global = JS_GetGlobalObject(ctx)
    let jctor = ctx.newJSCFunction($cdef.class_name, cctor, 0, JS_CFUNC_constructor)
    JS_SetConstructor(ctx, jctor, proto)
    ctxOpaque.ctors[result] = JS_DupValue(ctx, jctor)
    ctx.setProperty(global, $cdef.class_name, jctor)
    JS_FreeValue(ctx, global)

proc callFunction*(fun: JSObject): JSObject =
  result.ctx = fun.ctx
  let global = JS_GetGlobalObject(fun.ctx)
  result.val = JS_Call(fun.ctx, fun.val, JS_UNDEFINED, 0, nil)
  JS_FreeValue(fun.ctx, global)

proc callFunction*(fun: JSObject, this: JSObject): JSObject =
  result.ctx = fun.ctx
  result.val = JS_Call(fun.ctx, fun.val, this.val, 0, nil)

type FuncParam = tuple[name: string, t: NimNode, val: Option[NimNode], generic: Option[NimNode]]

func getMinArgs(params: seq[FuncParam]): int =
  for i in 0..<params.len:
    let it = params[i]
    if it[2].issome:
      return i
    let t = it.t
    if t.kind == nnkBracketExpr:
      if t.typeKind == varargs.getType().typeKind:
        assert i == params.high, "Not even nim can properly handle this..."
        return i
  return params.len

func fromJSInt[T: SomeInteger](ctx: JSContext, val: JSValue): Option[T] =
  when T is int:
    when sizeof(int) <= sizeof(int32):
      var ret: int32
      if JS_ToInt32(ctx, addr ret, val) < 0:
        return none(T)
      return some(int(ret))
    else:
      var ret: int64
      if JS_ToInt64(ctx, addr ret, val) < 0:
        return none(T)
      return some(int(ret))
  elif T is uint:
    when sizeof(int) <= sizeof(int32):
      var ret: uint32
      if JS_ToUint32(ctx, addr ret, val) < 0:
        return none(T)
      return some(ret)
    else:
      var ret: uint32
      if JS_ToUint32(ctx, addr ret, val) < 0:
        return none(T)
      return some(cast[uint](ret))
  elif T is int32:
    var ret: int32
    if JS_ToInt32(ctx, addr ret, val) < 0:
      return none(T)
    return some(ret)
  elif T is int64:
    var ret: int64
    if JS_ToInt64(ctx, addr ret, val) < 0:
      return none(T)
    return some(ret)
  elif T is uint32:
    var ret: uint32
    if JS_ToUint32(ctx, addr ret, val) < 0:
      return none(T)
    return some(ret)
  elif T is uint64:
    var ret: uint32
    if JS_ToUint32(ctx, addr ret, val) < 0:
      return none(T)
    return some(cast[uint64](ret))

proc fromJS[T](ctx: JSContext, val: JSValue): Option[T]

macro len(t: type tuple): int =
  let i = t.getType()[1].len - 1 # - tuple
  newLit(i)

macro fromJSTupleBody(a: tuple) =
  let len = a.getType().len - 1
  let done = ident("done")
  result = newStmtList(quote do:
    var `done`: Option[bool])
  for i in 0..<len:
    result.add(quote do:
      let next = JS_Call(ctx, next_method, it, 0, nil)
      if JS_IsException(next):
        return none(T)
      defer: JS_FreeValue(ctx, next)
      let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().done)
      if JS_IsException(doneVal):
        return none(T)
      defer: JS_FreeValue(ctx, doneVal)
      `done` = fromJS[bool](ctx, doneVal)
      if `done`.isnone: # exception
        return none(T)
      if `done`.get:
        JS_ThrowTypeError(ctx, "Too few arguments in sequence (got %d, expected %d)", `i`, `len`)
        return none(T)
      let valueVal = JS_GetProperty(ctx, next, ctx.getOpaque().value)
      if JS_IsException(valueVal):
        return none(T)
      defer: JS_FreeValue(ctx, valueVal)
      let genericRes = fromJS[typeof(result.get[`i`])](ctx, valueVal)
      if genericRes.isnone: # exception
        return none(T)
      `a`[`i`] = genericRes.get
    )
    if i == len - 1:
      result.add(quote do:
        let next = JS_Call(ctx, next_method, it, 0, nil)
        if JS_IsException(next):
          return none(T)
        defer: JS_FreeValue(ctx, next)
        let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().done)
        `done` = fromJS[bool](ctx, doneVal)
        if `done`.isnone: # exception
          return none(T)
        var i = `i`
        # we're simulating a sequence, so we must query all remaining parameters too:
        while not `done`.get:
          inc i
          let next = JS_Call(ctx, next_method, it, 0, nil)
          if JS_IsException(next):
            return none(T)
          defer: JS_FreeValue(ctx, next)
          let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().done)
          if JS_IsException(doneVal):
            return none(T)
          defer: JS_FreeValue(ctx, doneVal)
          `done` = fromJS[bool](ctx, doneVal)
          if `done`.isnone: # exception
            return none(T)
          if `done`.get:
            JS_ThrowTypeError(ctx, "Too many arguments in sequence (got %d, expected %d)", i, `len`)
            return none(T)
          JS_FreeValue(ctx, JS_GetProperty(ctx, next, ctx.getOpaque().value))
      )

proc fromJSTuple[T: tuple](ctx: JSContext, val: JSValue): Option[T] =
  let itprop = JS_GetProperty(ctx, val, ctx.getOpaque().sym_iterator)
  if JS_IsException(itprop):
    return none(T)
  defer: JS_FreeValue(ctx, itprop)
  let it = JS_Call(ctx, itprop, val, 0, nil)
  if JS_IsException(it):
    return none(T)
  defer: JS_FreeValue(ctx, it)
  let next_method = JS_GetProperty(ctx, it, ctx.getOpaque().next)
  if JS_IsException(next_method):
    return none(T)
  defer: JS_FreeValue(ctx, next_method)
  var x: T
  fromJSTupleBody(x)
  return some(x)

proc fromJSSeq[T](ctx: JSContext, val: JSValue): Option[seq[T]] =
  let itprop = JS_GetProperty(ctx, val, ctx.getOpaque().sym_iterator)
  if JS_IsException(itprop):
    return none(seq[T])
  defer: JS_FreeValue(ctx, itprop)
  let it = JS_Call(ctx, itprop, val, 0, nil)
  if JS_IsException(it):
    return none(seq[T])
  defer: JS_FreeValue(ctx, it)
  let next_method = JS_GetProperty(ctx, it, ctx.getOpaque().next)
  if JS_IsException(next_method):
    return none(seq[T])
  defer: JS_FreeValue(ctx, next_method)
  result = some(newSeq[T]())
  while true:
    let next = JS_Call(ctx, next_method, it, 0, nil)
    if JS_IsException(next):
      return none(seq[T])
    defer: JS_FreeValue(ctx, next)
    let doneVal = JS_GetProperty(ctx, next, ctx.getOpaque().done)
    if JS_IsException(doneVal):
      return none(seq[T])
    defer: JS_FreeValue(ctx, doneVal)
    let done = fromJS[bool](ctx, doneVal)
    if done.isnone: # exception
      return none(seq[T])
    if done.get:
      break
    let valueVal = JS_GetProperty(ctx, next, ctx.getOpaque().value)
    if JS_IsException(valueVal):
      return none(seq[T])
    defer: JS_FreeValue(ctx, valueVal)
    let genericRes = fromJS[typeof(result.get[0])](ctx, valueVal)
    if genericRes.isnone: # exception
      return none(seq[T])
    result.get.add(genericRes.get)

proc fromJSTable[A, B](ctx: JSContext, val: JSValue): Option[Table[A, B]] =
  var ptab: ptr JSPropertyEnum
  var plen: uint32
  let flags = cint(JS_GPN_STRING_MASK)
  if JS_GetOwnPropertyNames(ctx, addr ptab, addr plen, val, flags) < -1:
    # exception
    return none(Table[A, B])
  defer:
    for i in 0..<plen:
      let prop = cast[ptr JSPropertyEnum](cast[int](ptab) + sizeof(ptab[]) * int(i))
      JS_FreeAtom(ctx, prop.atom)
    js_free(ctx, ptab)
  result = some(Table[A, B]())
  for i in 0..<plen:
    let prop = cast[ptr JSPropertyEnum](cast[int](ptab) + sizeof(ptab[]) * int(i))
    let atom = prop.atom
    let k = JS_AtomToValue(ctx, atom)
    defer: JS_FreeValue(ctx, k)
    let kn = fromJS[A](ctx, k)
    if kn.isnone: # exception
      return none(Table[A, B])
    let v = JS_GetProperty(ctx, val, atom)
    defer: JS_FreeValue(ctx, v)
    let vn = fromJS[B](ctx, v)
    if vn.isnone: # exception
      return none(Table[A, B])
    result.get[kn.get] = vn.get

proc fromJS[T](ctx: JSContext, val: JSValue): Option[T] =
  when T is string:
    return toString(ctx, val)
  elif typeof(result.unsafeGet) is Option: # unwrap
    let res = fromJS[typeof(result.get.get)](ctx, val)
    if res.isnone:
      return none(T)
    return some(res)
  elif T is seq:
    return fromJSSeq[typeof(result.get[0])](ctx, val)
  elif T is tuple:
    return fromJSTuple[T](ctx, val)
  elif T is bool:
    let ret = JS_ToBool(ctx, val)
    if ret == -1: # exception
      return none(T)
    if ret == 0:
      return some(false)
    return some(true)
  elif typeof(result.get) is Table:
    return fromJSTable[typeof(result.get.keys), typeof(result.get.values)](ctx, val)
  elif T is SomeInteger:
    return fromJSInt[T](ctx, val)
  elif T is SomeFloat:
    let f64: float64
    if JS_ToFloat64(ctx, addr f64, val) < 0:
      return none(T)
    return some(cast[T](f64))
  elif T is enum:
    #TODO implement enum handling...
    if JS_IsException(val):
      return none(T)
    let s = toString(ctx, val)
    if s.isnone:
      return none(T)
    try:
      return some(parseEnum[T](s.get))
    except ValueError:
      JS_ThrowTypeError(ctx, "`%s' is not a valid value for enumeration %s", cstring(s.get), $T)
      return none(T)
  elif T is JSObject:
    return some(JSObject(ctx: ctx, val: val))
  elif T is object:
    #TODO TODO TODO dictionary case
    return none(T)
  else:
    if JS_IsException(val):
      return none(T)
    let op = cast[T](getOpaque(ctx, val, $T))
    if op == nil:
      JS_ThrowTypeError(ctx, "Value is not an instance of %s", $T)
      return none(T)
    return some(op)

func toJSString(ctx: JSContext, str: string): JSValue =
  return JS_NewString(ctx, cstring(str))

func toJSInt(ctx: JSContext, n: SomeInteger): JSValue =
  when n is int:
    when sizeof(int) <= sizeof(int32):
      return JS_NewInt32(ctx, int32(n))
    else:
      return JS_NewInt64(ctx, n)
  elif n is uint:
    when sizeof(uint) <= sizeof(uint32):
      return JS_NewUint32(ctx, n)
    else:
      return JS_NewUint64(ctx, n)
  elif n is int32:
    return JS_NewInt32(ctx, n)
  elif n is int64:
    return JS_NewInt64(ctx, n)
  elif n is uint32:
    return JS_NewUint32(ctx, n)
  elif n is uint64:
    return JS_NewUint64(ctx, n)

func toJSNumber(ctx: JSContext, n: SomeNumber): JSValue =
  when n is SomeInteger:
    return toJSInt(ctx, n)
  else:
    return JS_NewFloat64(ctx, n)

func toJSBool(ctx: JSContext, b: bool): JSValue =
  return JS_NewBool(ctx, b)

proc getTypePtr[T](x: T): pointer =
  when T is RootRef or T is pointer:
    # I'm so sorry.
    # (This dereferences the object's first member, m_type. Probably.)
    return cast[ptr pointer](x)[]
  else:
    return getTypeInfo(x)

func toJSObject[T](ctx: JSContext, obj: T): JSValue =
  let op = JS_GetRuntime(ctx).getOpaque()
  let p = cast[pointer](obj)
  if p in op.plist:
    # a JSValue already points to this object.
    return JS_DupValue(ctx, JS_MKPTR(JS_TAG_OBJECT, op.plist[p]))
  let clazz = ctx.getOpaque().typemap[getTypePtr(obj)]
  let jsObj = ctx.newJSObject(clazz)
  jsObj.setOpaque(obj)
  return jsObj.val

proc toJS*[T](ctx: JSContext, obj: T): JSValue =
  when T is string:
    return ctx.toJSString(obj)
  elif T is SomeNumber:
    return ctx.toJSNumber(obj)
  elif T is bool:
    return ctx.toJSBool(obj)
  elif T is Table:
    result = JS_NewObject(ctx)
    if not JS_IsException(result):
      for k, v in obj:
        setProperty(ctx, result, k, toJS(ctx, v))
  elif T is Option:
    if obj.issome:
      return toJS(ctx, obj.get)
    return JS_NULL
  elif T is seq:
    let a = JS_NewArray(ctx)
    if not JS_IsException(a):
      for i in 0..obj.high:
        let j = toJS(ctx, obj[i])
        if JS_IsException(j):
          return j
        if JS_DefinePropertyValueInt64(ctx, a, int64(i), j, JS_PROP_C_W_E or JS_PROP_THROW) < 0:
          return JS_EXCEPTION
    return a
  else:
    if obj == nil:
      return JS_NULL
    return ctx.toJSObject(obj)

type
  JS_Error = object of CatchableError

  JS_SyntaxError* = object of JS_Error
  JS_TypeError* = object of JS_Error
  JS_ReferenceError* = object of JS_Error
  JS_RangeError* = object of JS_Error
  JS_InternalError* = object of JS_Error

  JSFuncGenerator = object
    original: NimNode
    copied: NimNode
    hasthis: bool
    funcName: string
    generics: Table[string, seq[NimNode]]
    funcParams: seq[FuncParam]
    thisType: string
    returnType: Option[NimNode]
    newName: string
    newBranchList: seq[NimNode]
    jsFunCallLists: seq[NimNode]
    jsFunCallList: NimNode
    jsFunCall: NimNode
    jsCallAndRet: NimNode
    minArgs: int
    i: int # nim parameters accounted for
    j: int # js parameters accounted for (not including fix ones, e.g. `this')
    res: NimNode

  RegisteredFunction = object
    name: string
    id: NimNode
    magic: uint16

var RegisteredFunctions {.compileTime.}: Table[string, seq[RegisteredFunction]]

proc getGenerics(fun: NimNode): Table[string, seq[NimNode]] =
  var node = fun.findChild(it.kind == nnkBracket)
  if node.kind == nnkNilLit:
    return # no bracket
  node = node.findChild(it.kind == nnkGenericParams)
  if node.kind == nnkNilLit:
    return # no generics
  node = node.findChild(it.kind == nnkIdentDefs)
  var stack: seq[NimNode]
  for i in countdown(node.len - 1, 0): stack.add(node[i])
  var gen_name: NimNode
  var gen_types: seq[NimNode]
  template add_gen =
    if gen_name != nil:
      assert gen_types.len != 0
      result[gen_name.strVal] = gen_types
      gen_types.setLen(0)

  while stack.len > 0:
    let node = stack.pop()
    case node.kind
    of nnkIdent:
      add_gen
      gen_name = node
    of nnkSym:
      assert gen_name != nil
      gen_types.add(node)
    of nnkInfix:
      assert node[0].eqIdent(ident("|")) or node[0].eqIdent(ident("or")), "Only OR generics are supported."
      for i in countdown(node.len - 1, 1): stack.add(node[i]) # except infix ident
    of nnkBracketExpr:
      gen_types.add(node)
    else:
      discard
  add_gen

proc getParams(fun: NimNode): seq[FuncParam] =
  let formalParams = fun.findChild(it.kind == nnkFormalParams)
  var funcParams: seq[FuncParam]
  var returnType = none(NimNode)
  if formalParams[0].kind != nnkEmpty:
    returnType = some(formalParams[0])
  for i in 1..<fun.params.len:
    let it = formalParams[i]
    let name = $it[0]
    let tt = it[1]
    let t = if it[1].kind != nnkEmpty:
      `tt`
    else:
      let x = it[2]
      quote do:
        typeof(`x`)
    let val = if it[2].kind != nnkEmpty:
      let x = it[2]
      some(newPar(x))
    else:
      none(NimNode)
    var g = none(NimNode)
    funcParams.add((name, t, val, g))
  funcParams

proc getReturn(fun: NimNode): Option[NimNode] =
  let formalParams = fun.findChild(it.kind == nnkFormalParams)
  if formalParams[0].kind != nnkEmpty:
    some(formalParams[0])
  else:
    none(NimNode)

template getJSParams(): untyped =
  [
    (quote do: JSValue),
    newIdentDefs(ident("ctx"), quote do: JSContext),
    newIdentDefs(ident("this"), quote do: JSValue),
    newIdentDefs(ident("argc"), quote do: int),
    newIdentDefs(ident("argv"), quote do: ptr JSValue)
  ]

template getJSGetterParams(): untyped =
  [
    (quote do: JSValue),
    newIdentDefs(ident("ctx"), quote do: JSContext),
    newIdentDefs(ident("this"), quote do: JSValue),
  ]

template getJSSetterParams(): untyped =
  [
    (quote do: JSValue),
    newIdentDefs(ident("ctx"), quote do: JSContext),
    newIdentDefs(ident("this"), quote do: JSValue),
    newIdentDefs(ident("val"), quote do: JSValue),
  ]

proc addParam2(gen: var JSFuncGenerator, s, t, val: NimNode, fallback: NimNode = nil) =
  let stmt = quote do:
    fromJS_or_return(`t`, ctx, `val`)
  for i in 0..gen.jsFunCallLists.high:
    if fallback == nil:
      gen.jsFunCallLists[i].add(newLetStmt(s, stmt))
    else:
      let j = gen.j
      gen.jsFunCallLists[i].add(newLetStmt(s, quote do:
        if `j` < argc: `stmt` else: `fallback`))

proc addValueParam(gen: var JSFuncGenerator, s, t: NimNode, fallback: NimNode = nil) =
  let j = gen.j
  gen.addParam2(s, t, quote do: getJSValue(ctx, argv, `j`), fallback)

proc addFixParam(gen: var JSFuncGenerator, name: string) =
  let s = ident("arg_" & $gen.i)
  let t = gen.funcParams[gen.i][1]
  let id = ident(name)
  gen.addParam2(s, t, id)
  if gen.jsFunCall != nil:
    gen.jsFunCall.add(s)
  inc gen.i

proc addUnionParamBranch(gen: var JSFuncGenerator, query, newBranch: NimNode, fallback: NimNode = nil) =
  let i = gen.i
  let query = if fallback == nil: query else:
    quote do: (
      if `i` >= argc:
       false
      else:
       `query`
    )
  let newBranch = newStmtList(newBranch)
  for i in 0..gen.jsFunCallLists.high:
    var ifstmt = newIfStmt((query, newBranch))
    let oldBranch = newStmtList()
    ifstmt.add(newTree(nnkElse, oldBranch))
    gen.jsFunCallLists[i].add(ifstmt)
    gen.jsFunCallLists[i] = oldBranch
  gen.newBranchList.add(newBranch)

proc addUnionParam(gen: var JSFuncGenerator, tt: NimNode, s: NimNode, fallback: NimNode = nil) =
  # Union types.
  #TODO lots of types missing
  let j = gen.j
  let flattened = gen.generics[tt.strVal] # flattened member types
  var tableg = none(NimNode)
  var seqg = none(NimNode)
  var hasString = false
  var hasJSObject = false
  for g in flattened:
    if g.len > 0 and g[0] == Table.getType():
      tableg = some(g)
    elif g.typekind == ntySequence:
      seqg = some(g)
    elif g == string.getType():
      hasString = true
    elif g == JSObject.getTypeInst():
      hasJSObject = true
  # 4. If V is null or undefined, then:
  #TODO this is wrong. map dictionary to object instead
  #if tableg.issome:
  #  let a = tableg.get[1]
  #  let b = tableg.get[2]
  #  gen.addUnionParamBranch(quote do: (
  #      let val = getJSValue(ctx, argv, `j`)
  #      JS_IsNull(val) or JS_IsUndefined(val)
  #    ),
  #    quote do:
  #      let `s` = Table[`a`, `b`](),
  #    fallback)
  # 10. If Type(V) is Object, then:
  # Sequence:
  if seqg.issome:
    let query = quote do:
      (
        let o = getJSValue(ctx, argv, `j`)
        JS_IsObject(o) and (
          let prop = JS_GetProperty(ctx, o, ctx.getOpaque().sym_iterator)
          if JS_IsException(prop):
            return JS_EXCEPTION
          let ret = not JS_IsUndefined(prop)
          JS_FreeValue(ctx, prop)
          ret
        )
      )
    let a = seqg.get[1]
    gen.addUnionParamBranch(query, quote do:
      let `s` = fromJS_or_return(seq[`a`], ctx, getJSValue(ctx, argv, `j`)),
      fallback)
  # Record:
  if tableg.issome:
    let a = tableg.get[1]
    let b = tableg.get[2]
    let query = quote do:
      JS_IsObject(getJSValue(ctx, argv, `j`))
    gen.addUnionParamBranch(query, quote do:
      let `s` = fromJS_or_return(Table[`a`, `b`], ctx, getJSValue(ctx, argv, `j`)),
      fallback)
  # Object (JSObject variant):
  #TODO non-JS objects
  if hasJSObject:
    let query = quote do:
      JS_IsObject(getJSValue(ctx, argv, `j`))
    gen.addUnionParamBranch(query, quote do:
      let `s` = fromJS_or_return(JSObject, ctx, getJSValue(ctx, argv, `j`)),
      fallback)

  # 14. If types includes a string type, then return the result of converting V
  # to that type.
  # TODO else typeerror
  gen.addParam2(s, string.getType(), quote do: getJSValue(ctx, argv, `j`), fallback)

  for branch in gen.newBranchList:
    gen.jsFunCallLists.add(branch)
  gen.newBranchList.setLen(0)

proc addRequiredParams(gen: var JSFuncGenerator) =
  let minArgs = gen.funcParams.getMinArgs()
  while gen.i < minArgs:
    let s = ident("arg_" & $gen.i)
    let tt = gen.funcParams[gen.i][1]
    if tt.typeKind == ntyGenericParam:
      gen.addUnionParam(tt, s)
    else:
      gen.addValueParam(s, tt)
    if gen.jsFunCall != nil:
      gen.jsFunCall.add(s)
    inc gen.j
    inc gen.i

proc addOptionalParams(gen: var JSFuncGenerator) =
  while gen.i < gen.funcParams.len:
    let j = gen.j
    let s = ident("arg_" & $gen.i)
    let tt = gen.funcParams[gen.i][1]
    if tt.typeKind == varargs.getType().typeKind: # pray it's not a generic...
      let vt = tt[1].getType()
      for i in 0..gen.jsFunCallLists.high:
        gen.jsFunCallLists[i].add(newLetStmt(s, quote do:
          (
            var valist: seq[`vt`]
            for i in `j`..<argc:
              let it = fromJS_or_return(`vt`, ctx, getJSValue(ctx, argv, i))
              valist.add(it)
            valist
          )
        ))
    else:
      let fallback = gen.funcParams[gen.i][2].get
      if tt.typeKind == ntyGenericParam:
        gen.addUnionParam(tt, s, fallback)
      else:
        gen.addValueParam(s, tt, fallback)
    if gen.jsFunCall != nil:
      gen.jsFunCall.add(s)
    inc gen.j
    inc gen.i

proc finishFunCallList(gen: var JSFuncGenerator) =
  for branch in gen.jsFunCallLists:
    branch.add(gen.jsFunCall)

var js_funcs {.compileTime.}: Table[string, JSFuncGenerator]

proc registerFunction(typ: string, name: string, id: NimNode, magic: uint16 = 0) =
  let nf = RegisteredFunction(name: name, id: id, magic: magic)
  if typ notin RegisteredFunctions:
    RegisteredFunctions[typ] = @[nf]
  else:
    RegisteredFunctions[typ].add(nf)

proc registerFunction(gen: JSFuncGenerator) =
  registerFunction(gen.thisType, gen.funcName, ident(gen.newName))
  js_funcs[gen.funcName] = gen

var js_errors {.compileTime.}: Table[string, seq[string]]

export JS_ThrowTypeError, JS_ThrowRangeError, JS_ThrowSyntaxError,
       JS_ThrowInternalError, JS_ThrowReferenceError

proc newJSProcBody(gen: var JSFuncGenerator, isva: bool): NimNode =
  let tt = gen.thisType
  let fn = gen.funcName
  let ma = if gen.hasthis: gen.minArgs - 1 else: gen.minArgs
  assert ma >= 0
  result = newStmtList()
  if isva:
    result.add(quote do: 
      if argc < `ma`:
        return JS_ThrowTypeError(ctx, "At least %d arguments required, but only %d passed", `ma`, argc)
    )
  if gen.hasthis:
    result.add(quote do:
      if not (JS_IsUndefined(this) or ctx.isGlobal(`tt`)) and not isInstanceOf(ctx, this, `tt`):
        # undefined -> global.
        return JS_ThrowTypeError(ctx, "'%s' called on an object that is not an instance of %s", `fn`, `tt`)
    )

  if gen.funcName in js_errors:
    var tryWrap = newNimNode(nnkTryStmt)
    tryWrap.add(gen.jsCallAndRet)
    for error in js_errors[gen.funcName]:
      let ename = ident(error)
      var exceptBranch = newNimNode(nnkExceptBranch)
      let eid = ident("e")
      exceptBranch.add(newNimNode(nnkInfix).add(ident("as"), ename, eid))
      let throwName = ident("JS_Throw" & error.substr("JS_".len))
      exceptBranch.add(quote do:
        return `throwName`(ctx, "%s", cstring(`eid`.msg)))
      tryWrap.add(exceptBranch)
    gen.jsCallAndRet = tryWrap
  result.add(gen.jsCallAndRet)

proc newJSProc(gen: var JSFuncGenerator, params: openArray[NimNode], isva = true): NimNode =
  let jsBody = gen.newJSProcBody(isva)
  let jsPragmas = newNimNode(nnkPragma).add(ident("cdecl"))
  result = newProc(ident(gen.newName), params, jsBody, pragmas = jsPragmas)
  gen.res = result

# WARNING: for now, this only works correctly when the .jserr pragma was
# declared on the parent function.
# Note: this causes the entire nim function body to be inlined inside the JS
# interface function.
#TODO: implement actual inlining (so we can e.g. get rid of JS_Error, use format strings, etc.)
macro JS_THROW*(a: typed, b: string) =
  result = quote do:
    block when_js:
      raise newException(`a`, `b`)

proc setupGenerator(fun: NimNode, hasthis = true, hasfuncall = true): JSFuncGenerator =
  result.funcName = $fun[0]
  if result.funcName == "$":
    # stringifier
    result.funcName = "toString"
  result.generics = getGenerics(fun)
  result.funcParams = getParams(fun)
  result.returnType = getReturn(fun)
  result.minArgs = result.funcParams.getMinArgs()
  result.original = fun
  result.hasthis = hasthis
  result.jsFunCallList = newStmtList()
  result.jsFunCallLists.add(result.jsFunCallList)
  if hasfuncall:
    result.jsFunCall = newCall(fun[0])

# this might be pretty slow...
#TODO ideally we wouldn't need separate functions at all. Not sure how that
# could be achieved, maybe using options?
proc rewriteExceptions(gen: var JSFuncGenerator, errors: var seq[string], node: NimNode) =
  for i in countdown(node.len - 1, 0):
    let c = node[i]
    if c.kind == nnkCommand and c[0].eqIdent ident("JS_THROW"):
      if gen.copied == nil:
        gen.copied = copy(gen.original)
      node[i] = newNimNode(nnkReturnStmt).add(newNilLit())
      if c[1].strVal notin errors:
        errors.add(c[1].strVal)
    elif c.len > 0:
      gen.rewriteExceptions(errors, c)
  
proc rewriteExceptions(gen: var JSFuncGenerator) =
  let ostmts = gen.original.findChild(it.kind == nnkStmtList)
  var errors: seq[string]
  gen.rewriteExceptions(errors, ostmts)
  assert gen.copied != nil
  var name: string
  if gen.copied[0].kind == nnkIdent:
    name = gen.copied[0].strVal
  elif gen.copied[0].kind == nnkPostfix:
    name = gen.copied[0][1].strVal
  else:
    assert false, "No JS_THROW statement found in proc with jserr pragma."
  name &= "_exceptions"
  gen.copied[0] = ident(name)
  js_errors[name] = errors

macro jserr*(fun: untyped) =
  var gen: JSFuncGenerator
  gen.original = fun
  gen.rewriteExceptions()
  var pragma = gen.original.findChild(it.kind == nnkPragma)
  for i in 0..<pragma.len:
    if pragma[i].eqIdent(ident("jsctor")) or pragma[i].eqIdent(ident("jsfunc")) or pragma[i].eqIdent(ident("jsget")) or pragma[i].eqIdent(ident("jsset")):
      pragma.del(i)
  gen.copied.addPragma(quote do: inline)

  result = newStmtList(gen.original, gen.copied)

macro jsctor*(fun: typed) =
  var gen = setupGenerator(fun, hasthis = false)
  if gen.funcName in js_funcs:
    #TODO TODO TODO implement function overloading
    error("Function overloading hasn't been implemented yet...")
    result = newStmtList(fun)
  else:
    if gen.returnType.get.kind == nnkRefTy:
      gen.thisType = gen.returnType.get[0].strVal
    else:
      gen.thisType = gen.returnType.get.strVal
    gen.newName = "js_new_" & gen.thisType & '_' & gen.funcName
    gen.addRequiredParams()
    gen.addOptionalParams()
    gen.finishFunCallList()
    let jfcl = gen.jsFunCallList
    gen.jsCallAndRet = quote do:
      return ctx.toJS(`jfcl`)
    discard gen.newJSProc(getJSParams())
    gen.registerFunction()
    result = newStmtList(fun)

macro jsfget*(fun: typed) =
  var gen = setupGenerator(fun)
  gen.newName = "js_get_" & gen.funcParams[0][0] & '_' & gen.funcName
  gen.thisType = $gen.funcParams[0][1]
  if gen.minArgs != 1 or gen.funcParams.len != gen.minArgs:
    error("jsget functions must accept one parameter")
  if gen.returnType.isnone:
    error("jsget functions must have a return type")
  gen.addFixParam("this")
  gen.finishFunCallList()
  let jfcl = gen.jsFunCallList
  gen.jsCallAndRet = quote do:
    return ctx.toJS(`jfcl`)
  let jsProc = gen.newJSProc(getJSGetterParams(), false)
  gen.registerFunction()
  result = newStmtList(fun, jsProc)

macro jsfset*(fun: typed) =
  var gen = setupGenerator(fun)
  gen.newName = "js_set_" & gen.funcParams[0][0] & '_' & gen.funcName
  gen.thisType = $gen.funcParams[0][1]
  if gen.minArgs != 2 or gen.funcParams.len != gen.minArgs:
    error("jsset functions must accept two parameters")
  if gen.returnType.issome:
    error("jsset functions must not have a return type")
  gen.addFixParam("this")
  gen.addFixParam("val")
  gen.finishFunCallList()
  let jfcl = gen.jsFunCallList
  # Ideally we could simulate JS setters using nim setters, but nim setters
  # won't accept types that don't match their reflected field's type.
  gen.jsCallAndRet = quote do:
    `jfcl`
    return JS_DupValue(ctx, val)
  let jsProc = gen.newJSProc(getJSSetterParams(), false)
  gen.registerFunction()
  result = newStmtList(fun, jsProc)

macro jsfunc*(fun: typed) =
  var gen = setupGenerator(fun)
  gen.newName = "js_"
  if gen.funcParams.len > 0:
    gen.newName &= gen.funcParams[0][0] & "_"
  gen.newName &= gen.funcName
  assert gen.minArgs > 0 #TODO support zero-param (=global, no parent object)
  gen.thisType = $gen.funcParams[0][1]
  gen.addFixParam("this")
  gen.addRequiredParams()
  gen.addOptionalParams()
  gen.finishFunCallList()
  let jfcl = gen.jsFunCallList
  gen.jsCallAndRet = if gen.returnType.issome:
    quote do:
      return ctx.toJS(`jfcl`)
  else:
    quote do:
      `jfcl`
      return JS_UNDEFINED
  let jsProc = gen.newJSProc(getJSParams())
  gen.registerFunction()
  result = newStmtList(fun, jsProc)

# Having the same names for these and the macros leads to weird bugs, so the
# macros get an additional f.
template jsget*() {.pragma.}
template jsset*() {.pragma.}

proc nim_finalize_for_js[T](obj: T) =
  for rt in runtimes:
    let rtOpaque = rt.getOpaque()
    if tables.hasKey(rtOpaque.plist, cast[pointer](obj)):
      let p = rtOpaque.plist[cast[pointer](obj)]
      let val = JS_MKPTR(JS_TAG_OBJECT, p)
      let header = cast[ptr JSRefCountHeader](p)
      if header.ref_count > 1:
        # References to this value still exist in JS, so we
        # * copy the opaque's value
        # * increase the new value's refcount by 1
        # * set the new value as the new opaque
        # * add the new value to the pointer table
        # Now it's on JS to decrement the new object's refcount.
        # (Yeah, kind of an ugly hack. But it starts to look better when
        # the alternative is writing a cycle collector...)
        let newop = new(T)
        newop[] = obj[]
        GC_ref(newop)
        let np = cast[pointer](newop)
        JS_SetOpaque(val, np)
        rtOpaque.plist[np] = p
      else:
        # This was the last reference to the JS value.
        # Clear val's opaque so our refcount isn't decreased again.
        JS_SetOpaque(val, nil)
      tables.del(rtOpaque.plist, cast[pointer](obj))
      # Decrement jsvalue's refcount. This is needed in both cases to
      # trigger the JS finalizer and free the JS value.
      JS_FreeValueRT(rt, val)

proc js_illegal_ctor*(ctx: JSContext, this: JSValue, argc: int, argv: ptr JSValue): JSValue {.cdecl.} =
  return JS_ThrowTypeError(ctx, "Illegal constructor")

template fromJS_or_return*(t, ctx, val: untyped): untyped =
  (
    let x = fromJS[t](ctx, val)
    if x.isnone:
      return JS_EXCEPTION
    x.get
  )

type JSObjectPragmas = object
  jsget: seq[NimNode]
  jsset: seq[NimNode]

proc findPragmas(t: NimNode): JSObjectPragmas =
  let typ = t.getTypeInst()[1] # The type, as declared.
  var impl = typ.getTypeImpl() # ref t
  assert impl.kind == nnkRefTy, "Only ref nodes are supported..."
  impl = impl[0].getImpl()
  # stolen from std's macros.customPragmaNode
  var identDefsStack = newSeq[NimNode](impl[2].len)
  for i in 0..<identDefsStack.len: identDefsStack[i] = impl[2][i]
  while identDefsStack.len > 0:
    var identDefs = identDefsStack.pop()

    case identDefs.kind
    of nnkRecList:
      for child in identDefs.children:
        identDefsStack.add(child)
    of nnkRecCase:
      # Add condition definition
      identDefsStack.add(identDefs[0])
      # Add branches
      for i in 1 ..< identDefs.len:
        identDefsStack.add(identDefs[i].last)
    else:
      for i in 0 .. identDefs.len - 3:
        let varNode = identDefs[i]
        if varNode.kind == nnkPragmaExpr:
          var varName = varNode[0]
          if varName.kind == nnkPostfix:
            # This is a public field. We are skipping the postfix *
            varName = varName[1]
          for pragma in varNode[1]:
            case $pragma
            of "jsget": result.jsget.add(varName)
            of "jsset": result.jsset.add(varName)

macro registerType*(ctx: typed, t: typed, parent: JSClassID = 0, asglobal = false, nointerface = false): JSClassID =
  result = newStmtList()
  let s = t.strVal
  var sctr = ident("js_illegal_ctor")
  var sfin = ident("js_" & s & "ClassFin")
  var ctorFun: NimNode
  var ctorImpl: NimNode
  var setters, getters: Table[string, NimNode]
  let tabList = newNimNode(nnkBracket)
  let pragmas = findPragmas(t)
  for node in pragmas.jsget:
    let id = ident("js_get_" & s & "_" & $node)
    let fn = $node
    result.add(quote do:
      proc `id`(ctx: JSContext, this: JSValue): JSValue {.cdecl.} =
        if not (JS_IsUndefined(this) or ctx.isGlobal(`s`)) and not ctx.isInstanceOf(this, `s`):
          # undefined -> global.
          return JS_ThrowTypeError(ctx, "'%s' called on an object that is not an instance of %s", `fn`, `s`)
        let arg_0 = fromJS_or_return(`t`, ctx, this)
        return toJS(ctx, arg_0.`node`)
    )
    registerFunction(s, fn, id)
  for node in pragmas.jsset:
    let id = ident("js_set_" & s & "_" & $node)
    let fn = $node
    result.add(quote do:
      proc `id`(ctx: JSContext, this: JSValue, val: JSValue): JSValue {.cdecl.} =
        if not (JS_IsUndefined(this) or ctx.isGlobal(`s`)) and not ctx.isInstanceOf(this, `s`):
          # undefined -> global.
          return JS_ThrowTypeError(ctx, "'%s' called on an object that is not an instance of %s", `fn`, `s`)
        let arg_0 = fromJS_or_return(`t`, ctx, this)
        let arg_1 = val
        arg_0.`node` = fromJS_or_return(typeof(arg_0.`node`), ctx, arg_1)
        return JS_DupValue(ctx, arg_1)
    )
    registerFunction(s, fn, id)

  if s in RegisteredFunctions:
    for fun in RegisteredFunctions[s].mitems:
      var f0 = fun.name
      let f1 = fun.id
      if fun.name.endsWith("_exceptions"):
        fun.name = fun.name.substr(0, fun.name.high - "_exceptions".len)
      if f1.strVal.startsWith("js_new"):
        ctorImpl = js_funcs[$f0].res
        if ctorFun != nil:
          error("Class " & $s & " has 2+ constructors.")
        ctorFun = f1
      elif f1.strVal.startsWith("js_get"):
        getters[f0] = f1
      elif f1.strVal.startsWith("js_set"):
        setters[f0] = f1
      else:
        f0 = fun.name
        tabList.add(quote do:
          JS_CFUNC_DEF(`f0`, 0, cast[JSCFunction](`f1`)))

  for k, v in getters:
    if k in setters:
      let s = setters[k]
      tabList.add(quote do: JS_CGETSET_DEF(`k`, `v`, `s`))
    else:
      tabList.add(quote do: JS_CGETSET_DEF(`k`, `v`, nil))
  for k, v in setters:
    if k notin getters:
      tabList.add(quote do: JS_CGETSET_DEF(`k`, nil, `v`))

  if ctorFun != nil:
    sctr = ctorFun
    result.add(ctorImpl)

  result.add(quote do:
    proc `sfin`(rt: JSRuntime, val: JSValue) {.cdecl.} =
      let opaque = JS_GetOpaque(val, val.getClassID())
      if opaque != nil:
        # This means the nim value is no longer referenced by anything but this
        # JSValue. Meaning we can just unref and remove it from the pointer
        # table.
        GC_unref(cast[`t`](opaque))
        let rtOpaque = rt.getOpaque()
        rtOpaque.plist.del(opaque)
  )

  result.add(quote do:
    block:
      # See the definition of `new':
      # > **Note**:
      # > The `finalizer` refers to the type `T`, not to the object!
      # > This means that for each object of type `T` the finalizer will be
      # > called!
      # We exploit this by setting a finalizer here, which can then unregister
      # any associated JS object from all relevant runtimes.
      var x: `t`
      new(x, nim_finalize_for_js)
      const classDef = JSClassDef(class_name: `s`, finalizer: `sfin`)
      `ctx`.newJSClass(JSClassDefConst(unsafeAddr classDef), `sctr`, `tabList`, getTypePtr(x), `parent`, `asglobal`, `nointerface`)
  )

proc getMemoryUsage*(rt: JSRuntime): string =
  var m: JSMemoryUsage
  JS_ComputeMemoryUsage(rt, addr m)
  result = fmt"""
memory allocated: {m.malloc_count} {m.malloc_size} ({float(m.malloc_size)/float(m.malloc_count):.1f}/block)
memory used: {m.memory_used_count} {m.memory_used_size} ({float(m.malloc_size-m.memory_used_size)/float(m.memory_used_count):.1f} average slack)
atoms: {m.atom_count} {m.atom_size} ({float(m.atom_size)/float(m.atom_count):.1f}/atom)
strings: {m.str_count} {m.str_size} ({float(m.str_size)/float(m.str_count):.1f}/string)
objects: {m.obj_count} {m.obj_size} ({float(m.obj_size)/float(m.obj_count):.1f}/object)
properties: {m.prop_count} {m.prop_size} ({float(m.prop_size)/float(m.obj_count):.1f}/object)
shapes: {m.shape_count} {m.shape_size} ({float(m.shape_size)/float(m.shape_count):.1f}/shape)
js functions: {m.js_func_count} {m.js_func_size} ({float(m.js_func_size)/float(m.js_func_count):.1f}/function)
native functions: {m.c_func_count}
arrays: {m.array_count}
fast arrays: {m.fast_array_count}
fast array elements: {m.fast_array_elements} {m.fast_array_elements*sizeof(JSValue)} ({float(m.fast_array_elements)/float(m.fast_array_count):.1f})
binary objects: {m.binary_object_count} {m.binary_object_size}"""

proc eval*(ctx: JSContext, s: string, file: string, eval_flags: int): JSObject =
  result.ctx = ctx
  result.val = JS_Eval(ctx, cstring(s), cint(s.len), cstring(file), cint(eval_flags))
