import options
import sequtils
import strutils
import sugar
import tables

import utils/twtstr

type
  RGBColor* = distinct uint32

  RGBAColor* = distinct uint32

  CellColor* = object
    case rgb*: bool
    of true:
      rgbcolor*: RGBColor
    of false:
      color*: uint8

converter toRGBColor*(i: RGBAColor): RGBColor =
  return RGBColor(uint32(i) and 0xFFFFFFu32)

converter toRGBAColor*(i: RGBColor): RGBAColor =
  return RGBAColor(uint32(i) or 0xFF000000u32)

func `==`*(color1, color2: CellColor): bool =
  if color1.rgb != color2.rgb:
    return false
  if color1.rgb:
    return int(color1.rgbcolor) == int(color2.rgbcolor)
  return color1.color == color2.color

const defaultColor* = CellColor(rgb: false, color: 0)

const ColorsANSIFg* = [
  CellColor(rgb: false, color: 30), # black
  CellColor(rgb: false, color: 31), # red
  CellColor(rgb: false, color: 32), # green
  CellColor(rgb: false, color: 33), # yellow
  CellColor(rgb: false, color: 34), # blue
  CellColor(rgb: false, color: 35), # magenta
  CellColor(rgb: false, color: 36), # cyan
  CellColor(rgb: false, color: 37), # white
]

const ColorsANSIBg* = [
  CellColor(rgb: false, color: 40), # black
  CellColor(rgb: false, color: 41), # red
  CellColor(rgb: false, color: 42), # green
  CellColor(rgb: false, color: 43), # yellow
  CellColor(rgb: false, color: 44), # blue
  CellColor(rgb: false, color: 45), # magenta
  CellColor(rgb: false, color: 46), # cyan
  CellColor(rgb: false, color: 47), # white
]

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
  let c = (hexValue(c1[0]) shl 20) or (hexValue(c1[1]) shl 16) or
          (hexValue(c2[0]) shl 12) or (hexValue(c2[1]) shl 8) or
          (hexValue(c3[0]) shl 4) or hexValue(c3[1])
  return some(RGBColor(c))

func r*(c: RGBAColor): int =
  return int(c) shr 16 and 0xff

func g*(c: RGBAColor): int =
  return int(c) shr 8 and 0xff

func b*(c: RGBAColor): int =
  return int(c) and 0xff

func a*(c: RGBAColor): int =
  return int(c) shr 24 and 0xff

func rgb*(r, g, b: int): RGBColor =
  return RGBColor((r shl 16) or (g shl 8) or b)

func `==`*(a, b: RGBAColor): bool =
  return int(a) == int(b)


func r*(c: RGBColor): int =
  return int(c) shr 16 and 0xff

func g*(c: RGBColor): int =
  return int(c) shr 8 and 0xff

func b*(c: RGBColor): int =
  return int(c) and 0xff

func rgba*(r, g, b, a: int): RGBAColor =
  return RGBAColor((a shl 24) or (r shl 16) or (g shl 8) or b)

func `$`*(color: CellColor): string =
  if color.rgb:
    "r" & $color.rgbcolor.r & "g" & $color.rgbcolor.g & "b" & $color.rgbcolor.b
  else:
    "tcolor" & $color.color
