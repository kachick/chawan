import std/base64

import js/domexception
import utils/opt

# atob and btoa convert Latin-1 to base64 and vice versa. (And throw on
# anything above latin-1.)
# We could do this quite efficiently if we had an API for the QuickJS string
# internal representation. Unfortunately we do not, so we do the following:
# * atob: decode, convert latin-1 to utf-8, pass to qjs, where it is then
#   converted to latin-1 again.
# * btoa: qjs converts its string (either utf-16 or latin-1) to utf-8,
#   we convert this to latin-1 (or throw), then encode.
# That is two conversions more than needed (i.e. 0) for each step. We should
# really write an API for handling QJS strings sometime...

proc atob*(data: string): DOMResult[string] =
  try:
    let ds = base64.decode(data)
    var s = newStringOfCap(ds.len)
    for c in ds:
      if uint8(c) <= 0x7F:
        s &= c
      else: # latin-1
        s &= char((uint8(c) shr 6) or 0xC0)
        s &= char((uint8(c) and 0x3F) or 0x80)
    return ok(s)
  except ValueError:
    return err(newDOMException("Invalid character in string",
      "InvalidCharacterError"))

proc btoa*(data: string): DOMResult[string] =
  var s = newStringOfCap(data.len)
  var i = 0
  while i < data.len:
    let c = data[i]
    let n = uint8(c)
    if n <= 0x7F: # ascii
      s &= c
      inc i
    elif n <= 0xC3: # latin-1
      inc i
      s &= char((n shl 6) or (uint8(data[i]) and 0x3F))
      inc i
    else:
      return err(newDOMException("Invalid character in string",
        "InvalidCharacterError"))
  return ok(base64.encode(s))
