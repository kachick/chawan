import std/unicode

const C0Controls* = {chr(0x00)..chr(0x1F)}
const Controls* = (C0Controls + {chr(0x7F)})
const Ascii* = {chr(0x00)..chr(0x7F)}
const AsciiUpperAlpha* = {'A'..'Z'}
const AsciiLowerAlpha* = {'a'..'z'}
const AsciiAlpha* = (AsciiUpperAlpha + AsciiLowerAlpha)
const NonAscii* = {char(0x80)..char(0xFF)}
const AsciiDigit* = {'0'..'9'}
const AsciiAlphaNumeric* = AsciiAlpha + AsciiDigit
const AsciiHexDigit* = (AsciiDigit + {'a'..'f', 'A'..'F'})
const AsciiWhitespace* = {' ', '\n', '\r', '\t', '\f'}

func isDigitAscii*(r: Rune): bool =
  return uint32(r) < 256 and char(r) in AsciiDigit
