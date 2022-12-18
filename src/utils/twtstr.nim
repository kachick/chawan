import algorithm
import terminal
import strutils
import unicode
import os
import math
import sugar
import sequtils
import options
import punycode

import data/idna

when defined(posix):
  import posix

func ansiStyle*(str: string, style: Style): string =
  result &= ansiStyleCode(style)
  result &= str

func ansiFgColor*(str: string, color: ForegroundColor): string =
  result &= ansiForegroundColorCode(color)
  result &= str

func ansiReset*(str: string): string =
  result &= str
  result &= ansiResetCode

const C0Controls* = {chr(0x00)..chr(0x1F)}
const Controls* = (C0Controls + {chr(0x7F)})
const Ascii* = {chr(0x00)..chr(0x7F)}
const AsciiUpperAlpha* = {'A'..'Z'}
const AsciiLowerAlpha* = {'a'..'z'}
const AsciiAlpha* = (AsciiUpperAlpha + AsciiLowerAlpha)
const NonAscii* = (AllChars - Ascii)
const AsciiDigit* = {'0'..'9'}
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

func toLowerAscii2*(str: string): string =
  var i = 0
  block noconv:
    while i < str.len:
      let c = str[i]
      if c in AsciiUpperAlpha:
        break noconv
      inc i
    return str
  result = newString(str.len)
  prepareMutation(result)
  copyMem(addr result[0], unsafeAddr str[0], i)
  while i < str.len:
    result[i] = str[i].tolower()

proc toLowerAsciiIp*(str: var string) =
  var i = 0
  block noconv:
    while i < str.len:
      let c = str[i]
      if c in AsciiUpperAlpha:
        break noconv
      inc i
    return
  while i < str.len:
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

func isAscii*(r: Rune): bool =
  return int32(r) < 128

const HexChars = "0123456789ABCDEF"
func toHex*(c: char): string =
  result = newString(2)
  result[0] = HexChars[(uint8(c) shr 4)]
  result[1] = HexChars[(uint8(c) and 0xF)]

func equalsIgnoreCase*(s1: seq[Rune], s2: string): bool =
  var i = 0
  while i < min(s1.len, s2.len):
    if not s1[i].isAscii() or cast[char](s1[i]).tolower() != s2[i]:
      return false
    inc i
  return true

func equalsIgnoreCase*(s1, s2: string): bool {.inline.} =
  return s1.cmpIgnoreCase(s2) == 0

func isAlphaAscii*(r: Rune): bool =
  return int(r) < 256 and isAlphaAscii(char(r))

func isDigitAscii*(r: Rune): bool =
  return int(r) < 256 and isDigit(char(r))

func substr*(s: seq[Rune], i, j: int): seq[Rune] =
  if s.len == 0:
    return @[]
  return s[min(high(s), i)..min(high(s), j - 1)]

func substr*(s: seq[Rune], i: int): seq[Rune] =
  if i > high(s) or s.len == 0:
    return @[]
  return s[min(high(s), i)..high(s)]

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

# From w3m
const SizeUnit = [
  "b", "kb", "Mb", "Gb", "Tb", "Pb", "Eb", "Zb", "Bb", "Yb"
]
func convert_size*(len: int): string =
  var sizepos = 0
  var csize = float(len)
  while csize >= 999.495 and sizepos < SizeUnit.len:
    csize = csize / 1024.0
    inc sizepos
  result = $(floor(csize * 100 + 0.5) / 100)
  result &= SizeUnit[sizepos]

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

const romanNumbers_lower = romanNumbers.map((x) => (x[0], x[1].tolower()))

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

func parseInt32*(s: string): int =
  var sign = 1
  var t = 1
  var integer: int = 0
  var e: int = 0

  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i

  while i < s.len and isDigit(s[i]):
    integer *= 10
    integer += decValue(s[i])
    inc i

  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and s[i] == '-':
      t = -1
      inc i
    elif i < s.len and s[i] == '+':
      inc i

    while i < s.len and isDigit(s[i]):
      e *= 10
      e += decValue(s[i])
      inc i

  return sign * integer * 10 ^ (t * e)

