import std/strutils
import std/unicode

import utils/proptable
import utils/charcategory
import utils/map

include res/map/charwidth_gen

func isDoubleWidthHigh(r: Rune): bool =
  return DoubleWidthRanges.isInRange(uint32(r))

func isDoubleWidthAmbiguousHigh(r: Rune): bool =
  # binary search in table of non-spacing characters
  if DoubleWidthAmbiguousRanges.isInRange(uint32(r)):
    return true
  return r.isDoubleWidthHigh()

func isCombining(r: Rune): bool =
  return Combining.isInRange(uint32(r))

# One of the few global variables in the code. Honestly, it should not exist.
var is_cjk_ambiguous = false
proc set_cjk_ambiguous*(b: bool) =
  is_cjk_ambiguous = b

# Warning: this shouldn't be called without normalization.
# We could make this function more efficient in edge cases, but it's already
# too complex for my taste.
func width*(r: Rune): int =
  {.cast(noSideEffect).}:
    let u = uint32(r)
    if u <= 0xFFFF:
      if r in CombiningTable:
        return 0
      if not is_cjk_ambiguous:
        if r in DoubleWidthTable:
          return 2
      else:
        if r in DoubleWidthTable or DoubleWidthAmbiguousRanges.isInRange(u):
          return 2
    else:
      if r.isCombining():
        return 0
      if not is_cjk_ambiguous:
        if r.isDoubleWidthHigh():
          return 2
      else:
        if r.isDoubleWidthAmbiguousHigh():
          return 2
    return 1

# Width, but also works with tabs.
# Needs the column width of the text so far.
func twidth*(r: Rune, w: int): int =
  if r != Rune('\t'):
    return r.width()
  return ((w div 8) + 1) * 8 - w

func width*(s: string): int =
  for r in s.runes():
    result += r.twidth(result)

func width*(s: string, start, len: int): int =
  var i = start
  var m = len
  if m > s.len: m = s.len
  while i < m:
    var r: Rune
    fastRuneAt(s, i, r)
    result += r.twidth(result)

func notwidth*(s: string): int =
  for r in s.runes:
    result += r.width()

func twidth*(s: string, w: int): int =
  var i = w
  for r in s.runes():
    i += r.twidth(w)
  return i - w

func padToWidth*(str: string, size: int, schar = '$'): string =
  if str.width() < size:
    return str & ' '.repeat(size - str.width())
  else:
    let size = size - 1
    result = newStringOfCap(str.len)
    var w = 0
    var i = 0
    while i < str.len:
      var r: Rune
      fastRuneAt(str, i, r)
      if w + r.width <= size:
        result &= r
        w += r.width
    result &= schar

func isDigitAscii(r: Rune): bool =
  return uint32(r) < 128 and char(r) in AsciiDigit

type BreakCategory* = enum
  BREAK_ALPHA, BREAK_SPACE, BREAK_SYMBOL

func breaksWord*(r: Rune): bool =
  return not (r.isDigitAscii() or r.width() == 0 or r.isAlpha())

func breaksViWordCat*(r: Rune): BreakCategory =
  if r.isWhiteSpace():
    return BREAK_SPACE
  elif r.breaksWord():
    return BREAK_SYMBOL
  return BREAK_ALPHA

func breaksWordCat*(r: Rune): BreakCategory =
  if not r.breaksWord():
    return BREAK_ALPHA
  return BREAK_SPACE

func breaksBigWordCat*(r: Rune): BreakCategory =
  if not r.isWhiteSpace():
    return BREAK_ALPHA
  return BREAK_SPACE
