import std/unicode

import utils/proptable
import utils/map

include res/map/charwidth_gen

# One of the few global variables in the code. Honestly, it should not exist.
var isCJKAmbiguous* = false

# Warning: this shouldn't be called without normalization.
func width*(r: Rune): int =
  let u = uint32(r)
  if u <= 0xFFFF: # fast path for BMP
    if u in CombiningTable:
      return 0
    if u in DoubleWidthTable:
      return 2
    {.cast(noSideEffect).}:
      if isCJKAmbiguous and DoubleWidthAmbiguousRanges.isInRange(u):
        return 2
  else:
    if Combining.isInRange(u):
      return 0
    if DoubleWidthRanges.isInRange(u):
      return 2
    {.cast(noSideEffect).}:
      if isCJKAmbiguous and DoubleWidthAmbiguousRanges.isInRange(u):
        return 2
  return 1

# Width, but also works with tabs.
# Needs the column width of the text so far.
func twidth*(r: Rune; w: int): int =
  if r != Rune('\t'):
    return r.width()
  return ((w div 8) + 1) * 8 - w

func width*(s: string): int =
  result = 0
  for r in s.runes:
    result += r.twidth(result)

func width*(s: string; start, len: int): int =
  result = 0
  var i = start
  var m = len
  if m > s.len:
    m = s.len
  while i < m:
    var r: Rune
    fastRuneAt(s, i, r)
    result += r.twidth(result)

when NimMajor < 2:
  template ones(n: untyped): untyped = ((1 shl n)-1)
  template fastRuneAt(s: openArray[char]; i: int; result: untyped) =
    result = Rune(0xFFFD)
    if uint32(s[i]) <= 127:
      result = Rune(uint32(s[i]))
    elif uint32(s[i]) shr 5 == 0b110:
      if i <= s.len - 2:
        result = Rune((uint32(s[i]) and (ones(5))) shl 6 or
          (uint32(s[i+1]) and ones(6)))
        i += 1
    elif uint32(s[i]) shr 4 == 0b1110:
      if i <= s.len - 3:
        result = Rune((uint32(s[i]) and ones(4)) shl 12 or
          (uint32(s[i+1]) and ones(6)) shl 6 or (uint32(s[i+2]) and ones(6)))
        i += 2
    elif uint32(s[i]) shr 3 == 0b11110:
      if i <= s.len - 4:
        result = Rune((uint32(s[i]) and ones(3)) shl 18 or
          (uint32(s[i+1]) and ones(6)) shl 12 or
          (uint32(s[i+2]) and ones(6)) shl 6 or
          (uint32(s[i+3]) and ones(6)))
        i += 3
    inc i

func notwidth*(s: openArray[char]): int =
  result = 0
  var i = 0
  while i < s.len:
    var r: Rune
    fastRuneAt(s, i, r)
    result += r.width()

func twidth*(s: string; w: int): int =
  var i = w
  for r in s.runes:
    i += r.twidth(w)
  return i - w

func padToWidth*(s: string; size: int; schar = '$'): string =
  result = newStringOfCap(s.len)
  var w = 0
  var r: Rune
  var i = 0
  while i < s.len:
    fastRuneAt(s, i, r)
    w += r.width()
    if w > size - 1:
      break
    result &= r
  if w > size - 1:
    if w == size and i == s.len:
      result &= r
    else:
      result &= schar
  while w < size:
    result &= ' '
    inc w
