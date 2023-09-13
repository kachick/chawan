import algorithm
import strutils
import unicode
import os
import math
import sequtils
import options

import bindings/libunicode
import data/charwidth
import data/idna
import js/error
import utils/map
import utils/opt
import lib/punycode

when defined(posix):
  import posix

const C0Controls* = {chr(0x00)..chr(0x1F)}
const Controls* = (C0Controls + {chr(0x7F)})
const Ascii* = {chr(0x00)..chr(0x7F)}
const AsciiUpperAlpha* = {'A'..'Z'}
const AsciiLowerAlpha* = {'a'..'z'}
const AsciiAlpha* = (AsciiUpperAlpha + AsciiLowerAlpha)
const NonAscii* = (AllChars - Ascii)
const AsciiDigit* = {'0'..'9'}
const AsciiAlphaNumeric* = AsciiAlpha + AsciiDigit
const AsciiHexDigit* = (AsciiDigit + {'a'..'f', 'A'..'F'})
const AsciiWhitespace* = {' ', '\n', '\r', '\t', '\f'}

func isWhitespace*(c: char): bool {.inline.} =
  return c in AsciiWhitespace

func onlyWhitespace*(s: string): bool =
  for c in s:
    if not c.isWhitespace():
      return false
  return true

func isControlChar*(r: Rune): bool =
  case r
  of Rune(0x00)..Rune(0x1F): return true
  of Rune(0x7F): return true
  else: return false

func isC0ControlOrSpace*(c: char): bool =
  return c in (Controls + {' '})

func genControlCharMap*(): string =
  for c in low(char)..high(char):
    if c == '?':
      result &= char(127)
    else:
      result &= char((int(c) and 0x1f))

const controlCharMap = genControlCharMap()

func getControlChar*(c: char): char =
  return controlCharMap[int(c)]

func genControlLetterMap*(): string =
  for c in low(char)..high(char):
    if c == char(127):
      result &= '?'
    else:
      result &= char((int(c) or 0x40))

const controlLetterMap = genControlLetterMap()

func getControlLetter*(c: char): char =
  return controlLetterMap[int(c)]

const lowerChars = (func(): array[char, char] =
  for i in 0..255:
    if char(i) in 'A'..'Z':
      result[char(i)] = char(i + 32)
    else:
      result[char(i)] = char(i)
)()

func tolower*(c: char): char =
  return lowerChars[c]

proc mtoLowerAscii*(str: var string) =
  for i in 0 ..< str.len:
    str[i] = str[i].tolower()

func toHeaderCase*(str: string): string =
  result = str
  var flip = true
  for i in 0..str.high:
    if flip:
      result[i] = result[i].toUpperAscii()
    flip = result[i] == '-'

func toScreamingSnakeCase*(str: string): string = # input is camel case
  if str.len >= 1: result &= str[0].toUpperAscii()
  for c in str[1..^1]:
    if c in AsciiUpperAlpha:
      result &= '_'
      result &= c
    else:
      result &= c.toUpperAscii()

func snakeToKebabCase*(str: string): string =
  result = str
  for c in result.mitems:
    if c == '_':
      c = '-'

func normalizeLocale*(s: string): string =
  for i in 0 ..< s.len:
    if cast[uint8](s[i]) > 0x20 and s[i] != '_' and s[i] != '-':
      result &= s[i].toLowerAscii()

func isAscii*(r: Rune): bool =
  return cast[uint32](r) < 128

func startsWithNoCase*(str, prefix: string): bool =
  if str.len < prefix.len: return false
  # prefix.len is always lower
  var i = 0
  while true:
    if i == prefix.len: return true
    if str[i].tolower() != prefix[i].tolower(): return false
    inc i

const hexCharMap = (func(): array[char, int] =
  for i in 0..255:
    case chr(i)
    of '0'..'9': result[char(i)] = i - ord('0')
    of 'a'..'f': result[char(i)] = i - ord('a') + 10
    of 'A'..'F': result[char(i)] = i - ord('A') + 10
    else: result[char(i)] = -1
)()

const decCharMap = (func(): array[char, int] =
  for i in 0..255:
    case char(i)
    of '0'..'9': result[char(i)] = i - ord('0')
    else: result[char(i)] = -1
)()