func parseInt64*(s: string): int64 =
  var sign = 1
  var t = 1
  var integer: int64 = 0
  var e: int64 = 0

  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i

  while i < s.len and isDigit(s[i]):
    integer *= 10
    integer += decValue(s[i])
    inc i

  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and s[i] == '-':
      t = -1
      inc i
    elif i < s.len and s[i] == '+':
      inc i

    while i < s.len and isDigit(s[i]):
      e *= 10
      e += decValue(s[i])
      inc i

  return sign * integer * 10 ^ (t * e)

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
    append &= c.toHex()

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

func clearControls*(s: string): string =
  for c in s:
    if c notin Controls:
      result &= c

func processIdna(str: string, checkhyphens, checkbidi, checkjoiners, transitionalprocessing: bool): Option[string] =
  var mapped = ""
  var i = 0
  while i < str.len:
    var r: Rune
    fastRuneAt(str, i, r)
    let status = getIdnaTableStatus(r)
    case status
    of IDNA_DISALLOWED: return none(string) #error
    of IDNA_IGNORED: discard
    of IDNA_MAPPED: mapped &= getIdnaMapped(r)
    of IDNA_DEVIATION:
      if transitionalprocessing: mapped &= getDeviationMapped(r)
      else: mapped &= r
    of IDNA_VALID: mapped &= r
  
  #TODO normalize
  var labels: seq[string]
  for label in str.split('.'):
    var s = label
    if label.startsWith("xn--"):
      try:
        s = punycode.decode(label.substr("xn--".len))
      except PunyError:
        return none(string) #error
    #TODO check normalization
    if checkhyphens:
      if s.len >= 4 and s[2] == '-' and s[3] == '-':
        return none(string) #error
      if s.len > 0 and s[0] == '-' and s[^1] == '-':
        return none(string) #error
    var i = 0
    while i < s.len:
      if s[i] == '.':
        return none(string) #error
      var r: Rune
      fastRuneAt(str, i, r)
      #TODO check general category mark
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
  return labels.join('.').some

func unicodeToAscii*(s: string, checkhyphens, checkbidi, checkjoiners, transitionalprocessing, verifydnslength: bool): Option[string] =
  let processed = s.processIdna(checkhyphens, checkbidi, checkjoiners,
                                transitionalprocessing)
  if processed.isnone:
    return none(string) #error
  var labels: seq[string]
  for label in processed.get.split('.'):
    var needsconversion = false
    for c in label:
      if c notin Ascii:
        needsconversion = true
        break
    if needsconversion:
      try:
        let converted = "xn--" & punycode.encode(label)
        #TODO verify dns length
        labels.add(converted)
      except PunyError:
        return none(string) #error
    else:
      labels.add(label)
  return labels.join('.').some

#TODO this is stupid
func isValidNonZeroInt*(str: string): bool =
  if str.len == 0: return false
  if str == "0": return false
  for c in str:
    if not c.isDigit():
      return false
  try:
    discard parseInt(str)
  except ValueError:
    return false
  true

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

iterator split*(s: seq[Rune], sep: Rune): seq[Rune] =
  var i = 0
  var prev = 0
  while i < s.len:
    if s[i] == sep:
      yield s.substr(prev, i)
      prev = i
    inc i

  if prev < i:
    yield s.substr(prev, i)

