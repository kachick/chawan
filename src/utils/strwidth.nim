import std/strutils
import std/unicode

import data/charwidth
import js/error
import types/opt
import utils/charcategory
import utils/map

# Combining chars from https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c
#
# The following two functions define the column width of an ISO 10646
# character as follows:
#
#   - The null character (U+0000) has a column width of 0.
#
#   - Other C0/C1 control characters and DEL will lead to a return value of 0
#
#   - Non-spacing and enclosing combining characters (general category code Mn
#     or Me in the Unicode database) have a column width of 0.
#
#   - SOFT HYPHEN (U+00AD) has a column width of 1.
#
#   - Other format characters (general category code Cf in the Unicode
#     database) and ZERO WIDTH SPACE (U+200B) have a column width of 0.
#
#   - Hangul Jamo medial vowels and final consonants (U+1160-U+11FF) have a
#     column width of 0.
#
#   - Spacing characters in the East Asian Wide (W) or East Asian Full-width
#     (F) category as defined in Unicode Technical Report #11 have a column
#     width of 2.
#
#   - All remaining characters (including all printable ISO 8859-1 and WGL4
#     characters, Unicode control characters, etc.) have a column width of 1.
#

# sorted list of non-overlapping intervals of non-spacing characters generated
# by "uniset +cat=Me +cat=Mn +cat=Cf -00AD +1160-11FF +200B c"
const Combining = [
  (0x0300u32, 0x036Fu32), (0x0483u32, 0x0486u32), (0x0488u32, 0x0489u32),
  (0x0591u32, 0x05BDu32), (0x05BFu32, 0x05BFu32), (0x05C1u32, 0x05C2u32),
  (0x05C4u32, 0x05C5u32), (0x05C7u32, 0x05C7u32), (0x0600u32, 0x0603u32),
  (0x0610u32, 0x0615u32), (0x064Bu32, 0x065Eu32), (0x0670u32, 0x0670u32),
  (0x06D6u32, 0x06E4u32), (0x06E7u32, 0x06E8u32), (0x06EAu32, 0x06EDu32),
  (0x070Fu32, 0x070Fu32), (0x0711u32, 0x0711u32), (0x0730u32, 0x074Au32),
  (0x07A6u32, 0x07B0u32), (0x07EBu32, 0x07F3u32), (0x0901u32, 0x0902u32),
  (0x093Cu32, 0x093Cu32), (0x0941u32, 0x0948u32), (0x094Du32, 0x094Du32),
  (0x0951u32, 0x0954u32), (0x0962u32, 0x0963u32), (0x0981u32, 0x0981u32),
  (0x09BCu32, 0x09BCu32), (0x09C1u32, 0x09C4u32), (0x09CDu32, 0x09CDu32),
  (0x09E2u32, 0x09E3u32), (0x0A01u32, 0x0A02u32), (0x0A3Cu32, 0x0A3Cu32),
  (0x0A41u32, 0x0A42u32), (0x0A47u32, 0x0A48u32), (0x0A4Bu32, 0x0A4Du32),
  (0x0A70u32, 0x0A71u32), (0x0A81u32, 0x0A82u32), (0x0ABCu32, 0x0ABCu32),
  (0x0AC1u32, 0x0AC5u32), (0x0AC7u32, 0x0AC8u32), (0x0ACDu32, 0x0ACDu32),
  (0x0AE2u32, 0x0AE3u32), (0x0B01u32, 0x0B01u32), (0x0B3Cu32, 0x0B3Cu32),
  (0x0B3Fu32, 0x0B3Fu32), (0x0B41u32, 0x0B43u32), (0x0B4Du32, 0x0B4Du32),
  (0x0B56u32, 0x0B56u32), (0x0B82u32, 0x0B82u32), (0x0BC0u32, 0x0BC0u32),
  (0x0BCDu32, 0x0BCDu32), (0x0C3Eu32, 0x0C40u32), (0x0C46u32, 0x0C48u32),
  (0x0C4Au32, 0x0C4Du32), (0x0C55u32, 0x0C56u32), (0x0CBCu32, 0x0CBCu32),
  (0x0CBFu32, 0x0CBFu32), (0x0CC6u32, 0x0CC6u32), (0x0CCCu32, 0x0CCDu32),
  (0x0CE2u32, 0x0CE3u32), (0x0D41u32, 0x0D43u32), (0x0D4Du32, 0x0D4Du32),
  (0x0DCAu32, 0x0DCAu32), (0x0DD2u32, 0x0DD4u32), (0x0DD6u32, 0x0DD6u32),
  (0x0E31u32, 0x0E31u32), (0x0E34u32, 0x0E3Au32), (0x0E47u32, 0x0E4Eu32),
  (0x0EB1u32, 0x0EB1u32), (0x0EB4u32, 0x0EB9u32), (0x0EBBu32, 0x0EBCu32),
  (0x0EC8u32, 0x0ECDu32), (0x0F18u32, 0x0F19u32), (0x0F35u32, 0x0F35u32),
  (0x0F37u32, 0x0F37u32), (0x0F39u32, 0x0F39u32), (0x0F71u32, 0x0F7Eu32),
  (0x0F80u32, 0x0F84u32), (0x0F86u32, 0x0F87u32), (0x0F90u32, 0x0F97u32),
  (0x0F99u32, 0x0FBCu32), (0x0FC6u32, 0x0FC6u32), (0x102Du32, 0x1030u32),
  (0x1032u32, 0x1032u32), (0x1036u32, 0x1037u32), (0x1039u32, 0x1039u32),
  (0x1058u32, 0x1059u32), (0x1160u32, 0x11FFu32), (0x135Fu32, 0x135Fu32),
  (0x1712u32, 0x1714u32), (0x1732u32, 0x1734u32), (0x1752u32, 0x1753u32),
  (0x1772u32, 0x1773u32), (0x17B4u32, 0x17B5u32), (0x17B7u32, 0x17BDu32),
  (0x17C6u32, 0x17C6u32), (0x17C9u32, 0x17D3u32), (0x17DDu32, 0x17DDu32),
  (0x180Bu32, 0x180Du32), (0x18A9u32, 0x18A9u32), (0x1920u32, 0x1922u32),
  (0x1927u32, 0x1928u32), (0x1932u32, 0x1932u32), (0x1939u32, 0x193Bu32),
  (0x1A17u32, 0x1A18u32), (0x1B00u32, 0x1B03u32), (0x1B34u32, 0x1B34u32),
  (0x1B36u32, 0x1B3Au32), (0x1B3Cu32, 0x1B3Cu32), (0x1B42u32, 0x1B42u32),
  (0x1B6Bu32, 0x1B73u32), (0x1DC0u32, 0x1DCAu32), (0x1DFEu32, 0x1DFFu32),
  (0x200Bu32, 0x200Fu32), (0x202Au32, 0x202Eu32), (0x2060u32, 0x2063u32),
  (0x206Au32, 0x206Fu32), (0x20D0u32, 0x20EFu32), (0x302Au32, 0x302Fu32),
  (0x3099u32, 0x309Au32), (0xA806u32, 0xA806u32), (0xA80Bu32, 0xA80Bu32),
  (0xA825u32, 0xA826u32), (0xFB1Eu32, 0xFB1Eu32), (0xFE00u32, 0xFE0Fu32),
  (0xFE20u32, 0xFE23u32), (0xFEFFu32, 0xFEFFu32), (0xFFF9u32, 0xFFFBu32),
  (0x10A01u32, 0x10A03u32), (0x10A05u32, 0x10A06u32), (0x10A0Cu32, 0x10A0Fu32),
  (0x10A38u32, 0x10A3Au32), (0x10A3Fu32, 0x10A3Fu32), (0x1D167u32, 0x1D169u32),
  (0x1D173u32, 0x1D182u32), (0x1D185u32, 0x1D18Bu32), (0x1D1AAu32, 0x1D1ADu32),
  (0x1D242u32, 0x1D244u32), (0xE0001u32, 0xE0001u32), (0xE0020u32, 0xE007Fu32),
  (0xE0100u32, 0xE01EFu32)
]