func hexValue*(c: char): int =
  return hexCharMap[c]

func decValue*(c: char): int =
  return decCharMap[c]

func isAscii*(s: string): bool =
  for c in s:
    if c > char(0x80):
      return false
  return true

const HexCharsUpper = "0123456789ABCDEF"
const HexCharsLower = "0123456789abcdef"
func pushHex*(buf: var string, u: uint8) =
  buf &= HexCharsUpper[u shr 4]
  buf &= HexCharsUpper[u and 0xF]

func pushHex*(buf: var string, c: char) =
  buf.pushHex(cast[uint8](c))

func toHexLower*(u: uint16): string =
  var x = u
  let len = if (u and 0xF000) != 0:
    4
  elif (u and 0x0F00) != 0:
    3
  elif (u and 0xF0) != 0:
    2
  else:
    1
  var s = newString(len)
  for i in countdown(len - 1, 0):
    s[i] = HexCharsLower[x and 0xF]
    x = x shr 4
  return s

func equalsIgnoreCase*(s1, s2: string): bool {.inline.} =
  return s1.cmpIgnoreCase(s2) == 0

func isDigitAscii*(r: Rune): bool =
  return int(r) < 256 and isDigit(char(r))

func substr*(s: seq[Rune], i, j: int): seq[Rune] =
  if s.len == 0:
    return @[]
  return s[min(high(s), i)..min(high(s), j - 1)]

func stripAndCollapse*(s: string): string =
  var i = 0
  while i < s.len and s[i] in AsciiWhitespace:
    inc i
  var space = false
  while i < s.len:
    if s[i] notin AsciiWhitespace:
      if space:
        result &= ' '
        space = false
      result &= s[i]
    elif not space:
      space = true
    else:
      result &= ' '
    inc i

func skipBlanks*(buf: string, at: int): int =
  result = at
  while result < buf.len and buf[result].isWhitespace():
    inc result

func until*(s: string, c: set[char]): string =
  var i = 0
  while i < s.len:
    if s[i] in c:
      break
    result.add(s[i])
    inc i

func until*(s: string, c: char): string = s.until({c})

func after*(s: string, c: set[char]): string =
  var i = 0
  while i < s.len:
    if s[i] in c:
      return s.substr(i + 1)
    inc i

func after*(s: string, c: char): string = s.after({c})

