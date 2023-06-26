import math
import options
import sequtils
import strutils
import sugar
import tables

import utils/twtstr

type
  RGBColor* = distinct uint32

  RGBAColor* = distinct uint32

  ANSIColor* = distinct uint8

  EightBitColor* = distinct uint8

  CellColor* = object
    rgb*: bool
    n: uint32

converter toRGBColor*(i: RGBAColor): RGBColor =
  return RGBColor(uint32(i) and 0xFFFFFFu32)

converter toRGBAColor*(i: RGBColor): RGBAColor =
  return RGBAColor(uint32(i) or 0xFF000000u32)

func `==`*(a, b: RGBAColor): bool {.borrow.}

func `==`*(a, b: ANSIColor): bool {.borrow.}

func rgbcolor*(color: CellColor): RGBColor =
  cast[RGBColor](color.n)

func color*(color: CellColor): uint8 =
  cast[uint8](color.n)

func cellColor*(rgb: RGBColor): CellColor =
  return CellColor(rgb: true, n: uint32(rgb))

func cellColor*(c: ANSIColor): CellColor =
  return CellColor(rgb: false, n: uint32(c) mod 10)

#TODO maybe bright ANSI colors? (8..15)

func cellColor*(c: EightBitColor): CellColor =
  return CellColor(rgb: false, n: uint32(c))

const defaultColor* = CellColor(rgb: false, n: 0)

const
  ANSI_BLACK* = ANSIColor(0u8)
  ANSI_RED* = ANSIColor(1u8)
  ANSI_GREEN* = ANSIColor(2u8)
  ANSI_YELLOW* = ANSIColor(3u8)
  ANSI_BLUE* = ANSIColor(4u8)
  ANSI_MAGENTA* = ANSIColor(5u8)
  ANSI_CYAN* = ANSIColor(6u8)
  ANSI_WHITE* = ANSIColor(7u8)

