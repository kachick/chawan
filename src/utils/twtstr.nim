import std/algorithm
import std/math
import std/options
import std/os
import std/strutils
import std/unicode

when defined(posix):
  import std/posix

import types/opt
import utils/charcategory
import utils/map

export charcategory

func onlyWhitespace*(s: string): bool =
  return AllChars - AsciiWhitespace notin s

func isControlChar*(r: Rune): bool =
  return int(r) <= 0x1F or int(r) == 0x7F

func getControlChar*(c: char): char =
  if c == '?':
    return char(127)
  return char(int(c) and 0x1F)

func getControlLetter*(c: char): char =
  if c == char(127):
    return '?'
  return char(int(c) or 0x40)

func toHeaderCase*(str: string): string =
  result = str
  var flip = true
  for c in result.mitems:
    if flip:
      c = c.toUpperAscii()
    flip = c == '-'

func snakeToKebabCase*(str: string): string =
  result = str
  for c in result.mitems:
    if c == '_':
      c = '-'

func kebabToCamelCase*(s: string): string =
  result = s
  var flip = false
  for c in result.mitems:
    if flip:
      c = c.toUpperAscii()
    flip = c == '-'

func camelToKebabCase*(s: string): string =
  result = ""
  for c in s:
    if c in AsciiUpperAlpha:
      result &= '-'
      result &= c.toLowerAscii()
    else:
      result &= c

func startsWithNoCase*(str, prefix: string): bool =
  if str.len < prefix.len: return false
  # prefix.len is always lower
  var i = 0
  while true:
    if i == prefix.len: return true
    if str[i].toLowerAscii() != prefix[i].toLowerAscii(): return false
    inc i

func hexValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  if c in 'a'..'f':
    return int(c) - int('a') + 0xA
  if c in 'A'..'F':
    return int(c) - int('A') + 0xA
  return -1

func decValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  return -1

const HexCharsUpper = "0123456789ABCDEF"
const HexCharsLower = "0123456789abcdef"
func pushHex*(buf: var string; u: uint8) =
  buf &= HexCharsUpper[u shr 4]
  buf &= HexCharsUpper[u and 0xF]

func pushHex*(buf: var string; c: char) =
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

func startsWithIgnoreCase*(s1, s2: string): bool =
  if s1.len < s2.len: return false
  for i in 0 ..< s2.len:
    if s1[i].toLowerAscii() != s2[i].toLowerAscii():
      return false
  return true

func endsWithIgnoreCase*(s1, s2: string): bool =
  if s1.len < s2.len: return false
  for i in countdown(s2.high, 0):
    if s1[i].toLowerAscii() != s2[i].toLowerAscii():
      return false
  return true

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

func skipBlanks*(buf: string; at: int): int =
  result = at
  while result < buf.len and buf[result] in AsciiWhitespace:
    inc result

