import os

const javascriptDirs = ["/usr", "/lib", "/usr/lib", "/usr/local/lib", "/usr/local"]
const lib = (func(): string =
  when defined(posix):
    for dir in javascriptDirs:
      for dir in @[dir, dir / "quickjs"]:
        if fileExists(dir / "libquickjs.a"):
          return dir
)()
const hlib = (func(): string =
  when defined(posix):
    for dir in javascriptDirs:
      for dir in @[dir / "include", dir / "include" / "quickjs"]:
        if fileExists(dir / "quickjs.h"):
          return dir
)()
const qjsheader = "<quickjs/quickjs.h>"

when lib != "":
  {.passL: "-L" & lib.}
when hlib != "":
  {.passC: "-I" & hlib.}
{.passL: "-lquickjs -lm -lpthread".}

when sizeof(int) < sizeof(int64):
  {.passC: "-DJS_NAN_BOXING".}
  type
    JSValue* {.importc: "JSValue", header: qjsheader.} = uint64
  # uh this won't compile you're on your own
else:
  type
    JSValueUnion {.union.} = object
      int32: int32
      float64: float64
      `ptr`: pointer
    JSValue* {.importc: "JSValue", header: qjsheader.} = object
      u: JSValueUnion
      tag: int64

type
  JSRuntime* = ptr object
  JSContext* = ptr object
  JSCFunction* = proc (ctx: JSContext, this_val: JSValue, argc: int, argv: ptr JSValue): JSValue {.cdecl.}
  JSCFunctionEnum* {.size: sizeof(cint).} = enum
    JS_CFUNC_generic, JS_CFUNC_generic_magic, JS_CFUNC_constructor,
    JS_CFUNC_constructor_magic, JS_CFUNC_constructor_or_func,
    JS_CFUNC_constructor_or_func_magic, JS_CFUNC_f_f, JS_CFUNC_f_f_f,
    JS_CFUNC_getter, JS_CFUNC_setter, JS_CFUNC_getter_magic,
    JS_CFUNC_setter_magic, JS_CFUNC_iterator_next

const                         ##  all tags with a reference count are negative
  JS_TAG_FIRST* = -10           ##  first negative tag
  JS_TAG_BIG_INT* = -10
  JS_TAG_BIG_FLOAT* = -9
  JS_TAG_SYMBOL* = -8
  JS_TAG_STRING* = -7
  JS_TAG_SHAPE* = -6            ##  used internally during GC
  JS_TAG_ASYNC_FUNCTION* = -5   ##  used internally during GC
  JS_TAG_VAR_REF* = -4          ##  used internally during GC
  JS_TAG_MODULE* = -3           ##  used internally
  JS_TAG_FUNCTION_BYTECODE* = -2 ##  used internally
  JS_TAG_OBJECT* = -1
  JS_TAG_INT* = 0
  JS_TAG_BOOL* = 1
  JS_TAG_NULL* = 2
  JS_TAG_UNDEFINED* = 3
  JS_TAG_UNINITIALIZED* = 4
  JS_TAG_CATCH_OFFSET* = 5
  JS_TAG_EXCEPTION* = 6
  JS_TAG_FLOAT64* = 7           ##  any larger tag is FLOAT64 if JS_NAN_BOXING

template JS_MKVAL*(t, val: untyped): JSValue =
  JSValue(u: JSValueUnion(`int32`: val), tag: t)

const
  JS_NULL* = JS_MKVAL(JS_TAG_NULL, 0)
  JS_UNDEFINED* = JS_MKVAL(JS_TAG_UNDEFINED, 0)
  JS_FALSE* = JS_MKVAL(JS_TAG_BOOL, 0)
  JS_TRUE* = JS_MKVAL(JS_TAG_BOOL, 1)
  JS_EXCEPTION* = JS_MKVAL(JS_TAG_EXCEPTION, 0)
  JS_UNINITIALIZED* = JS_MKVAL(JS_TAG_UNINITIALIZED, 0)