const ColorsRGB* = {
  "aliceblue": 0xf0f8ff,
  "antiquewhite": 0xfaebd7,
  "aqua": 0x00ffff,
  "aquamarine": 0x7fffd4,
  "azure": 0xf0ffff,
  "beige": 0xf5f5dc,
  "bisque": 0xffe4c4,
  "black": 0x000000,
  "blanchedalmond": 0xffebcd,
  "blue": 0x0000ff,
  "blueviolet": 0x8a2be2,
  "brown": 0xa52a2a,
  "burlywood": 0xdeb887,
  "cadetblue": 0x5f9ea0,
  "chartreuse": 0x7fff00,
  "chocolate": 0xd2691e,
  "coral": 0xff7f50,
  "cornflowerblue": 0x6495ed,
  "cornsilk": 0xfff8dc,
  "crimson": 0xdc143c,
  "cyan": 0x00ffff,
  "darkblue": 0x00008b,
  "darkcyan": 0x008b8b,
  "darkgoldenrod": 0xb8860b,
  "darkgray": 0xa9a9a9,
  "darkgreen": 0x006400,
  "darkgrey": 0xa9a9a9,
  "darkkhaki": 0xbdb76b,
  "darkmagenta": 0x8b008b,
  "darkolivegreen": 0x556b2f,
  "darkorange": 0xff8c00,
  "darkorchid": 0x9932cc,
  "darkred": 0x8b0000,
  "darksalmon": 0xe9967a,
  "darkseagreen": 0x8fbc8f,
  "darkslateblue": 0x483d8b,
  "darkslategray": 0x2f4f4f,
  "darkslategrey": 0x2f4f4f,
  "darkturquoise": 0x00ced1,
  "darkviolet": 0x9400d3,
  "deeppink": 0xff1493,
  "deepskyblue": 0x00bfff,
  "dimgray": 0x696969,
  "dimgrey": 0x696969,
  "dodgerblue": 0x1e90ff,
  "firebrick": 0xb22222,
  "floralwhite": 0xfffaf0,
  "forestgreen": 0x228b22,
  "fuchsia": 0xff00ff,
  "gainsboro": 0xdcdcdc,
  "ghostwhite": 0xf8f8ff,
  "gold": 0xffd700,
  "goldenrod": 0xdaa520,
  "gray": 0x808080,
  "green": 0x008000,
  "greenyellow": 0xadff2f,
  "grey": 0x808080,
  "honeydew": 0xf0fff0,
  "hotpink": 0xff69b4,
  "indianred": 0xcd5c5c,
  "indigo": 0x4b0082,
  "ivory": 0xfffff0,
  "khaki": 0xf0e68c,
  "lavender": 0xe6e6fa,
  "lavenderblush": 0xfff0f5,
  "lawngreen": 0x7cfc00,
  "lemonchiffon": 0xfffacd,
  "lightblue": 0xadd8e6,
  "lightcoral": 0xf08080,
  "lightcyan": 0xe0ffff,
  "lightgoldenrodyellow": 0xfafad2,
  "lightgray": 0xd3d3d3,
  "lightgreen": 0x90ee90,
  "lightgrey": 0xd3d3d3,
  "lightpink": 0xffb6c1,
  "lightsalmon": 0xffa07a,
  "lightseagreen": 0x20b2aa,
  "lightskyblue": 0x87cefa,
  "lightslategray": 0x778899,
  "lightslategrey": 0x778899,
  "lightsteelblue": 0xb0c4de,
  "lightyellow": 0xffffe0,
  "lime": 0x00ff00,
  "limegreen": 0x32cd32,
  "linen": 0xfaf0e6,
  "magenta": 0xff00ff,
  "maroon": 0x800000,
  "mediumaquamarine": 0x66cdaa,
  "mediumblue": 0x0000cd,
  "mediumorchid": 0xba55d3,
  "mediumpurple": 0x9370db,
  "mediumseagreen": 0x3cb371,
  "mediumslateblue": 0x7b68ee,
  "mediumspringgreen": 0x00fa9a,
  "mediumturquoise": 0x48d1cc,
  "mediumvioletred": 0xc71585,
  "midnightblue": 0x191970,
  "mintcream": 0xf5fffa,
  "mistyrose": 0xffe4e1,
  "moccasin": 0xffe4b5,
  "navajowhite": 0xffdead,
  "navy": 0x000080,
  "oldlace": 0xfdf5e6,
  "olive": 0x808000,
  "olivedrab": 0x6b8e23,
  "orange": 0xffa500,
  "orangered": 0xff4500,
  "orchid": 0xda70d6,
  "palegoldenrod": 0xeee8aa,
  "palegreen": 0x98fb98,
  "paleturquoise": 0xafeeee,
  "palevioletred": 0xdb7093,
  "papayawhip": 0xffefd5,
  "peachpuff": 0xffdab9,
  "peru": 0xcd853f,
  "pink": 0xffc0cb,
  "plum": 0xdda0dd,
  "powderblue": 0xb0e0e6,
  "purple": 0x800080,
  "red": 0xff0000,
  "rosybrown": 0xbc8f8f,
  "royalblue": 0x4169e1,
  "saddlebrown": 0x8b4513,
  "salmon": 0xfa8072,
  "sandybrown": 0xf4a460,
  "seagreen": 0x2e8b57,
  "seashell": 0xfff5ee,
  "sienna": 0xa0522d,
  "silver": 0xc0c0c0,
  "skyblue": 0x87ceeb,
  "slateblue": 0x6a5acd,
  "slategray": 0x708090,
  "slategrey": 0x708090,
  "snow": 0xfffafa,
  "springgreen": 0x00ff7f,
  "steelblue": 0x4682b4,
  "tan": 0xd2b48c,
  "teal": 0x008080,
  "thistle": 0xd8bfd8,
  "tomato": 0xff6347,
  "turquoise": 0x40e0d0,
  "violet": 0xee82ee,
  "wheat": 0xf5deb3,
  "white": 0xffffff,
  "whitesmoke": 0xf5f5f5,
  "yellow": 0xffff00,
  "yellowgreen": 0x9acd32,
  "rebeccapurple": 0x663399,
}.map((a) => (a[0], RGBColor(a[1]))).toTable()

func r*(c: RGBAColor): uint8 =
  return cast[uint8]((uint32(c) shr 16) and 0xff)