# Measure length of runes. From https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c
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
const combining = [
  ( 0x0300, 0x036F ), ( 0x0483, 0x0486 ), ( 0x0488, 0x0489 ),
  ( 0x0591, 0x05BD ), ( 0x05BF, 0x05BF ), ( 0x05C1, 0x05C2 ),
  ( 0x05C4, 0x05C5 ), ( 0x05C7, 0x05C7 ), ( 0x0600, 0x0603 ),
  ( 0x0610, 0x0615 ), ( 0x064B, 0x065E ), ( 0x0670, 0x0670 ),
  ( 0x06D6, 0x06E4 ), ( 0x06E7, 0x06E8 ), ( 0x06EA, 0x06ED ),
  ( 0x070F, 0x070F ), ( 0x0711, 0x0711 ), ( 0x0730, 0x074A ),
  ( 0x07A6, 0x07B0 ), ( 0x07EB, 0x07F3 ), ( 0x0901, 0x0902 ),
  ( 0x093C, 0x093C ), ( 0x0941, 0x0948 ), ( 0x094D, 0x094D ),
  ( 0x0951, 0x0954 ), ( 0x0962, 0x0963 ), ( 0x0981, 0x0981 ),
  ( 0x09BC, 0x09BC ), ( 0x09C1, 0x09C4 ), ( 0x09CD, 0x09CD ),
  ( 0x09E2, 0x09E3 ), ( 0x0A01, 0x0A02 ), ( 0x0A3C, 0x0A3C ),
  ( 0x0A41, 0x0A42 ), ( 0x0A47, 0x0A48 ), ( 0x0A4B, 0x0A4D ),
  ( 0x0A70, 0x0A71 ), ( 0x0A81, 0x0A82 ), ( 0x0ABC, 0x0ABC ),
  ( 0x0AC1, 0x0AC5 ), ( 0x0AC7, 0x0AC8 ), ( 0x0ACD, 0x0ACD ),
  ( 0x0AE2, 0x0AE3 ), ( 0x0B01, 0x0B01 ), ( 0x0B3C, 0x0B3C ),
  ( 0x0B3F, 0x0B3F ), ( 0x0B41, 0x0B43 ), ( 0x0B4D, 0x0B4D ),
  ( 0x0B56, 0x0B56 ), ( 0x0B82, 0x0B82 ), ( 0x0BC0, 0x0BC0 ),
  ( 0x0BCD, 0x0BCD ), ( 0x0C3E, 0x0C40 ), ( 0x0C46, 0x0C48 ),
  ( 0x0C4A, 0x0C4D ), ( 0x0C55, 0x0C56 ), ( 0x0CBC, 0x0CBC ),
  ( 0x0CBF, 0x0CBF ), ( 0x0CC6, 0x0CC6 ), ( 0x0CCC, 0x0CCD ),
  ( 0x0CE2, 0x0CE3 ), ( 0x0D41, 0x0D43 ), ( 0x0D4D, 0x0D4D ),
  ( 0x0DCA, 0x0DCA ), ( 0x0DD2, 0x0DD4 ), ( 0x0DD6, 0x0DD6 ),
  ( 0x0E31, 0x0E31 ), ( 0x0E34, 0x0E3A ), ( 0x0E47, 0x0E4E ),
  ( 0x0EB1, 0x0EB1 ), ( 0x0EB4, 0x0EB9 ), ( 0x0EBB, 0x0EBC ),
  ( 0x0EC8, 0x0ECD ), ( 0x0F18, 0x0F19 ), ( 0x0F35, 0x0F35 ),
  ( 0x0F37, 0x0F37 ), ( 0x0F39, 0x0F39 ), ( 0x0F71, 0x0F7E ),
  ( 0x0F80, 0x0F84 ), ( 0x0F86, 0x0F87 ), ( 0x0F90, 0x0F97 ),
  ( 0x0F99, 0x0FBC ), ( 0x0FC6, 0x0FC6 ), ( 0x102D, 0x1030 ),
  ( 0x1032, 0x1032 ), ( 0x1036, 0x1037 ), ( 0x1039, 0x1039 ),
  ( 0x1058, 0x1059 ), ( 0x1160, 0x11FF ), ( 0x135F, 0x135F ),
  ( 0x1712, 0x1714 ), ( 0x1732, 0x1734 ), ( 0x1752, 0x1753 ),
  ( 0x1772, 0x1773 ), ( 0x17B4, 0x17B5 ), ( 0x17B7, 0x17BD ),
  ( 0x17C6, 0x17C6 ), ( 0x17C9, 0x17D3 ), ( 0x17DD, 0x17DD ),
  ( 0x180B, 0x180D ), ( 0x18A9, 0x18A9 ), ( 0x1920, 0x1922 ),
  ( 0x1927, 0x1928 ), ( 0x1932, 0x1932 ), ( 0x1939, 0x193B ),
  ( 0x1A17, 0x1A18 ), ( 0x1B00, 0x1B03 ), ( 0x1B34, 0x1B34 ),
  ( 0x1B36, 0x1B3A ), ( 0x1B3C, 0x1B3C ), ( 0x1B42, 0x1B42 ),
  ( 0x1B6B, 0x1B73 ), ( 0x1DC0, 0x1DCA ), ( 0x1DFE, 0x1DFF ),
  ( 0x200B, 0x200F ), ( 0x202A, 0x202E ), ( 0x2060, 0x2063 ),
  ( 0x206A, 0x206F ), ( 0x20D0, 0x20EF ), ( 0x302A, 0x302F ),
  ( 0x3099, 0x309A ), ( 0xA806, 0xA806 ), ( 0xA80B, 0xA80B ),
  ( 0xA825, 0xA826 ), ( 0xFB1E, 0xFB1E ), ( 0xFE00, 0xFE0F ),
  ( 0xFE20, 0xFE23 ), ( 0xFEFF, 0xFEFF ), ( 0xFFF9, 0xFFFB ),
  ( 0x10A01, 0x10A03 ), ( 0x10A05, 0x10A06 ), ( 0x10A0C, 0x10A0F ),
  ( 0x10A38, 0x10A3A ), ( 0x10A3F, 0x10A3F ), ( 0x1D167, 0x1D169 ),
  ( 0x1D173, 0x1D182 ), ( 0x1D185, 0x1D18B ), ( 0x1D1AA, 0x1D1AD ),
  ( 0x1D242, 0x1D244 ), ( 0xE0001, 0xE0001 ), ( 0xE0020, 0xE007F ),
  ( 0xE0100, 0xE01EF )
]