func afterLast*(s: string, c: set[char], n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(i + 1)
  return s

func afterLast*(s: string, c: char, n = 1): string = s.afterLast({c}, n)

func beforeLast*(s: string, c: set[char], n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(0, i)
  return s

func beforeLast*(s: string, c: char, n = 1): string = s.afterLast({c}, n)

proc c_sprintf(buf, fm: cstring): cint {.header: "<stdio.h>", importc: "sprintf", varargs}

# From w3m
const SizeUnit = [
  cstring"b", cstring"kb", cstring"Mb", cstring"Gb", cstring"Tb", cstring"Pb",
  cstring"Eb", cstring"Zb", cstring"Bb", cstring"Yb"
]
func convert_size*(size: int): string =
  var sizepos = 0
  var csize = float32(size)
  while csize >= 999.495 and sizepos < SizeUnit.len:
    csize = csize / 1024.0
    inc sizepos
  result = newString(10)
  let f = floor(csize * 100 + 0.5) / 100
  discard c_sprintf(cstring(result), cstring("%.3g%s"), f, SizeUnit[sizepos])
  result.setLen(cstring(result).len)

func number_additive*(i: int, range: HSlice[int, int], symbols: openarray[(int, string)]): string =
  if i notin range:
    return $i

  var n = i
  var at = 0
  while n > 0:
    if n >= symbols[at][0]:
      n -= symbols[at][0]
      result &= symbols[at][1]
      continue
    inc at

  return result

const romanNumbers = [
  (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
  (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
]

const romanNumbers_lower = romanNumbers.map(proc(x: auto): auto =
  (x[0], x[1].tolower()))

func romanNumber*(i: int): string =
  return number_additive(i, 1..3999, romanNumbers)

func romanNumber_lower*(i: int): string =
  return number_additive(i, 1..3999, romanNumbers_lower)

func japaneseNumber*(i: int): string =
  if i == 0:
    return "〇"
  var n = i
  if i < 0:
    result &= "マイナス"
    n *= -1

  let o = n

  var ss: seq[string]
  var d = 0
  while n > 0:
    let m = n mod 10

    if m != 0:
      case d
      of 1: ss.add("十")
      of 2: ss.add("百")
      of 3: ss.add("千")
      of 4:
        ss.add("万")
        ss.add("一")
      of 5:
        ss.add("万")
        ss.add("十")
      of 6:
        ss.add("万")
        ss.add("百")
      of 7:
        ss.add("万")
        ss.add("千")
        ss.add("一")
      of 8:
        ss.add("億")
        ss.add("一")
      of 9:
        ss.add("億")
        ss.add("十")
      else: discard
    case m
    of 0:
      inc d
      n = n div 10
    of 1:
      if o == n:
        ss.add("一")
    of 2: ss.add("二")
    of 3: ss.add("三")
    of 4: ss.add("四")
    of 5: ss.add("五")
    of 6: ss.add("六")
    of 7: ss.add("七")
    of 8: ss.add("八")
    of 9: ss.add("九")
    else: discard
    n -= m

  n = ss.len - 1
  while n >= 0:
    result &= ss[n]
    dec n

# Implements https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#signed-integers
func parseInt32*(s: string): Option[int32] =
  var sign: int32 = 1
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  if i == s.len or s[i] notin AsciiDigit:
    return none(int32)
  var integer = int32(decValue(s[i]))
  inc i
  while i < s.len and isDigit(s[i]):
    if unlikely(integer != 0 and high(int32) div 10 < integer):
      return none(int32) # overflow
    integer *= 10
    let c = int32(decValue(s[i]))
    if unlikely(high(int32) - c < integer):
      return none(int32) # overflow
    integer += c
    inc i
  return some(sign * integer)

func parseInt64*(s: string): Opt[int64] =
  var sign: int64 = 1
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  if i == s.len or s[i] notin AsciiDigit:
    return err()
  var integer = int64(decValue(s[i]))
  inc i
  while i < s.len and isDigit(s[i]):
    if unlikely(integer != 0 and high(int64) div 10 < integer):
      return err() # overflow
    integer *= 10
    let c = int64(decValue(s[i]))
    if unlikely(high(int64) - c < integer):
      return err() # overflow
    integer += c
    inc i
  return ok(sign * integer)

func parseUInt8*(s: string): Option[uint8] =
  var i = 0
  if i < s.len and s[i] == '+':
    inc i
  if i == s.len or s[i] notin AsciiDigit:
    return none(uint8)
  var integer = uint8(decValue(s[i]))
  inc i
  while i < s.len and isDigit(s[i]):
    if unlikely(integer != 0 and high(uint8) div 10 < integer):
      return none(uint8) # overflow
    integer *= 10
    let c = uint8(decValue(s[i]))
    if unlikely(high(uint8) - c < integer):
      return none(uint8) # overflow
    integer += uint8(c)
    inc i
  return some(integer)

func parseUInt32*(s: string): Option[uint32] =
  var i = 0
  if i < s.len and s[i] == '+':
    inc i
  if i == s.len or s[i] notin AsciiDigit:
    return none(uint32)
  var integer = uint32(decValue(s[i]))
  inc i
  while i < s.len and isDigit(s[i]):
    if unlikely(integer != 0 and high(uint32) div 10 < integer):
      return none(uint32) # overflow
    integer *= 10
    let c = uint32(decValue(s[i]))
    if unlikely(high(uint32) - c < integer):
      return none(uint32) # overflow
    integer += c
    inc i
  return some(integer)

#TODO not sure where this algorithm is from...
func parseFloat64*(s: string): float64 =
  var sign = 1
  var t = 1
  var d = 0
  var integer: float64 = 0
  var f: float64 = 0
  var e: float64 = 0

  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i

  while i < s.len and isDigit(s[i]):
    integer *= 10
    integer += float64(decValue(s[i]))
    inc i

  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and isDigit(s[i]):
      f *= 10
      f += float64(decValue(s[i]))
      inc i
      inc d

  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and s[i] == '-':
      t = -1
      inc i
    elif i < s.len and s[i] == '+':
      inc i

    while i < s.len and isDigit(s[i]):
      e *= 10
      e += float64(decValue(s[i]))
      inc i

  return float64(sign) * (integer + f * pow(10, float64(-d))) * pow(10, (float64(t) * e))

func isSurrogate*(r: Rune): bool = int32(r) in 0xD800..0xDFFF
func isNonCharacter*(r: Rune): bool =
  let n = int32(r)
  n in 0xFDD0..0xFDEF or
  n in [0xFFFE, 0xFFFF, 0x1FFFE, 0x1FFFF, 0x2FFFE, 0x2FFFF, 0x3FFFE, 0x3FFFF,
        0x4FFFE, 0x4FFFF, 0x5FFFE, 0x5FFFF, 0x6FFFE, 0x6FFFF, 0x7FFFE, 0x7FFFF,
        0x8FFFE, 0x8FFFF, 0x9FFFE, 0x9FFFF, 0xAFFFE, 0xAFFFF, 0xBFFFE, 0xBFFFF,
        0xCFFFE, 0xCFFFF, 0xDFFFE, 0xDFFFF, 0xEFFFE, 0xEFFFF, 0xFFFFE, 0xFFFFF,
        0x10FFFE, 0x10FFFF]

const ControlPercentEncodeSet* = (Controls + NonAscii)
const FragmentPercentEncodeSet* = (Controls + NonAscii)
const QueryPercentEncodeSet* = (ControlPercentEncodeSet + {' ', '"', '#', '<', '>'})
const SpecialQueryPercentEncodeSet* = (QueryPercentEncodeSet + {'\''})
const PathPercentEncodeSet* = (QueryPercentEncodeSet + {'?', '`', '{', '}'})
const UserInfoPercentEncodeSet* = (PathPercentEncodeSet + {'/', ':', ';', '=', '@', '['..'^', '|'})
const ComponentPercentEncodeSet* = (UserInfoPercentEncodeSet + {'$'..'&', '+', ','})
const ApplicationXWWWFormUrlEncodedSet* = (ComponentPercentEncodeSet + {'!', '\''..')', '~'})
# used by client
when defined(windows) or defined(OS2) or defined(DOS):
  const LocalPathPercentEncodeSet* = (Ascii - AsciiAlpha - AsciiDigit - {'.', '\\', '/'})
else:
  const LocalPathPercentEncodeSet* = (Ascii - AsciiAlpha - AsciiDigit -  {'.', '/'})

proc percentEncode*(append: var string, c: char, set: set[char], spaceAsPlus = false) {.inline.} =
  if spaceAsPlus and c == ' ':
    append &= '+'
  elif c notin set:
    append &= c
  else:
    append &= '%'
    append.pushHex(c)

proc percentEncode*(append: var string, s: string, set: set[char], spaceAsPlus = false) {.inline.} =
  for c in s:
    append.percentEncode(c, set, spaceAsPlus)

func percentEncode*(c: char, set: set[char], spaceAsPlus = false): string {.inline.} =
  result.percentEncode(c, set, spaceAsPlus)

func percentEncode*(s: string, set: set[char], spaceAsPlus = false): string =
  result.percentEncode(s, set, spaceAsPlus)

func percentDecode*(input: string): string =
  var i = 0
  while i < input.len:
    let c = input[i]
    if c != '%' or i + 2 >= input.len:
      result &= c
    else:
      let h1 = input[i + 1].hexValue
      let h2 = input[i + 2].hexValue
      if h1 == -1 or h2 == -1:
        result &= c
      else:
        result &= char((h1 shl 4) or h2)
        i += 2
    inc i

#basically std join but with char
func join*(ss: openarray[string], sep: char): string =
  if ss.len == 0:
    return ""
  var n = ss.high - 1
  for i in 0..high(ss):
    n += ss[i].len
  result = newStringOfCap(n)
  result &= ss[0]
  for i in 1..high(ss):
    result &= sep
    result &= ss[i]

proc passRealloc(opaque: pointer, p: pointer, size: csize_t): pointer {.cdecl.} =
  return realloc(p, size)

proc mnormalize*(rs: var seq[Rune], form = UNICODE_NFC) = {.cast(noSideEffect).}:
  if rs.len == 0: return
  var outbuf: ptr uint32
  let out_len = unicode_normalize(addr outbuf,
                                  cast[ptr uint32](unsafeAddr rs[0]),
                                  cint(rs.len), form, nil, passRealloc)
  if out_len < 0:
    raise newException(Defect, "Unicode normalization failed")
  if out_len == 0:
    return
  rs = cast[seq[Rune]](newSeqUninitialized[uint32](out_len))
  copyMem(addr rs[0], outbuf, out_len * sizeof(uint32))
  dealloc(outbuf)

#TODO maybe a utf8 normalization procedure?
proc mnormalize*(s: var string) =
  if s.isAscii():
    return # no need to normalize ascii
  var rs = s.toRunes()
  rs.mnormalize()
  s = $rs

func normalize*(rs: seq[Rune], form = UNICODE_NFC): seq[Rune] = {.cast(noSideEffect).}:
  if rs.len == 0: return
  var outbuf: ptr uint32
  let out_len = unicode_normalize(addr outbuf,
                                  cast[ptr uint32](unsafeAddr rs[0]),
                                  cint(rs.len), form, nil, passRealloc)
  if out_len < 0:
    raise newException(Defect, "Unicode normalization failed")
  if out_len == 0:
    return
  result = cast[seq[Rune]](newSeqUninitialized[uint32](out_len))
  copyMem(addr result[0], outbuf, out_len * sizeof(uint32))
  dealloc(outbuf)

type u32pair {.packed.} = object
  a: uint32
  b: uint32

func cmpRange(x: u32pair, y: uint32): int =
  if x.a < y:
    return -1
  elif x.b > y:
    return 1
  return 0

func processIdna(str: string, checkhyphens, checkbidi, checkjoiners, transitionalprocessing: bool): Option[string] =
  var mapped: seq[Rune]
  for r in str.runes():
    let status = getIdnaTableStatus(r)
    case status
    of IDNA_DISALLOWED: return none(string) #error
    of IDNA_IGNORED: discard
    of IDNA_MAPPED: mapped &= getIdnaMapped(r).toRunes()
    of IDNA_DEVIATION:
      if transitionalprocessing:
        mapped &= getDeviationMapped(r).toRunes()
      else:
        mapped &= r
    of IDNA_VALID: mapped &= r
  if mapped.len == 0: return
  mapped.mnormalize()
  var cr: CharRange
  {.cast(noSideEffect).}:
    cr_init(addr cr, nil, passRealloc)
    assert unicode_general_category(addr cr, "Mark") == 0
  var labels: seq[string]
  for label in ($mapped).split('.'):
    if label.startsWith("xn--"):
      try:
        let s = punycode.decode(label.substr("xn--".len))
        let x0 = s.toRunes()
        let x1 = normalize(x0)
        if x0 != x1:
          return none(string) #error
        if checkhyphens:
          if s.len >= 4 and s[2] == '-' and s[3] == '-':
            return none(string) #error
          if s.len > 0 and s[0] == '-' and s[^1] == '-':
            return none(string) #error
        if x0.len > 0:
          let cps = cast[ptr UncheckedArray[u32pair]](cr.points)
          let c = cast[uint32](x0[0])
          if binarySearch(toOpenArray(cps, 0, cr.len div 2 - 1), c, cmpRange) != -1:
            return none(string) #error
        for r in x0:
          if r == Rune('.'):
            return none(string) #error
          let status = getIdnaTableStatus(r)
          case status
          of IDNA_DISALLOWED, IDNA_IGNORED, IDNA_MAPPED:
            return none(string) #error
          of IDNA_DEVIATION:
            if transitionalprocessing:
              return none(string) #error
          of IDNA_VALID: discard
          #TODO check joiners
          #TODO check bidi
        labels.add(s)
      except PunyError:
        return none(string) #error
    else:
      labels.add(label)
  cr_free(addr cr)
  return some(labels.join('.'))

func unicodeToAscii*(s: string, checkhyphens, checkbidi, checkjoiners, transitionalprocessing, verifydnslength: bool): Option[string] =
  let processed = s.processIdna(checkhyphens, checkbidi, checkjoiners,
                                transitionalprocessing)
  if processed.isnone:
    return none(string) #error
  var labels: seq[string]
  var all = 0
  for label in processed.get.split('.'):
    if not label.isAscii():
      try:
        let converted = "xn--" & punycode.encode(label)
        labels.add(converted)
      except PunyError:
        return none(string) #error
    else:
      labels.add(label)
    if verifydnslength:
      let rl = labels[^1].runeLen()
      if rl notin 1..63:
        return none(string)
      all += rl
  if verifydnslength:
    if all notin 1..253:
      return none(string) #error
  return some(labels.join('.'))


# https://www.w3.org/TR/xml/#NT-Name
const NameStartCharRanges = [
  (0xC0, 0xD6),
  (0xD8, 0xF6),
  (0xF8, 0x2FF),
  (0x370, 0x37D),
  (0x37F, 0x1FFF),
  (0x200C, 0x200D),
  (0x2070, 0x218F),
  (0x2C00, 0x2FEF),
  (0x3001, 0xD7FF),
  (0xF900, 0xFDCF),
  (0xFDF0, 0xFFFD),
  (0x10000, 0xEFFFF)
]
const NameCharRanges = [ # + NameStartCharRanges
  (0xB7, 0xB7),
  (0x0300, 0x036F),
  (0x203F, 0x2040)
]
const NameStartCharAscii = {':', '_'} + AsciiAlpha
const NameCharAscii = NameStartCharAscii + {'-', '.'} + AsciiDigit
func matchNameProduction*(str: string): bool =
  if str.len == 0:
    return false
  # NameStartChar
  var i = 0
  var r: Rune
  if str[i] in Ascii:
    if str[i] notin NameStartCharAscii:
      return false
    inc i
  else:
    fastRuneAt(str, i, r)
    if not isInRange(NameStartCharRanges, int32(r)):
      return false
  # NameChar
  while i < str.len:
    if str[i] in Ascii:
      if str[i] notin NameCharAscii:
        return false
      inc i
    else:
      fastRuneAt(str, i, r)
      if not isInRange(NameStartCharRanges, int32(r)) and
          not isInMap(NameCharRanges, int32(r)):
        return false
  return true

func matchQNameProduction*(s: string): bool =
  if s.len == 0:
    return false
  if s[0] == ':':
    return false
  if s[^1] == ':':
    return false
  var colon = false
  for i in 1 ..< s.len - 1:
    if s[i] == ':':
      if colon:
        return false
      colon = true
  return s.matchNameProduction()

func utf16Len*(s: string): int =
  for r in s.runes:
    if cast[uint32](r) < 0x10000: # ucs-2
      result += 1
    else: # surrogate
      result += 2

proc expandPath*(path: string): string =
  if path.len == 0:
    return path
  result = path
  var i = 0
  if path[0] == '~':
    if path.len == 1:
      result = getHomeDir()
    elif path[1] == '/':
      result = getHomeDir() / path.substr(2)
      inc i
    else:
      when defined(posix):
        i = 1
        var usr = ""
        while path[i] != '/':
          usr &= path[i]
          inc i
        let p = getpwnam(cstring(usr))
        if p != nil:
          result = $p.pw_dir / path.substr(i)

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

func cmp(range: (uint32, uint32), r: Rune): int =
  if range[1] < cast[uint32](r):
    return -1
  elif range[0] > cast[uint32](r):
    return 1
  return 0

func isDoubleWidthHigh(r: Rune): bool =
  return binarySearch(DoubleWidthRanges, r, twtstr.cmp) != -1

func isDoubleWidthAmbiguousHigh(r: Rune): bool =
  # binary search in table of non-spacing characters
  if binarySearch(DoubleWidthAmbiguousRanges, r, twtstr.cmp) != -1:
    return true
  return r.isDoubleWidthHigh()

func isCombining(r: Rune): bool =
  return binarySearch(Combining, r, twtstr.cmp) != -1

# Lookup tables for characters on the BMP. This "only" takes up 8k of space
# per table, as opposed to the 135k that storing all characters would require.
# The downside is obviously that we need a binary search fallback for non-bmp.
# We do not store a lookup table of ambiguous ranges, either.
type PropertyTable = array[0..(0xFFFF div 8), uint8]

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
    let i = ucs div 8
    case ucs mod 8
    of 0: result[i] = result[i] or 0x01
    of 1: result[i] = result[i] or 0x02
    of 2: result[i] = result[i] or 0x04
    of 3: result[i] = result[i] or 0x08
    of 4: result[i] = result[i] or 0x10
    of 5: result[i] = result[i] or 0x20
    of 6: result[i] = result[i] or 0x40
    of 7: result[i] = result[i] or 0x80
    else: discard
    inc ucs

const DoubleWidthTable = (func(): PropertyTable =
  var ptab = makePropertyTable(DoubleWidthRanges, Combining)
  # Control chars return a width of 2, and are displayed as ^{letter}.
  for c in Controls:
    let i = uint16(c) div 8
    case uint16(c) mod 8
    of 0: ptab[i] = ptab[i] or 0x01
    of 1: ptab[i] = ptab[i] or 0x02
    of 2: ptab[i] = ptab[i] or 0x04
    of 3: ptab[i] = ptab[i] or 0x08
    of 4: ptab[i] = ptab[i] or 0x10
    of 5: ptab[i] = ptab[i] or 0x20
    of 6: ptab[i] = ptab[i] or 0x40
    of 7: ptab[i] = ptab[i] or 0x80
    else: discard
  return ptab
)()

const CombiningTable = makePropertyTable(Combining)

# One of the few global variables in the code. Honestly, it should not exist.
var is_cjk_ambiguous = false
proc set_cjk_ambiguous*(b: bool) =
  is_cjk_ambiguous = b

{.push boundChecks:off.}
func contains(props: PropertyTable, r: Rune): bool =
  let i = cast[uint32](r) div 8
  case cast[uint32](r) mod 8
  of 0: return (props[i] and 0x01) != 0
  of 1: return (props[i] and 0x02) != 0
  of 2: return (props[i] and 0x04) != 0
  of 3: return (props[i] and 0x08) != 0
  of 4: return (props[i] and 0x10) != 0
  of 5: return (props[i] and 0x20) != 0
  of 6: return (props[i] and 0x40) != 0
  of 7: return (props[i] and 0x80) != 0
  else: discard
{.pop.}

# Warning: this shouldn't be called without normalization.
# We could make this function more efficient in edge cases, but it's already
# too complex for my taste.
func width*(r: Rune): int =
  {.cast(noSideEffect).}:
    if cast[uint32](r) <= 0xFFFF:
      if r in CombiningTable:
        return 0
      if not is_cjk_ambiguous:
        if r in DoubleWidthTable:
          return 2
      else:
        if r in DoubleWidthTable or
            binarySearch(DoubleWidthAmbiguousRanges, r, twtstr.cmp) != -1:
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

func width*(s: seq[Rune]): int =
  for r in s:
    result += r.twidth(result)

func width*(s: seq[Rune], min, max: int): int =
  var i = min
  var mi = min(max, s.len)
  while i < mi:
    result += s[i].twidth(result)
    inc i

func width*(s: seq[Rune], min: int): int =
  var i = min
  while i < s.len:
    result += s[i].twidth(result)
    inc i

func twidth*(s: string, w: int): int =
  var i = w
  for r in s.runes():
    i += r.twidth(w)
  return i - w

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

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc makeCRLF*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len - 1:
    if s[i] == '\r' and s[i + 1] != '\n':
      result &= '\r'
      result &= '\n'
    elif s[i] != '\r' and s[i + 1] == '\n':
      result &= s[i]
      result &= '\r'
      result &= '\n'
      inc i
    else:
      result &= s[i]
    inc i
  if i < s.len:
    if s[i] == '\r':
      result &= '\r'
      result &= '\n'
    else:
      result &= s[i]