func g*(c: RGBAColor): uint8 =
  return cast[uint8]((uint32(c) shr 8) and 0xff)

func b*(c: RGBAColor): uint8 =
  return cast[uint8](uint32(c) and 0xff)

func a*(c: RGBAColor): uint8 =
  return cast[uint8]((uint32(c) shr 24) and 0xff)

proc `r=`*(c: var RGBAColor, r: uint8) =
  c = RGBAColor(uint32(c) or (uint32(r) shl 16))

proc `g=`*(c: var RGBAColor, g: uint8) =
  c = RGBAColor(uint32(c) or (uint32(g) shl 8))

proc `b=`*(c: var RGBAColor, b: uint8) =
  c = RGBAColor(uint32(c) or uint32(b))

proc `a=`*(c: var RGBAColor, a: uint8) =
  c = RGBAColor(uint32(c) or (uint32(a) shl 24))

# https://html.spec.whatwg.org/#serialisation-of-a-color
func serialize*(color: RGBAColor): string =
  if color.a == 255:
    let r = toHex(cast[uint8](color.r))
    let g = toHex(cast[uint8](color.g))
    let b = toHex(cast[uint8](color.b))
    return "#" & r & g & b
  let a = float64(color.a) / 255
  return "rgba(" & $color.r & ", " & $color.g & ", " & $color.b & ", " & $a &
    ")"

func `$`*(rgbacolor: RGBAColor): string =
  return rgbacolor.serialize()

# https://arxiv.org/pdf/2202.02864.pdf
func fastmul(c, ca: uint32): uint32 =
  let u = c or 0xFF000000u32
  var rb = u and 0x00FF00FFu32
  rb *= ca
  rb += 0x00800080
  rb += (rb shr 8) and 0x00FF00FFu32
  rb = rb and 0xFF00FF00u32
  var ga = (u shr 8) and 0x00FF00FFu32
  ga *= ca
  ga += 0x00800080
  ga += (ga shr 8) and 0x00FF00FFu32
  ga = ga and 0xFF00FF00u32
  return ga or (rb shr 8)

# fastmul, but preserves alpha
func fastmul1(c, ca: uint32): uint32 =
  let u = c
  var rb = u and 0x00FF00FFu32
  rb *= ca
  rb += 0x00800080
  rb += (rb shr 8) and 0x00FF00FFu32
  rb = rb and 0xFF00FF00u32
  var ga = (u shr 8) and 0x00FF00FFu32
  ga *= ca
  ga += 0x00800080
  ga += (ga shr 8) and 0x00FF00FFu32
  ga = ga and 0xFF00FF00u32
  return ga or (rb shr 8)

func fastmul(c: RGBAColor, ca: uint32): uint32 =
  return fastmul(uint32(c), ca)

func fastmul1(c: RGBAColor, ca: uint32): uint32 =
  return fastmul1(uint32(c), ca)

func rgba*(r, g, b, a: uint8): RGBAColor

func premul(c: RGBAColor): RGBAColor =
  return RGBAColor(fastmul(c, uint32(c.a)))

const straightAlphaTable = (func(): auto =
  var table: array[256, array[256, uint8]]
  for a in 0 ..< 256:
    let multiplier = if a > 0: (255 / a.float32) else: 0
    for c in 0 ..< 256:
      table[a][c] = min(round((c.float32 * multiplier)), 255).uint8
  return table)()

proc straight*(c: RGBAColor): RGBAColor =
  let r = straightAlphaTable[c.a][c.r]
  let g = straightAlphaTable[c.a][c.g]
  let b = straightAlphaTable[c.a][c.b]
  return rgba(r, g, b, c.a)

func blend*(c0, c1: RGBAColor): RGBAColor =
  let pc0 = c0.premul()
  let pc1 = c1.premul()
  let k = 255 - pc1.a
  let mc = RGBAColor(fastmul1(pc0, uint32(k)))
  let rr = cast[uint8](uint16(pc1.r) + uint16(mc.r))
  let rg = cast[uint8](uint16(pc1.g) + uint16(mc.g))
  let rb = cast[uint8](uint16(pc1.b) + uint16(mc.b))
  let ra = cast[uint8](uint16(pc1.a) + uint16(mc.a))
  let pres = rgba(rr, rg, rb, ra)
  let res = straight(pres)
  return res

