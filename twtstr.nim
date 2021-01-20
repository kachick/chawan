import terminal
import strutils

func addAnsiStyle*(str: string, style: Style): string =
  return ansiStyleCode(style) & str & "\e[0m"

func addAnsiFgColor*(str: string, color: ForegroundColor): string =
  return ansiForegroundColorCode(color) & str & ansiResetCode

func maxString*(str: string, max: int): string =
  if max < str.len:
    return str.substr(0, max - 2) & "$"
  return str

func fitValueToSize*(str: string, size: int): string =
  if str.len < size:
    return str & ' '.repeat(size - str.len)
  return str.maxString(size)

func buttonStr*(str: string): string =
  return "[".addAnsiFgColor(fgRed) & str.addAnsiFgColor(fgRed) & "]".addAnsiFgColor(fgRed)
