import terminal
import strutils
import unicode

func ansiStyle*(str: string, style: Style): seq[string] =
  result &= ansiStyleCode(style)
  result &= str

func ansiFgColor*(str: string, color: ForegroundColor): seq[string] =
  result &= ansiForegroundColorCode(color)
  result &= str

func ansiReset*(str: string): seq[string] =
  result &= str
  result &= ansiResetCode

func ansiStyle*(str: seq[string], style: Style): seq[string] =
  return ansiStyleCode(style) & str

func ansiFgColor*(str: seq[string], color: ForegroundColor): seq[string] =
  return ansiForegroundColorCode(color) & str

func ansiReset*(str: seq[string]): seq[string] =
  return str & ansiResetCode

func maxString*(str: string, max: int): string =
  if max < str.len:
    return str.substr(0, max - 2) & "$"
  return str

func fitValueToSize*(str: string, size: int): string =
  if str.runeLen < size:
    return str & ' '.repeat(size - str.runeLen)
  return str.maxString(size)

func buttonFmt*(str: string): seq[string] =
  return "[".ansiFgColor(fgRed) & str.ansiFgColor(fgRed).ansiReset() & "]".ansiFgColor(fgRed).ansiReset()

func buttonFmt*(str: seq[string]): seq[string] =
  return "[".ansiFgColor(fgRed) & str.ansiFgColor(fgRed).ansiReset() & "]".ansiFgColor(fgRed).ansiReset()

func buttonRaw*(str: string): string =
  return "[" & str & "]"

func remove*(str: string, c: string): string =
  let rem = c.toRunes()[0]
  for rune in str.runes:
    if rem != rune:
      result &= $rune

func isControlChar*(c: char): bool =
  return int(c) <= 0x1F or int(c) == 0x7F

func getControlChar*(c: char): char =
  if int(c) >= int('a'):
    return char(int(c) - int('a') + 1)
  elif c == '?':
    return char(127)
  assert(false)

func getControlLetter*(c: char): char =
  if int(c) <= 0x1F:
    return char(int(c) + int('A') - 1)
  elif c == '\x7F':
    return '?'
  assert(false)

func findChar*(str: string, c: char, start: int = 0): int =
  var i = start
  while i < str.len:
    if str[i] == c:
      return i
    inc i
  return -1

func findChar*(str: string, c: Rune, start: int = 0): int =
  var i = start
  var n = i
  while i < str.runeLen():
    var r: Rune
    fastRuneAt(str, n, r)
    if r == c:
      return i
    i = n
  return -1


#Measure length of rune. Transpiled from https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c

#auxiliary function for binary search in interval table
#TODO: use binary search from stdlib?
func bisearch(ucs: Rune, table: openarray[(int, int)]): bool =
  var max = table.high
  var min = 0
  var mid: int

  if int(ucs) < table[0][0] or int(ucs) > table[max][1]:
    return false

  while max >= min:
    mid = (min + max) div 2
    if int(ucs) > table[mid][1]:
      min = mid + 1
    elif int(ucs) < table[mid][0]:
      max = mid - 1
    else:
      return true
  return false


#The following two functions define the column width of an ISO 10646
#character as follows:
#
#   - The null character (U+0000) has a column width of 0.
#
#   - Other C0/C1 control characters and DEL will lead to a return
#     value of -1.
#
#   - Non-spacing and enclosing combining characters (general
#     category code Mn or Me in the Unicode database) have a
#     column width of 0.
#
#   - SOFT HYPHEN (U+00AD) has a column width of 1.
#
#   - Other format characters (general category code Cf in the Unicode
#     database) and ZERO WIDTH SPACE (U+200B) have a column width of 0.
#
#   - Hangul Jamo medial vowels and final consonants (U+1160-U+11FF)
#     have a column width of 0.
#
#   - Spacing characters in the East Asian Wide (W) or East Asian
#     Full-width (F) category as defined in Unicode Technical
#     Report #11 have a column width of 2.
#
#   - All remaining characters (including all printable
#     ISO 8859-1 and WGL4 characters, Unicode control characters,
#     etc.) have a column width of 1.
#
#This implementation assumes that wchar_t characters are encoded
#in ISO 10646.
#

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

func mk_wcwidth(r: Rune): int =
  let ucs = int(r)
  # sorted list of non-overlapping intervals of non-spacing characters
  # generated by "uniset +cat=Me +cat=Mn +cat=Cf -00AD +1160-11FF +200B c"

  # test for 8-bit control characters
  if ucs == 0:
    return 0
  if ucs < 32 or (ucs >= 0x7f and ucs < 0xa0):
    return -1

  # binary search in table of non-spacing characters
  if bisearch(r, combining):
    return 0

  # if we arrive here, ucs is not a combining or C0/C1 control character

  if (ucs >= 0x1100 and
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
      (ucs >= 0x30000 and ucs <= 0x3fffd))):
    return 2
  return 1


func mk_wcswidth(s: string): int =
  for r in s.runes:
    result += mk_wcwidth(r)


# 
# The following functions are the same as mk_wcwidth() and
# mk_wcswidth(), except that spacing characters in the East Asian
# Ambiguous (A) category as defined in Unicode Technical Report #11
# have a column width of 2. This variant might be useful for users of
# CJK legacy encodings who want to migrate to UCS without changing
# the traditional terminal character-width behaviour. It is not
# otherwise recommended for general use.
# 
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

func mk_wcwidth_cjk*(ucs: Rune): int =
  # sorted list of non-overlapping intervals of East Asian Ambiguous
  # characters, generated by "uniset +WIDTH-A -cat=Me -cat=Mn -cat=Cf c"

  # binary search in table of non-spacing characters
  if bisearch(ucs, ambiguous):
    return 2;

  return mk_wcwidth(ucs);


func mk_wcswidth_cjk*(s: string): int =
  #result = 0
  #for r in s.runes:
  #  result += mk_wcwidth_cjk(r)
  #return result
  result = 0
  var i = 0
  while i < len(s):
    var r: Rune
    fastRuneAt(s, i, r, false)
    if uint(s[i]) <= 127: inc(i)
    elif uint(s[i]) shr 5 == 0b110: inc(i, 2)
    elif uint(s[i]) shr 4 == 0b1110: inc(i, 3)
    elif uint(s[i]) shr 3 == 0b11110: inc(i, 4)
    elif uint(s[i]) shr 2 == 0b111110: inc(i, 5)
    elif uint(s[i]) shr 1 == 0b1111110: inc(i, 6)
    else: inc i
    inc(result, mk_wcwidth_cjk(r))
