import unicode
import std/base64

import js/domexception
import utils/opt

proc atob*(data: string): DOMResult[string] =
  try:
    return ok(base64.decode(data))
  except ValueError:
    return err(newDOMException("Invalid character in string",
      "InvalidCharacterError"))

proc btoa*(data: string): DOMResult[string] =
  # For some incomprehensible reason, this must return a DOMException
  # for strings with chars not in latin-1.
  #TODO this could be a lot more efficient if we just directly passed
  # is_wide_char from QJS strings.
  for r in data.runes:
    if int32(r) <= 0xFF:
      continue
    return err(newDOMException("Invalid character in string",
      "InvalidCharacterError"))
  return ok(base64.encode(data))