func until*(s: string; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result.add(s[i])

func untilLower*(s: string; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result.add(s[i].toLowerAscii())

func until*(s: string; c: char; starti = 0): string =
  s.until({c}, starti)

func after*(s: string; c: set[char]): string =
  var i = 0
  while i < s.len:
    if s[i] in c:
      return s.substr(i + 1)
    inc i

func after*(s: string; c: char): string = s.after({c})

func afterLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(i + 1)
  return s

func afterLast*(s: string; c: char; n = 1): string = s.afterLast({c}, n)

func beforeLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(0, i)
  return s

func beforeLast*(s: string; c: char; n = 1): string = s.beforeLast({c}, n)

proc c_sprintf(buf, fm: cstring): cint
  {.header: "<stdio.h>", importc: "sprintf", varargs}

# From w3m
const SizeUnit = [
  cstring"b", cstring"kb", cstring"Mb", cstring"Gb", cstring"Tb", cstring"Pb",
  cstring"Eb", cstring"Zb", cstring"Bb", cstring"Yb"
]
func convertSize*(size: int): string =
  var sizepos = 0
  var csize = float32(size)
  while csize >= 999.495 and sizepos < SizeUnit.len:
    csize = csize / 1024.0
    inc sizepos
  result = newString(10)
  let f = floor(csize * 100 + 0.5) / 100
  discard c_sprintf(cstring(result), cstring("%.3g%s"), f, SizeUnit[sizepos])
  result.setLen(cstring(result).len)

func numberAdditive*(i: int; range: HSlice[int, int];
    symbols: openArray[(int, string)]): string =
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
  (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
  (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
]

const romanNumbersLower = block:
  var res: seq[(int, string)]
  for (n, s) in romanNumbers:
    res.add((n, s.toLowerAscii()))
  res

func romanNumber*(i: int): string =
  return numberAdditive(i, 1..3999, romanNumbers)

func romanNumberLower*(i: int): string =
  return numberAdditive(i, 1..3999, romanNumbersLower)

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
func parseIntImpl[T: SomeSignedInt](s: string; allowed: set[char]; radix: T):
    Option[T] =
  var sign: T = 1
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  if i == s.len:
    return none(T)
  var integer: T = 0
  while i < s.len:
    if s[i] notin allowed:
      return none(T) # invalid
    let c = T(hexValue(s[i]))
    if unlikely(T.high div radix - c < integer):
      return none(T) # overflow
    integer *= radix
    integer += c
    inc i
  return some(sign * integer)

func parseIntImpl[T: SomeSignedInt](s: string): Option[T] =
  return parseIntImpl[T](s, AsciiDigit, 10)

func parseInt32*(s: string): Option[int32] =
  return parseIntImpl[int32](s)

func parseInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s)

func parseOctInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s, AsciiOctDigit, 8)

func parseHexInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s, AsciiHexDigit, 16)

func parseUIntImpl[T: SomeUnsignedInt](s: string; allowSign: static bool;
    allowed: set[char]; radix: T): Option[T] =
  var i = 0
  when allowSign:
    if i < s.len and s[i] == '+':
      inc i
  if i == s.len:
    return none(T)
  var integer: T = 0
  while i < s.len:
    if s[i] notin allowed:
      return none(T) # invalid
    let c = T(hexValue(s[i]))
    if unlikely(T.high div radix - c < integer):
      return none(T) # overflow
    integer *= radix
    integer += c
    inc i
  return some(integer)

func parseUIntImpl[T: SomeUnsignedInt](s: string; allowSign: static bool):
    Option[T] =
  return parseUIntImpl[T](s, allowSign, AsciiDigit, 10)

func parseUInt8*(s: string; allowSign: static bool): Option[uint8] =
  return parseUIntImpl[uint8](s, allowSign)

func parseUInt16*(s: string; allowSign: static bool): Option[uint16] =
  return parseUIntImpl[uint16](s, allowSign)

func parseUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign)

func parseOctUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign, AsciiOctDigit, 8)

func parseHexUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign, AsciiHexDigit, 16)

#TODO not sure where this algorithm is from...
# (probably from CSS)
func parseFloat64*(s: string): float64 =
  var sign = 1f64
  var t = 1
  var d = 0
  var integer: float64 = 0
  var f: float64 = 0
  var e: float64 = 0
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1f64
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  while i < s.len and s[i] in AsciiDigit:
    integer *= 10
    integer += float64(decValue(s[i]))
    inc i
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in AsciiDigit:
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
    while i < s.len and s[i] in AsciiDigit:
      e *= 10
      e += float64(decValue(s[i]))
      inc i
  return sign * (integer + f * pow(10, float64(-d))) * pow(10, (float64(t) * e))

const ControlPercentEncodeSet* = Controls + NonAscii
const FragmentPercentEncodeSet* = ControlPercentEncodeSet +
  {' ', '"', '<', '>', '`'}
const QueryPercentEncodeSet* = FragmentPercentEncodeSet - {'`'} + {'#'}
const SpecialQueryPercentEncodeSet* = QueryPercentEncodeSet + {'\''}
const PathPercentEncodeSet* = QueryPercentEncodeSet + {'?', '`', '{', '}'}
const UserInfoPercentEncodeSet* = PathPercentEncodeSet +
  {'/', ':', ';', '=', '@', '['..'^', '|'}
const ComponentPercentEncodeSet* = UserInfoPercentEncodeSet +
  {'$'..'&', '+', ','}
const ApplicationXWWWFormUrlEncodedSet* = ComponentPercentEncodeSet +
  {'!', '\''..')', '~'}
