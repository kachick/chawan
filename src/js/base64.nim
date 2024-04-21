import std/base64

import bindings/quickjs
import js/domexception
import js/javascript
import js/jstypes
import types/opt
import utils/twtstr

# atob and btoa convert Latin-1 to base64 and vice versa. (And throw on
# anything above latin-1.)

func atob(c: char): uint8 {.inline.} =
  # see RFC 4648 table
  if c in AsciiUpperAlpha:
    return uint8(c) - uint8('A')
  if c in AsciiLowerAlpha:
    return uint8(c) - uint8('a') + 26
  if c in AsciiDigit:
    return uint8(c) - uint8('0') + 52
  if c == '+':
    return 62
  if c == '/':
    return 63
  return uint8.high

proc atob*(data: string): DOMResult[NarrowString] =
  var outs = newStringOfCap(data.len div 4 * 3)
  var buf: array[4, uint8]
  var i = 0
  var j = 0
  var pad = 0
  while true:
    i = data.skipBlanks(i)
    if i >= data.len:
      break
    if data[i] == '=':
      i = data.skipBlanks(i + 1)
      inc pad
      break
    buf[j] = atob(data[i])
    if buf[j] == uint8.high:
      return errDOMException("Invalid character in encoded string",
        "InvalidCharacterError")
    if j == 3:
      let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
      let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
      let ob3 = (buf[2] shl 6) or buf[3]         # 2 bits of b2 | 6 bits of b3
      outs &= char(ob1)
      outs &= char(ob2)
      outs &= char(ob3)
      j = 0
    else:
      inc j
    inc i
  if i < data.len:
    if i < data.len and data[i] == '=':
      inc pad
      inc i
    i = data.skipBlanks(i)
  if pad > 0 and j + pad != 4:
    return errDOMException("Too much padding", "InvalidCharacterError")
  if i < data.len:
    return errDOMException("Invalid character after encoded string",
      "InvalidCharacterError")
  if j == 3:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
    outs &= char(ob1)
    outs &= char(ob2)
  elif j == 2:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    outs &= char(ob1)
  elif j != 0:
    return errDOMException("Incorrect number of characters in encoded string",
      "InvalidCharacterError")
  return ok(NarrowString(outs))

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
  let res = base64.encode(buf.toOpenArray(0, len - 1))
  JS_FreeValue(ctx, data)
  return ok(res)
