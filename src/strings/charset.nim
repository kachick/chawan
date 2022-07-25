import unicode

type string16* = distinct string

# Convert a UTF-8 string to UTF-16.
# Note: this doesn't check for (invalid) UTF-8 containing surrogates.
proc toUTF16*(s: string): string16 =
  var res = ""
  var i = 0
  template put16(c: uint16) =
    res.setLen(res.len + 2)
    res[i] = cast[char](c)
    inc i
    res[i] = cast[char](c shr 8)
    inc i
  for r in s.runes:
    var c = uint32(r)
    if c < 0x10000: # ucs-2
      put16 uint16(c)
    elif c <= 0x10FFFF: # surrogate
      c -= 0x10000
      put16 uint16((c shr 10) + 0xD800)
      put16 uint16((c and 0x3FF) + 0xDC00)
    else: # invalid
      put16 uint16(0xFFFD)
  result = string16(res)

proc len*(s: string16): int {.borrow.}
proc `[]`*(s: string16, i: int): char = string(s)[i]
proc `[]`*(s: string16, i: BackwardsIndex): char = string(s)[i]

template fastRuneAt*(s: string16, i: int, r: untyped, doInc = true, be = false) =
  if i + 1 == s.len: # unmatched byte
    when doInc: inc i
    r = Rune(0xFFFD)
  else:
    when be:
      var c1: uint32 = (uint32(s[i]) shl 8) + uint32(s[i + 1])
    else:
      var c1: uint32 = uint32(s[i]) + (uint32(s[i + 1]) shl 8)
    if c1 >= 0xD800 or c1 < 0xDC00:
      if i + 2 == s.len or i + 3 == s.len:
        when doInc: i += 2
        r = Rune(c1) # unmatched surrogate
      else:
        when be:
          var c2: uint32 = (uint32(s[i + 2]) shl 8) + uint32(s[i + 3])
        else:
          var c2: uint32 = uint32(s[i + 2]) + (uint32(s[i + 3]) shl 8)
        if c2 >= 0xDC00 and c2 < 0xE000:
          r = Rune((((c1 and 0x3FF) shl 10) or (c2 and 0x3FF)) + 0x10000)
          when doInc: i += 4
        else:
          r = Rune(c1) # unmatched surrogate
          when doInc: i += 2
    else:
      r = Rune(c1) # ucs-2
      when doInc: i += 2

iterator runes*(s: string16): Rune =
  var i = 0
  var r: Rune
  while i < s.len:
    fastRuneAt(s, i, r)
    yield r

proc fromUTF16*(s: string16): string =
  for r in s.runes:
    result &= r