# used by pager
when DirSep == '\\':
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '\\', '/'}
else:
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '/'}

proc percentEncode*(append: var string; c: char; set: set[char];
    spaceAsPlus = false) {.inline.} =
  if spaceAsPlus and c == ' ':
    append &= '+'
  elif c notin set:
    append &= c
  else:
    append &= '%'
    append.pushHex(c)

proc percentEncode*(append: var string; s: string; set: set[char];
    spaceAsPlus = false) {.inline.} =
  for c in s:
    append.percentEncode(c, set, spaceAsPlus)

func percentEncode*(c: char; set: set[char]; spaceAsPlus = false): string
    {.inline.} =
  result.percentEncode(c, set, spaceAsPlus)

func percentEncode*(s: string; set: set[char]; spaceAsPlus = false): string =
  result.percentEncode(s, set, spaceAsPlus)

func percentDecode*(input: string; si = 0): string =
  var i = si
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

func htmlEscape*(s: string): string =
  result = ""
  for c in s:
    case c
    of '<': result &= "&lt;"
    of '>': result &= "&gt;"
    of '&': result &= "&amp;"
    of '"': result &= "&quot;"
    of '\'': result &= "&apos;"
    else: result &= c

func dqEscape*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c == '"':
      result &= '\\'
    result &= c

#basically std join but with char
func join*(ss: openArray[string]; sep: char): string =
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

proc passRealloc*(opaque, p: pointer; size: csize_t): pointer {.cdecl.} =
  return realloc(p, size)

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
  result = 0
  for r in s.runes:
    if uint32(r) < 0x10000: # ucs-2
      result += 1
    else: # surrogate
      result += 2

proc expandPath*(path: string): string =
  if path.len == 0 or path[0] != '~':
    return path
  if path.len == 1:
    return getHomeDir()
  elif path[1] == '/':
    return getHomeDir() / path.substr(2)
  else:
    when defined(posix):
      let usr = path.until({'/'}, 1)
      let p = getpwnam(cstring(usr))
      if p != nil:
        return $p.pw_dir / path.substr(usr.len)
    return path

func deleteChars*(s: string; todel: set[char]): string =
  var i = 0
  block earlyret:
    for j, c in s:
      if c in todel:
        i = j
        break earlyret
    return s
  var rs = newStringOfCap(s.len - 1)
  for j in 0 ..< i:
    rs &= s[j]
  for j in i + 1 ..< s.len:
    if s[j] in todel:
      continue
    rs &= s[j]
    inc i
  return rs

func replaceControls*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c in Controls - {' '}:
      result &= '^'
      result &= c.getControlLetter()
    else:
      result &= c

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

func strictParseEnum*[T: enum](s: string): Opt[T] =
  # cmp when len is small enough, otherwise hashmap
  when {T.low..T.high}.len <= 4:
    for e in T.low .. T.high:
      if $e == s:
        return ok(e)
  else:
    const tab = (func(): Table[string, T] =
      result = initTable[string, T]()
      for e in T.low .. T.high:
        result[$e] = e
    )()
    if s in tab:
      return ok(tab[s])
  return err()

func parseEnumNoCase*[T: enum](s: string): Opt[T] =
  # cmp when len is small enough, otherwise hashmap
  when {T.low..T.high}.len <= 4:
    for e in T.low .. T.high:
      if $e.equalsIgnoreCase(s):
        return ok(e)
  else:
    const tab = (func(): Table[string, T] =
      result = initTable[string, T]()
      for e in T.low .. T.high:
        result[$e] = e
    )()
    if s in tab:
      return ok(tab[s])
  return err()

proc getContentTypeAttr*(contentType, attrname: string): string =
  var i = contentType.find(';')
  if i == -1:
    return ""
  i = contentType.find(attrname, i)
  if i == -1:
    return ""
  i = contentType.skipBlanks(i + attrname.len)
  if i >= contentType.len or contentType[i] != '=':
    return ""
  i = contentType.skipBlanks(i + 1)
  var q = false
  var s = ""
  for c in contentType.toOpenArray(i, contentType.high):
    if q:
      s &= c
      q = false
    elif c == '\\':
      q = true
    elif c in AsciiWhitespace + {';'}:
      break
    else:
      s &= c
  return s