func is_dwidth(r: Rune): bool =
  let ucs = int(r)
  return (ucs >= 0x1100 and
     (ucs <= 0x115f or                    # Hangul Jamo init. consonants
      ucs == 0x2329 or ucs == 0x232a or
      (ucs >= 0x2e80 and ucs <= 0xa4cf and
       ucs != 0x303f) or                  # CJK ... Yi
      (ucs >= 0xac00 and ucs <= 0xd7a3) or # Hangul Syllables
      (ucs >= 0xf900 and ucs <= 0xfaff) or # CJK Compatibility Ideographs
      (ucs >= 0xfe10 and ucs <= 0xfe19) or # Vertical forms
      (ucs >= 0xfe30 and ucs <= 0xfe6f) or # CJK Compatibility Forms
      (ucs >= 0xff00 and ucs <= 0xff60) or # Fullwidth Forms
      (ucs >= 0xffe0 and ucs <= 0xffe6) or
      (ucs >= 0x20000 and ucs <= 0x2fffd) or
      (ucs >= 0x30000 and ucs <= 0x3fffd)))

# sorted list of non-overlapping intervals of East Asian Ambiguous characters,
# generated by "uniset +WIDTH-A -cat=Me -cat=Mn -cat=Cf c"

const ambiguous = [
  ( 0x00A1, 0x00A1 ), ( 0x00A4, 0x00A4 ), ( 0x00A7, 0x00A8 ),
  ( 0x00AA, 0x00AA ), ( 0x00AE, 0x00AE ), ( 0x00B0, 0x00B4 ),
  ( 0x00B6, 0x00BA ), ( 0x00BC, 0x00BF ), ( 0x00C6, 0x00C6 ),
  ( 0x00D0, 0x00D0 ), ( 0x00D7, 0x00D8 ), ( 0x00DE, 0x00E1 ),
  ( 0x00E6, 0x00E6 ), ( 0x00E8, 0x00EA ), ( 0x00EC, 0x00ED ),
  ( 0x00F0, 0x00F0 ), ( 0x00F2, 0x00F3 ), ( 0x00F7, 0x00FA ),
  ( 0x00FC, 0x00FC ), ( 0x00FE, 0x00FE ), ( 0x0101, 0x0101 ),
  ( 0x0111, 0x0111 ), ( 0x0113, 0x0113 ), ( 0x011B, 0x011B ),
  ( 0x0126, 0x0127 ), ( 0x012B, 0x012B ), ( 0x0131, 0x0133 ),
  ( 0x0138, 0x0138 ), ( 0x013F, 0x0142 ), ( 0x0144, 0x0144 ),
  ( 0x0148, 0x014B ), ( 0x014D, 0x014D ), ( 0x0152, 0x0153 ),
  ( 0x0166, 0x0167 ), ( 0x016B, 0x016B ), ( 0x01CE, 0x01CE ),
  ( 0x01D0, 0x01D0 ), ( 0x01D2, 0x01D2 ), ( 0x01D4, 0x01D4 ),
  ( 0x01D6, 0x01D6 ), ( 0x01D8, 0x01D8 ), ( 0x01DA, 0x01DA ),
  ( 0x01DC, 0x01DC ), ( 0x0251, 0x0251 ), ( 0x0261, 0x0261 ),
  ( 0x02C4, 0x02C4 ), ( 0x02C7, 0x02C7 ), ( 0x02C9, 0x02CB ),
  ( 0x02CD, 0x02CD ), ( 0x02D0, 0x02D0 ), ( 0x02D8, 0x02DB ),
  ( 0x02DD, 0x02DD ), ( 0x02DF, 0x02DF ), ( 0x0391, 0x03A1 ),
  ( 0x03A3, 0x03A9 ), ( 0x03B1, 0x03C1 ), ( 0x03C3, 0x03C9 ),
  ( 0x0401, 0x0401 ), ( 0x0410, 0x044F ), ( 0x0451, 0x0451 ),
  ( 0x2010, 0x2010 ), ( 0x2013, 0x2016 ), ( 0x2018, 0x2019 ),
  ( 0x201C, 0x201D ), ( 0x2020, 0x2022 ), ( 0x2024, 0x2027 ),
  ( 0x2030, 0x2030 ), ( 0x2032, 0x2033 ), ( 0x2035, 0x2035 ),
  ( 0x203B, 0x203B ), ( 0x203E, 0x203E ), ( 0x2074, 0x2074 ),
  ( 0x207F, 0x207F ), ( 0x2081, 0x2084 ), ( 0x20AC, 0x20AC ),
  ( 0x2103, 0x2103 ), ( 0x2105, 0x2105 ), ( 0x2109, 0x2109 ),
  ( 0x2113, 0x2113 ), ( 0x2116, 0x2116 ), ( 0x2121, 0x2122 ),
  ( 0x2126, 0x2126 ), ( 0x212B, 0x212B ), ( 0x2153, 0x2154 ),
  ( 0x215B, 0x215E ), ( 0x2160, 0x216B ), ( 0x2170, 0x2179 ),
  ( 0x2190, 0x2199 ), ( 0x21B8, 0x21B9 ), ( 0x21D2, 0x21D2 ),
  ( 0x21D4, 0x21D4 ), ( 0x21E7, 0x21E7 ), ( 0x2200, 0x2200 ),
  ( 0x2202, 0x2203 ), ( 0x2207, 0x2208 ), ( 0x220B, 0x220B ),
  ( 0x220F, 0x220F ), ( 0x2211, 0x2211 ), ( 0x2215, 0x2215 ),
  ( 0x221A, 0x221A ), ( 0x221D, 0x2220 ), ( 0x2223, 0x2223 ),
  ( 0x2225, 0x2225 ), ( 0x2227, 0x222C ), ( 0x222E, 0x222E ),
  ( 0x2234, 0x2237 ), ( 0x223C, 0x223D ), ( 0x2248, 0x2248 ),
  ( 0x224C, 0x224C ), ( 0x2252, 0x2252 ), ( 0x2260, 0x2261 ),
  ( 0x2264, 0x2267 ), ( 0x226A, 0x226B ), ( 0x226E, 0x226F ),
  ( 0x2282, 0x2283 ), ( 0x2286, 0x2287 ), ( 0x2295, 0x2295 ),
  ( 0x2299, 0x2299 ), ( 0x22A5, 0x22A5 ), ( 0x22BF, 0x22BF ),
  ( 0x2312, 0x2312 ), ( 0x2460, 0x24E9 ), ( 0x24EB, 0x254B ),
  ( 0x2550, 0x2573 ), ( 0x2580, 0x258F ), ( 0x2592, 0x2595 ),
  ( 0x25A0, 0x25A1 ), ( 0x25A3, 0x25A9 ), ( 0x25B2, 0x25B3 ),
  ( 0x25B6, 0x25B7 ), ( 0x25BC, 0x25BD ), ( 0x25C0, 0x25C1 ),
  ( 0x25C6, 0x25C8 ), ( 0x25CB, 0x25CB ), ( 0x25CE, 0x25D1 ),
  ( 0x25E2, 0x25E5 ), ( 0x25EF, 0x25EF ), ( 0x2605, 0x2606 ),
  ( 0x2609, 0x2609 ), ( 0x260E, 0x260F ), ( 0x2614, 0x2615 ),
  ( 0x261C, 0x261C ), ( 0x261E, 0x261E ), ( 0x2640, 0x2640 ),
  ( 0x2642, 0x2642 ), ( 0x2660, 0x2661 ), ( 0x2663, 0x2665 ),
  ( 0x2667, 0x266A ), ( 0x266C, 0x266D ), ( 0x266F, 0x266F ),
  ( 0x273D, 0x273D ), ( 0x2776, 0x277F ), ( 0xE000, 0xF8FF ),
  ( 0xFFFD, 0xFFFD ), ( 0xF0000, 0xFFFFD ), ( 0x100000, 0x10FFFD )
]

