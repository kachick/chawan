import terminal
import strutils
import unicode

type ustring* = seq[Rune]

const runeSpace*: Rune = " ".toRunes()[0]
const runeNewline*: Rune = "\n".toRunes()[0]
const runeReturn*: Rune = "\r".toRunes()[0]

func isWhitespace(r: Rune): bool =
  case r
  of runeSpace, runeNewline, runeReturn: return true
  else: return false

func ansiStyle*(str: string, style: Style): string =
  return ansiStyleCode(style) & str

func ansiFgColor*(str: string, color: ForegroundColor): string =
  return ansiForegroundColorCode(color) & str

func ansiReset*(str: string): string =
  return str & ansiResetCode

func ansiStyle*(str: ustring, style: Style): ustring =
  return ansiStyleCode(style).toRunes() & str

func ansiFgColor*(str: ustring, color: ForegroundColor): ustring =
  return ansiForegroundColorCode(color).toRunes & str

func ansiReset*(str: ustring): ustring =
  return str & ansiResetCode.toRunes()

func maxString*(str: ustring, max: int): ustring =
  result = str
  if max < str.len:
    result.setLen(max - 2)
    result &= "$".toRunes()

func maxString*(str: string, max: int): string =
  result = str
  if max < str.len:
    result.setLen(max - 1)
    result[max - 2] = '$'

func fitValueToSize*(str: ustring, size: int): ustring =
  if str.len < size:
    return str & ' '.repeat(size - str.len).toRunes()
  return str.maxString(size)

func buttonFmt*(str: ustring): ustring =
  return "[".toRunes().ansiFgColor(fgRed).ansiReset() & str.ansiFgColor(fgRed).ansiReset() & "]".ansiFgColor(fgRed).toRunes().ansiReset()

func buttonRaw*(str: ustring): ustring = 
  return "[".toRunes() & str & "]".toRunes()

func remove*(s: ustring, r: Rune): ustring =
  for c in s:
    if c != r:
      result.add(c)
