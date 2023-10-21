import std/base64

import bindings/quickjs
import js/domexception
import js/javascript
import js/strings
import types/opt

# atob and btoa convert Latin-1 to base64 and vice versa. (And throw on
# anything above latin-1.)

proc atob*(data: string): DOMResult[NarrowString] =
  try:
    let ds = NarrowString(base64.decode(data))
    return ok(ds)
  except ValueError:
    return err(newDOMException("Invalid character in string",
      "InvalidCharacterError"))

proc btoa*(data: JSString): DOMResult[string] =
  if JS_IsStringWideChar(data):
    return err(newDOMException("Invalid character in string",
      "InvalidCharacterError"))
  let len = int(JS_GetStringLength(data))
  if len == 0:
    return ok("")
  let buf = JS_GetNarrowStringBuffer(data)
  let res = base64.encode(toOpenArray(buf, 0, len - 1))
  return ok(res)
