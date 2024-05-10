import std/unicode

import utils/charcategory
import utils/luwrap
import utils/strwidth

type BreakCategory* = enum
  bcAlpha, bcSpace, bcSymbol, bcHan, bcHiragana, bcKatakana, bcHangul

func isDigitAscii(r: Rune): bool =
  return uint32(r) < 128 and char(r) in AsciiDigit

proc breaksWord*(ctx: LUContext; r: Rune): bool =
  return not r.isDigitAscii() and r.width() != 0 and not ctx.isAlphaLU(r)

proc breaksViWordCat*(ctx: LUContext; r: Rune): BreakCategory =
  if int32(r) < 0x80: # ASCII
    let c = char(r)
    if c in AsciiAlphaNumeric + {'_'}:
      return bcAlpha
    elif c in AsciiWhitespace:
      return bcSpace
  elif ctx.isWhiteSpaceLU(r):
    return bcSpace
  elif ctx.isAlphaLU(r):
    if ctx.isHiragana(r):
      return bcHiragana
    elif ctx.isKatakana(r):
      return bcKatakana
    elif ctx.isHangul(r):
      return bcHangul
    elif ctx.isHan(r):
      return bcHan
    return bcAlpha
  return bcSymbol

proc breaksWordCat*(ctx: LUContext; r: Rune): BreakCategory =
  if not ctx.breaksWord(r):
    return bcAlpha
  return bcSpace

proc breaksBigWordCat*(ctx: LUContext; r: Rune): BreakCategory =
  if not ctx.isWhiteSpaceLU(r):
    return bcAlpha
  return bcSpace
