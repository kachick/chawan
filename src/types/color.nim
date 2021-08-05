type
  RGBColor* = tuple[r: uint8, g: uint8, b: uint8]

  CellColor* = object
    case rgb*: bool
    of true:
      rgbcolor: RGBColor
    of false:
      color*: uint8
