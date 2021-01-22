import terminal
import strutils
import unicode

const runeSpace* = " ".runeAt(0)

func ansiStyle*(str: string, style: Style): string =
  return ansiStyleCode(style) & str & "\e[0m"

func ansiFgColor*(str: string, color: ForegroundColor): string =
  return ansiForegroundColorCode(color) & str & ansiResetCode

func ansiReset*(str: string): string =
  return str & ansiResetCode

func maxString*(str: string, max: int): string =
  if max < str.len:
    return str.substr(0, max - 2) & "$"
  return str

func fitValueToSize*(str: string, size: int): string =
  if str.runeLen < size:
    return str & ' '.repeat(size - str.runeLen)
  return str.maxString(size)

func buttonFmt*(str: string): string =
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
