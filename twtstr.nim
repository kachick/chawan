import terminal
import strutils

func stripNewline*(str: string): string =
  if str.len == 0:
    result = str
    return

  case str[^1]
  of '\n':
    result = str.substr(0, str.len - 2)
  else: discard

func addAnsiStyle*(str: string, style: Style): string =
  return ansiStyleCode(style) & str & "\e[0m"

func addAnsiFgColor*(str: string, color: ForegroundColor): string =
  return ansiForegroundColorCode(color) & str & "\e[0m"

func maxString*(str: string, max: int): string =
  if max < str.len:
    return str.substr(0, max - 2) & "$"
  return str

func fitValueToSize*(str: string, size: int): string =
  if str.len < size:
    return str & ' '.repeat(size - str.len)
  return str.maxString(size)
