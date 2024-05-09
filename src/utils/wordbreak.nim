import std/unicode

import utils/charcategory
import utils/luwrap
import utils/strwidth

func isDigitAscii(r: Rune): bool =
  return uint32(r) < 128 and char(r) in AsciiDigit

type BreakCategory* = enum
  bcAlpha, bcSpace, bcSymbol, bcHan

func breaksWord*(r: Rune): bool =
  return not r.isDigitAscii() and r.width() != 0 and not r.isAlphaLU()

func breaksViWordCat*(r: Rune): BreakCategory =
  if r.isWhiteSpaceLU():
    return bcSpace
  elif r.breaksWord() and r != Rune'_':
    return bcSymbol
  elif r.isScriptLU("Han"):
    return bcHan
  return bcAlpha

func breaksWordCat*(r: Rune): BreakCategory =
  if not r.breaksWord():
    return bcAlpha
  return bcSpace

func breaksBigWordCat*(r: Rune): BreakCategory =
  if not r.isWhiteSpaceLU():
    return bcAlpha
  return bcSpace
