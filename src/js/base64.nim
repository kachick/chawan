import std/base64

import bindings/quickjs
import js/domexception
import js/javascript
import js/jstypes
import types/opt

# atob and btoa convert Latin-1 to base64 and vice versa. (And throw on
# anything above latin-1.)

proc atob*(data: string): DOMResult[NarrowString] =
  try:
    let ds = NarrowString(base64.decode(data))
    return ok(ds)
  except ValueError:
    return errDOMException("Invalid character in string",
      "InvalidCharacterError")

proc btoa*(ctx: JSContext; data: JSValue): DOMResult[string] =
  let data = JS_ToString(ctx, data)
  if JS_IsException(data):
    return err()
  assert JS_IsString(data)
  if JS_IsStringWideChar(data):
    JS_FreeValue(ctx, data)
    return errDOMException("Invalid character in string",
      "InvalidCharacterError")
  let len = int(JS_GetStringLength(data))
  if len == 0:
    JS_FreeValue(ctx, data)
    return ok("")
  let buf = JS_GetNarrowStringBuffer(data)
  let res = base64.encode(toOpenArray(buf, 0, len - 1))
  JS_FreeValue(ctx, data)
  return ok(res)