const
  JS_EVAL_TYPE_GLOBAL* = (0 shl 0) ##  global code (default)
  JS_EVAL_TYPE_MODULE* = (1 shl 0) ##  module code
  JS_EVAL_TYPE_DIRECT* = (2 shl 0) ##  direct call (internal use)
  JS_EVAL_TYPE_INDIRECT* = (3 shl 0) ##  indirect call (internal use)
  JS_EVAL_TYPE_MASK* = (3 shl 0)
  JS_EVAL_FLAG_SHEBANG* = (1 shl 2) ##  skip first line beginning with '#!'
  JS_EVAL_FLAG_STRICT* = (1 shl 3) ##  force 'strict' mode
  JS_EVAL_FLAG_STRIP* = (1 shl 4) ##  force 'strip' mode
  JS_EVAL_FLAG_COMPILE_ONLY* = (1 shl 5) ##  internal use

{.push header: qjsheader, cdecl.}

proc JS_NewRuntime*(): JSRuntime {.importc: "JS_NewRuntime".}
proc JS_FreeRuntime*(rt: JSRuntime) {.importc: "JS_FreeRuntime".}

proc JS_NewContext*(rt: JSRuntime): JSContext {.importc: "JS_NewContext".}
proc JS_NewContextRaw*(rt: JSRuntime): JSContext {.importc: "JS_NewContextRaw".}
proc JS_FreeContext*(ctx: JSContext) {.importc: "JS_FreeContext".}

proc JS_GetGlobalObject*(ctx: JSContext): JSValue {.importc: "JS_GetGlobalObject".}

proc JS_NewObject*(ctx: JSContext): JSValue {.importc: "JS_NewObject".}

proc JS_NewCFunction2*(ctx: JSContext, cfunc: JSCFunction, name: cstring, length: int, proto: JSCFunctionEnum, magic: int): JSValue {.importc: "JS_NewCFunction2".}
proc JS_NewCFunction*(ctx: JSContext, cfunc: JSCFunction, name: cstring, length: int): JSValue  {.importc: "JS_NewCFunction".}

proc JS_SetPropertyStr*(ctx: JSContext, this_obj: JSValue, prop: cstring, val: JSValue): int 
 {.importc: "JS_SetPropertyStr".}
proc JS_GetPropertyStr*(ctx: JSContext, this_obj: JSValue, prop: cstring): JSValue
 {.importc: "JS_GetPropertyStr".}

proc JS_FreeValue*(ctx: JSContext, v: JSValue) {.importc: "JS_FreeValue".}

# use toString if possible
proc JS_ToCStringLen*(ctx: JSContext, plen: ptr int, val1: JSValue): cstring {.importc: "JS_ToCStringLen".}
proc JS_ToCString*(ctx: JSContext, val1: JSValue): cstring {.importc: "JS_ToCString".}
proc JS_FreeCString*(ctx: JSContext, `ptr`: cstring) {.importc: "JS_FreeCString".}

proc JS_Eval*(ctx: JSContext, input: cstring, input_len: int, filename: cstring, eval_flags: int): JSValue {.importc: "JS_Eval".}

proc JS_IsException*(v: JSValue): bool {.importc: "JS_IsException".}
proc JS_IsError*(v: JSValue): bool {.importc: "JS_IsError".}
proc JS_IsUndefined*(v: JSValue): bool {.importc: "JS_IsUndefined".}

proc JS_GetException*(ctx: JSContext): JSValue {.importc: "JS_GetException".}

proc JS_SetContextOpaque*(ctx: JSContext, opaque: pointer) {.importc: "JS_SetContextOpaque".}
proc JS_GetContextOpaque*(ctx: JSContext): pointer {.importc: "JS_GetContextOpaque".}

proc js_free_rt*(rt: JSRuntime, p: pointer) {.importc: "js_free_rt".}
{.pop.}