# 
# The following functions are the same as mk_wcwidth() and mk_wcswidth(),
# except that spacing characters in the East Asian Ambiguous (A) category as
# defined in Unicode Technical Report #11 have a column width of 2. This
# variant might be useful for users of CJK legacy encodings who want to migrate
# to UCS without changing the traditional terminal character-width behaviour.
# It is not otherwise recommended for general use.

func is_dwidth_cjk(r: Rune): bool =
  # binary search in table of non-spacing characters
  if binarySearch(ambiguous, int32(r), (x, y) => (if x[0] < y: -1 elif x[1] > y: 1 else: 0)) != -1:
    return true

  return r.is_dwidth()

# compute lookup table on startup
var width_table*: array[0..0x10FFFF, byte]

func makewidthtable*(cjk: bool): array[0..0x10FFFF, byte] {.noInit.} =
  for r in low(char)..high(char):
    if r in Controls:
      result[int(r)] = 0
    else:
      result[int(r)] = 1

  var i = 0
  var next_combining = combining[i]
  if cjk:
    for ucs in 256..0x10FFFF:
      if ucs >= next_combining[0]:
        if ucs <= next_combining[1]:
          result[ucs] = 0
          continue
        elif i + 1 < combining.len:
          inc i
          next_combining = combining[i]

      if Rune(ucs).is_dwidth_cjk():
        result[ucs] = 2
      else:
        result[ucs] = 1
  else:
    for ucs in 256..0x10FFFF:
      if ucs >= next_combining[0]:
        if ucs <= next_combining[1]:
          result[ucs] = 0
          continue
        elif i + 1 < combining.len:
          inc i
          next_combining = combining[i]

      if Rune(ucs).is_dwidth():
        result[ucs] = 2
      else:
        result[ucs] = 1

{.push boundChecks:off.}
func width*(r: Rune): int =
  {.cast(noSideEffect).}:
    return int(width_table[int(r)])
{.pop.}

func width*(s: string): int =
  for r in s.runes():
    result += width(r)

func width*(s: string, len: int): int =
  var i = 0
  var m = len
  if m > s.len: m = s.len
  while i < m:
    var r: Rune
    fastRuneAt(s, i, r)
    result += width(r)

func width*(s: seq[Rune]): int =
  for r in s:
    result += width(r)

func width*(s: seq[Rune], min, max: int): int =
  var i = min
  var mi = min(max, s.len)
  while i < mi:
    result += width(s[i])
    inc i

func width*(s: seq[Rune], min: int): int =
  var i = min
  while i < s.len:
    result += width(s[i])
    inc i

func breaksWord*(r: Rune): bool =
  return not (r.isDigitAscii() or r.width() == 0 or r.isAlpha())

type BoundaryFunction* = proc(x: Rune): Option[bool]

proc breaksWord*(r: Rune, check: Option[BoundaryFunction]): bool =
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