#func blend*(c0, c1: RGBAColor): RGBAColor =
#  const norm = 1f64 / 255f64
#  let c0a = float64(c0.a) * norm
#  let c1a = float64(c1.a) * norm
#  let a0 = c0a + c1a * (1 - c0a)

func rgb*(r, g, b: uint8): RGBColor =
  return RGBColor((uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b))

func r*(c: RGBColor): uint8 =
  return cast[uint8]((uint32(c) shr 16) and 0xff)

func g*(c: RGBColor): uint8 =
  return cast[uint8]((uint32(c) shr 8) and 0xff)

func b*(c: RGBColor): uint8 =
  return cast[uint8](uint32(c) and 0xff)

# see https://learn.microsoft.com/en-us/previous-versions/windows/embedded/ms893078(v=msdn.10)
func Y*(c: RGBColor): uint8 =
  let rmul = uint16(c.r) * 66u16
  let gmul = uint16(c.g) * 129u16
  let bmul = uint16(c.b) * 25u16
  return cast[uint8](((rmul + gmul + bmul + 128) shr 8) + 16)

func U*(c: RGBColor): uint8 =
  let rmul = uint16(c.r) * 38u16
  let gmul = uint16(c.g) * 74u16
  let bmul = uint16(c.b) * 112u16
  return cast[uint8](((128 + bmul - rmul - gmul) shr 8) + 128)

func V*(c: RGBColor): uint8 =
  let rmul = uint16(c.r) * 112u16
  let gmul = uint16(c.g) * 94u16
  let bmul = uint16(c.b) * 18u16
  return cast[uint8](((128 + rmul - gmul - bmul) shr 8) + 128)

func YUV*(Y, U, V: uint8): RGBColor =
  let C = int(Y) - 16
  let D = int(U) - 128
  let E = int(V) - 128
  let r = max(min((298 * C + 409 * E + 128) shr 8, 255), 0)
  let g = max(min((298 * C - 100 * D - 208 * E + 128) shr 8, 255), 0)
  let b = max(min((298 * C + 516 * D + 128) shr 8, 255), 0)
  return rgb(cast[uint8](r), cast[uint8](g), cast[uint8](b))

func rgba*(r, g, b, a: uint8): RGBAColor =
  return RGBAColor((uint32(a) shl 24) or (uint32(r) shl 16) or
    (uint32(g) shl 8) or uint32(b))

func rgba*(r, g, b, a: int): RGBAColor =
  return rgba(uint8(r), uint8(g), uint8(b), uint8(a))

func gray*(n: uint8): RGBColor =
  return rgb(n, n, n) #TODO use yuv instead?

# NOTE: this assumes n notin 0..15 (which would be ANSI 4-bit)
func eightBitToRGB*(param0: EightBitColor): RGBColor =
  doAssert uint8(param0) notin 0u8..15u8
  let u = uint8(param0)
  if u in 16u8..231u8:
    #16 + 36 * r + 6 * g + b
    let n = u - 16
    let r = cast[uint8](int(n div 36) * 255 div 5)
    let m = int(n mod 36)
    let g = cast[uint8](((m div 6) * 255) div 5)
    let b = cast[uint8](((m mod 6) * 255) div 5)
    return rgb(r, g, b)
  else: # 232..255
    let n = (u - 232) * 10 + 8
    return gray(n)

func rgbToEightBit*(rgb: RGBColor): EightBitColor =
  let r = int(rgb.r)
  let g = int(rgb.g)
  let b = int(rgb.b)
  # Idea from here: https://github.com/Qix-/color-convert/pull/75
  # This seems to work about as well as checking for
  # abs(U - 128) < 5 & abs(V - 128 < 5), but is definitely faster.
  if r shr 4 == g shr 4 and g shr 4 == b shr 4:
    if r < 8:
      return EightBitColor(16)
    if r > 248:
      return EightBitColor(231)
    return EightBitColor(cast[uint8](((r - 8 * 24) div 247) + 232))
  #16 + 36 * r + 6 * g + b
  return EightBitColor(cast[uint8](16 + 36 * (r * 5 div 255) +
    6 * (g * 5 div 255) + (b * 5 div 255)))

