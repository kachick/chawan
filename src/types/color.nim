type
  RGBColor* = tuple[r: uint8, g: uint8, b: uint8]

  CellColor* = object
    case rgb*: bool
    of true:
      rgbcolor*: RGBColor
    of false:
      color*: uint8

func `==`*(color1: CellColor, color2: CellColor): bool =
  if color1.rgb != color2.rgb:
    return false
  if color1.rgb:
    return color1.rgbcolor == color2.rgbcolor
  return color1.color == color2.color

const defaultColor* = CellColor(rgb: false, color: 0)
