import bindings/constcharp
import bindings/quickjs
import js/javascript
import js/tojs

proc setImportMeta(ctx: JSContext; funcVal: JSValue; isMain: bool) =
  let m = cast[JSModuleDef](JS_VALUE_GET_PTR(funcVal))
  let moduleNameAtom = JS_GetModuleName(ctx, m)
  let metaObj = JS_GetImportMeta(ctx, m)
  definePropertyCWE(ctx, metaObj, "url", JS_AtomToValue(ctx, moduleNameAtom))
  definePropertyCWE(ctx, metaObj, "main", isMain)
  JS_FreeValue(ctx, metaObj)
  JS_FreeAtom(ctx, moduleNameAtom)

proc finishLoadModule*(ctx: JSContext; f: string; name: cstring): JSModuleDef =
  let funcVal = compileModule(ctx, f, $name)
  if JS_IsException(funcVal):
    return nil
  setImportMeta(ctx, funcVal, false)
  # "the module is already referenced, so we must free it"
  # idk how this works, so for now let's just do what qjs does
  result = cast[JSModuleDef](JS_VALUE_GET_PTR(funcVal))
  JS_FreeValue(ctx, funcVal)

proc normalizeModuleName*(ctx: JSContext; base_name, name: cstringConst;
    opaque: pointer): cstring {.cdecl.} =
  return js_strdup(ctx, cstring(name))