template `$`*(rgbcolor: RGBColor): string =
  "rgb(" & $rgbcolor.r & ", " & $rgbcolor.g & ", " & $rgbcolor.b & ")"

template `$`*(color: CellColor): string =
  if color.rgb:
    $color.rgbcolor
  else:
    "tcolor" & $color.n

func parseHexColor*(s: string): Option[RGBAColor] =
  for c in s:
    if hexValue(c) == -1: return none(RGBAColor)
  case s.len
  of 6:
    let c = (hexValue(s[0]) shl 20) or (hexValue(s[1]) shl 16) or
            (hexValue(s[2]) shl 12) or (hexValue(s[3]) shl 8) or
            (hexValue(s[4]) shl 4) or hexValue(s[5])
    return some(RGBAColor(c))
  of 8:
    let c = (hexValue(s[6]) shl 28) or (hexValue(s[7]) shl 24) or
            (hexValue(s[0]) shl 20) or (hexValue(s[1]) shl 16) or
            (hexValue(s[2]) shl 12) or (hexValue(s[3]) shl 8) or
            (hexValue(s[4]) shl 4) or hexValue(s[5])
    return some(RGBAColor(c))
  of 3:
    let c = (hexValue(s[0]) shl 20) or (hexValue(s[0]) shl 16) or
            (hexValue(s[1]) shl 12) or (hexValue(s[1]) shl 8) or
            (hexValue(s[2]) shl 4) or hexValue(s[2])
    return some(RGBAColor(c))
  of 4:
    let c = (hexValue(s[3]) shl 28) or (hexValue(s[3]) shl 24) or
            (hexValue(s[0]) shl 20) or (hexValue(s[0]) shl 16) or
            (hexValue(s[1]) shl 12) or (hexValue(s[1]) shl 8) or
            (hexValue(s[2]) shl 4) or hexValue(s[2])
    return some(RGBAColor(c))
  else: discard

func parseRGBAColor*(s: string): Option[RGBAColor] =
  if s in ColorsRGB:
    return some(RGBAColor(ColorsRGB[s]))
  if (s.len == 3 or s.len == 4 or s.len == 6 or s.len == 8) and s[0] == '#':
    return parseHexColor(s[1..^1])
  if s.len > 2 and s[0] == '0' and s[1] == 'x':
    return parseHexColor(s[2..^1])
  return parseHexColor(s)

func parseLegacyColor*(s: string): Option[RGBColor] =
  if s == "": return
  let s = s.strip(chars = AsciiWhitespace)
  if s == "transparent": return
  if s in ColorsRGB:
    return some(ColorsRGB[s])
  block hex:
    if s.len == 4:
      for c in s:
        if hexValue(c) == -1:
          break hex
      let c = (hexValue(s[0]) * 17 shl 16) or
        (hexValue(s[1]) * 17 shl 8) or
        (hexValue(s[2]) * 17)
      return some(RGBColor(c))
  # Seriously, what the hell.
  var s2 = if s[0] == '#':
    s.substr(1)
  else:
    s
  for i in 0 ..< s2.len:
    if hexValue(s2[i]) == -1:
      s2[i] = '0'
  while s2.len == 0 or s2.len mod 3 != 0:
    s2 &= '0'
  var l = s2.len div 3
  let c1 = s2[0..<min(l,2)]
  let c2 = s2[l..<min(l*2,l+2)]
  let c3 = s2[l*2..<min(l*3,l*2+2)]
  let c = if l == 1:
    (hexValue(c1[0]) shl 20) or (hexValue(c1[0]) shl 16) or
    (hexValue(c2[0]) shl 12) or (hexValue(c2[0]) shl 8) or
    (hexValue(c3[0]) shl 4) or hexValue(c3[0])
  else:
    (hexValue(c1[0]) shl 20) or (hexValue(c1[1]) shl 16) or
    (hexValue(c2[0]) shl 12) or (hexValue(c2[1]) shl 8) or
    (hexValue(c3[0]) shl 4) or hexValue(c3[1])
  return some(RGBColor(c))
