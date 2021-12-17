type
  RGBColor* = distinct int

  RGBAColor* = distinct int

  CellColor* = object
    case rgb*: bool
    of true:
      rgbcolor*: RGBColor
    of false:
      color*: uint8

func `==`*(color1, color2: CellColor): bool =
  if color1.rgb != color2.rgb:
    return false
  if color1.rgb:
    return int(color1.rgbcolor) == int(color2.rgbcolor)
  return color1.color == color2.color

const defaultColor* = CellColor(rgb: false, color: 0)

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


func r*(c: RGBColor): int =
  return int(c) shr 16 and 0xff

func g*(c: RGBColor): int =
  return int(c) shr 8 and 0xff

func b*(c: RGBColor): int =
  return int(c) and 0xff

func rgba*(r, g, b, a: int): RGBAColor =
  return RGBAColor((a shl 24) or (r shl 16) or (g shl 8) or b)

converter toRGBColor*(i: RGBAColor): RGBColor =
  return RGBColor(int(i) and 0xFFFFFF)