func isDoubleWidthHigh(r: Rune): bool =
  return DoubleWidthRanges.isInRange(uint32(r))

func isDoubleWidthAmbiguousHigh(r: Rune): bool =
  # binary search in table of non-spacing characters
  if DoubleWidthAmbiguousRanges.isInRange(uint32(r)):
    return true
  return r.isDoubleWidthHigh()

func isCombining(r: Rune): bool =
  return DoubleWidthAmbiguousRanges.isInRange(uint32(r))

# Lookup tables for characters on the BMP. This "only" takes up 8k of space
# per table, as opposed to the 135k that storing all characters would require.
# The downside is obviously that we need a binary search fallback for non-bmp.
# We do not store a lookup table of ambiguous ranges, either.

static:
  # following won't work on 16-bit
  doAssert sizeof(int) >= sizeof(Rune)

type PropertyTable = array[0x10000 div (sizeof(int) * 8), int]

type RangeMap = openarray[(uint32, uint32)]

func makePropertyTable(ranges: RangeMap, skip: RangeMap = @[]): PropertyTable =
  var ucs: uint32 = 0
  var j = 0
  var k = 0
  while ucs <= 0xFFFF:
    if k > ranges.len:
      break
    if ranges[k][0] > ucs:
      ucs = ranges[k][0]
      continue
    if ranges[k][1] < ucs:
      inc k
      continue
    if j != skip.len and ucs == skip[j][0]:
      ucs = skip[j][1] + 1
      continue
    let i = ucs div (sizeof(int) * 8)
    let m = ucs mod (sizeof(int) * 8)
    result[i] = result[i] or (1 shl m)
    inc ucs

const DoubleWidthTable = (func(): PropertyTable =
  var ptab = makePropertyTable(DoubleWidthRanges, Combining)
  # Control chars return a width of 2, and are displayed as ^{letter}.
  for c in Controls:
    let u = int(c)
    let i = u div (sizeof(int) * 8)
    let m = u mod (sizeof(int) * 8)
    ptab[i] = ptab[i] or (1 shl m)
  return ptab
)()

const CombiningTable = makePropertyTable(Combining)

# One of the few global variables in the code. Honestly, it should not exist.
var is_cjk_ambiguous = false
proc set_cjk_ambiguous*(b: bool) =
  is_cjk_ambiguous = b

{.push boundChecks:off.}
func contains(props: PropertyTable, r: Rune): bool =
  let u = int(r)
  let i = u div (sizeof(int) * 8)
  let m = u mod (sizeof(int) * 8)
  return (props[i] and (1 shl m)) != 0
{.pop.}

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

func breaksWord*(r: Rune): bool =
  return not (r.isDigitAscii() or r.width() == 0 or r.isAlpha())

type BoundaryFunction* = proc(x: Rune): JSResult[bool]

proc breaksWord*(r: Rune, check: Opt[BoundaryFunction]): bool =
  if check.isSome:
    let f = check.get()
    let v = f(r)
    if v.isSome: #TODO report error?
      return v.get()
  return r.breaksWord()
