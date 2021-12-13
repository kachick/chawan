import unicode
import tables
import sugar
import sequtils

import utils/twtstr
import types/enums
import css/parser
import types/color

type
  CSSLength* = object
    num*: float64
    unit*: CSSUnit
    auto*: bool

  CSSColor* = object
    rgba: RGBAColor
    termcolor: int
  
  CSSComputedValue* = ref object of RootObj
    t*: CSSPropertyType
    case v*: CSSValueType
    of VALUE_COLOR:
      color*: CSSColor
    of VALUE_LENGTH:
      length*: CSSLength
    of VALUE_FONT_STYLE:
      fontstyle*: CSSFontStyle
    of VALUE_DISPLAY:
      display*: CSSDisplay
    of VALUE_CONTENT:
      content*: seq[Rune]
    of VALUE_WHITESPACE:
      whitespace*: CSSWhitespace
    of VALUE_INTEGER:
      integer*: int
    of VALUE_TEXT_DECORATION:
      textdecoration*: CSSTextDecoration
    of VALUE_WORD_BREAK:
      wordbreak*: CSSWordBreak
    of VALUE_NONE: discard

  CSSComputedValues* = ref array[low(CSSPropertyType)..high(CSSPropertyType), CSSComputedValue]

  CSSSpecifiedValue* = object of CSSComputedValue
    globalValue*: CSSGlobalValueType

  CSSValueError* = object of ValueError

#TODO calculate this during compile time
const PropertyNames = {
  "all": PROPERTY_ALL,
  "color": PROPERTY_COLOR,
  "margin": PROPERTY_MARGIN,
  "margin-top": PROPERTY_MARGIN_TOP,
  "margin-bottom": PROPERTY_MARGIN_BOTTOM,
  "margin-left": PROPERTY_MARGIN_LEFT,
  "margin-right": PROPERTY_MARGIN_RIGHT,
  "font-style": PROPERTY_FONT_STYLE,
  "display": PROPERTY_DISPLAY,
  "content": PROPERTY_CONTENT,
  "white-space": PROPERTY_WHITE_SPACE,
  "font-weight": PROPERTY_FONT_WEIGHT,
  "text-decoration": PROPERTY_TEXT_DECORATION,
  "word-break": PROPERTY_WORD_BREAK,
  "width": PROPERTY_WIDTH,
  "height": PROPERTY_HEIGHT,
}.toTable()

const ValueTypes = [
  PROPERTY_NONE: VALUE_NONE,
  PROPERTY_ALL: VALUE_NONE,
  PROPERTY_COLOR: VALUE_COLOR,
  PROPERTY_MARGIN: VALUE_LENGTH,
  PROPERTY_MARGIN_TOP: VALUE_LENGTH,
  PROPERTY_MARGIN_LEFT: VALUE_LENGTH,
  PROPERTY_MARGIN_RIGHT: VALUE_LENGTH,
  PROPERTY_MARGIN_BOTTOM: VALUE_LENGTH,
  PROPERTY_FONT_STYLE: VALUE_FONT_STYLE,
  PROPERTY_DISPLAY: VALUE_DISPLAY,
  PROPERTY_CONTENT: VALUE_CONTENT,
  PROPERTY_WHITE_SPACE: VALUE_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT: VALUE_INTEGER,
  PROPERTY_TEXT_DECORATION: VALUE_TEXT_DECORATION,
  PROPERTY_WORD_BREAK: VALUE_WORD_BREAK,
  PROPERTY_WIDTH: VALUE_LENGTH,
  PROPERTY_HEIGHT: VALUE_LENGTH,
]

const InheritedProperties = {
  PROPERTY_COLOR, PROPERTY_FONT_STYLE, PROPERTY_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK
}

func getPropInheritedArray(): array[low(CSSPropertyType)..high(CSSPropertyType), bool] =
  for prop in low(CSSPropertyType)..high(CSSPropertyType):
    if prop in InheritedProperties:
      result[prop] = true
    else:
      result[prop] = false

const InheritedArray = getPropInheritedArray()

func propertyType*(s: string): CSSPropertyType =
  return PropertyNames.getOrDefault(s, PROPERTY_NONE)

func valueType*(prop: CSSPropertyType): CSSValueType =
  return ValueTypes[prop]

func inherited(t: CSSPropertyType): bool =
  return InheritedArray[t]

func cells*(l: CSSLength): int =
  case l.unit
  of UNIT_EM:
    return int(l.num)
  of UNIT_CH:
    return int(l.num)
  of UNIT_REM:
    return int(l.num)
  else:
    #TODO
    return int(l.num / 8)

func r(c: CSSColor): int =
  return c.rgba.r

func g(c: CSSColor): int =
  return c.rgba.g

func b(c: CSSColor): int =
  return c.rgba.b

func a(c: CSSColor): int =
  return c.rgba.a

const colors = {
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
}.map((a) => (a[0], CSSColor(rgba: RGBAColor(a[1])))).toTable()

func cssLength(val: float64, unit: string): CSSLength =
  case unit
  of "%": return CSSLength(num: val, unit: UNIT_PERC)
  of "cm": return CSSLength(num: val, unit: UNIT_CM)
  of "mm": return CSSLength(num: val, unit: UNIT_MM)
  of "in": return CSSLength(num: val, unit: UNIT_IN)
  of "px": return CSSLength(num: val, unit: UNIT_PX)
  of "pt": return CSSLength(num: val, unit: UNIT_PT)
  of "pc": return CSSLength(num: val, unit: UNIT_PC)
  of "em": return CSSLength(num: val, unit: UNIT_EM)
  of "ex": return CSSLength(num: val, unit: UNIT_EX)
  of "ch": return CSSLength(num: val, unit: UNIT_CH)
  of "rem": return CSSLength(num: val, unit: UNIT_REM)
  of "vw": return CSSLength(num: val, unit: UNIT_VW)
  of "vh": return CSSLength(num: val, unit: UNIT_VH)
  of "vmin": return CSSLength(num: val, unit: UNIT_VMIN)
  of "vmax": return CSSLength(num: val, unit: UNIT_VMAX)
  else: raise newException(CSSValueError, "Invalid unit")

func color(r, g, b: int): CSSColor =
  return CSSColor(rgba: rgba(r, g, b, 256))

func color(r, g, b, a: int): CSSColor =
  return CSSColor(rgba: rgba(r, g, b, a))

func cssColor*(d: CSSDeclaration): CSSColor =
  if d.value.len > 0:
    if d.value[0] of CSSToken:
      let tok = CSSToken(d.value[0])
      case tok.tokenType
      of CSS_HASH_TOKEN:
        let s = tok.value
        if s.len == 3:
          for r in s:
            if hexValue(r) == -1:
              raise newException(CSSValueError, "Invalid color")
          let c = (hexValue(s[0]) shl 20) or (hexValue(s[0]) shl 16) or
                  (hexValue(s[1]) shl 12) or (hexValue(s[1]) shl 8) or
                  (hexValue(s[2]) shl 4) or hexValue(s[2])
          return CSSColor(rgba: RGBAColor(c))
        elif s.len == 6:
          for r in s:
            if hexValue(r) == -1:
              raise newException(CSSValueError, "Invalid color")
          let c = (hexValue(s[0]) shl 20) or (hexValue(s[1]) shl 16) or
                  (hexValue(s[2]) shl 12) or (hexValue(s[3]) shl 8) or
                  (hexValue(s[4]) shl 4) or hexValue(s[5])
          return CSSColor(rgba: RGBAColor(c))
        else:
          raise newException(CSSValueError, "Invalid color")
      of CSS_IDENT_TOKEN:
        let s = tok.value
        if $s in colors:
          return colors[$s]
        else:
          raise newException(CSSValueError, "Invalid color")
      else:
        raise newException(CSSValueError, "Invalid color")
    elif d.value[0] of CSSFunction:
      let f = CSSFunction(d.value[0])
      #TODO calc etc (cssnumber function or something)
      case $f.name
      of "rgb":
        if f.value.len != 3:
          raise newException(CSSValueError, "Invalid color")
        for c in f.value:
          if c != CSS_NUMBER_TOKEN:
            raise newException(CSSValueError, "Invalid color")
        let r = CSSToken(f.value[0]).nvalue
        let g = CSSToken(f.value[1]).nvalue
        let b = CSSToken(f.value[2]).nvalue
        return color(int(r), int(g), int(b))
      of "rgba":
        if f.value.len != 4:
          raise newException(CSSValueError, "Invalid color")
        for c in f.value:
          if c != CSS_NUMBER_TOKEN:
            raise newException(CSSValueError, "Invalid color")
        let r = CSSToken(f.value[0]).nvalue
        let g = CSSToken(f.value[1]).nvalue
        let b = CSSToken(f.value[2]).nvalue
        let a = CSSToken(f.value[3]).nvalue
        return color(int(r), int(g), int(b), int(a))
      else: discard

  raise newException(CSSValueError, "Invalid color")

func cellColor*(color: CSSColor): CellColor =
  #TODO better would be to store color names and return term colors on demand
  #option)
  return CellColor(rgb: true, rgbcolor: RGBColor(color.rgba))

func cssLength(d: CSSDeclaration): CSSLength =
  if d.value.len > 0 and d.value[0] of CSSToken:
    let tok = CSSToken(d.value[0])
    case tok.tokenType
    of CSS_PERCENTAGE_TOKEN:
      return cssLength(tok.nvalue, "%")
    of CSS_DIMENSION_TOKEN:
      return cssLength(tok.nvalue, $tok.unit)
    of CSS_IDENT_TOKEN:
      if $tok.value == "auto":
        return CSSLength(auto: true)
    else:
      return CSSLength(num: 0, unit: UNIT_EM)

  return CSSLength(num: 0, unit: UNIT_EM)

#func hasColor*(style: CSS2Properties): bool =
#  return style.color.r != 0 or style.color.b != 0 or style.color.g != 0 or style.color.a != 0
#
#func termColor*(style: CSS2Properties): ForegroundColor =
#  if style.color.r > 120:
#    return fgRed
#  elif style.color.b > 120:
#    return fgBlue
#  elif style.color.g > 120:
#    return fgGreen
#  else:
#    return fgWhite

func isToken(d: CSSDeclaration): bool = d.value.len > 0 and d.value[0] of CSSToken
func getToken(d: CSSDeclaration): CSSToken = (CSSToken)d.value[0]

func cssGlobal(d: CSSDeclaration): CSSGlobalValueType =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "inherit": return VALUE_INHERIT
      of "initial": return VALUE_INITIAL
      of "unset": return VALUE_UNSET
      of "revert": return VALUE_REVERT
  return VALUE_NOGLOBAL

func cssString(d: CSSDeclaration): seq[Rune] =
  if isToken(d):
    let tok = getToken(d)
    case tok.tokenType
    of CSS_IDENT_TOKEN, CSS_STRING_TOKEN:
      return tok.value
    else: return

func cssDisplay(d: CSSDeclaration): CSSDisplay =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "block": return DISPLAY_BLOCK
      of "inline": return DISPLAY_INLINE
      # of "inline-block": return DISPLAY_INLINE_BLOCK
      # of "list-item": return DISPLAY_LIST_ITEM
      # of "table": return DISPLAY_TABLE
      # of "table-row-group": return DISPLAY_TABLE_ROW_GROUP
      # of "table-header-group": return DISPLAY_TABLE_HEADER_GROUP
      # of "table-footer-group": return DISPLAY_TABLE_FOOTER_GROUP
      # of "table-column-group": return DISPLAY_TABLE_COLUMN_GROUP
      # of "table-row": return DISPLAY_TABLE_ROW
      # of "table-column": return DISPLAY_TABLE_COLUMN
      # of "table-cell": return DISPLAY_TABLE_CELL
      of "none": return DISPLAY_NONE
      else: return DISPLAY_INLINE
  raise newException(CSSValueError, "Invalid display")

func cssFontStyle(d: CSSDeclaration): CSSFontStyle =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "normal": return FONTSTYLE_NORMAL
      of "italic": return FONTSTYLE_ITALIC
      of "oblique": return FONTSTYLE_OBLIQUE
      else: raise newException(CSSValueError, "Invalid font style")
  raise newException(CSSValueError, "Invalid font style")

func cssWhiteSpace(d: CSSDeclaration): CSSWhitespace =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "normal": return WHITESPACE_NORMAL
      of "nowrap": return WHITESPACE_NOWRAP
      of "pre": return WHITESPACE_PRE
      of "pre-line": return WHITESPACE_PRE_LINE
      of "pre-wrap": return WHITESPACE_PRE_WRAP
      else: return WHITESPACE_NORMAL
  raise newException(CSSValueError, "Invalid whitespace")

#TODO
func cssFontWeight(d: CSSDeclaration): int =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "normal": return 400
      of "bold": return 700
      of "lighter": return 400
      of "bolder": return 700

    elif tok.tokenType == CSS_NUMBER_TOKEN:
      return int(tok.nvalue)

  raise newException(CSSValueError, "Invalid font weight")

func cssTextDecoration(d: CSSDeclaration): CSSTextDecoration =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "underline": return TEXT_DECORATION_UNDERLINE
      of "overline": return TEXT_DECORATION_OVERLINE
      of "line-through": return TEXT_DECORATION_LINE_THROUGH
      of "blink": return TEXT_DECORATION_BLINK
  raise newException(CSSValueError, "Invalid text decoration")

func cssWordBreak(d: CSSDeclaration): CSSWordBreak =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "normal": return WORD_BREAK_NORMAL
      of "break-all": return WORD_BREAK_BREAK_ALL
      of "keep-all": return WORD_BREAK_KEEP_ALL
  raise newException(CSSValueError, "Invalid text decoration")

func getSpecifiedValue*(d: CSSDeclaration): CSSSpecifiedValue =
  let name = $d.name
  let ptype = propertyType(name)
  let vtype = valueType(ptype)
  result = CSSSpecifiedValue(t: ptype, v: vtype)
  try:
    case vtype
    of VALUE_COLOR: result.color = cssColor(d)
    of VALUE_LENGTH: result.length = cssLength(d)
    of VALUE_FONT_STYLE: result.fontstyle = cssFontStyle(d)
    of VALUE_DISPLAY: result.display = cssDisplay(d)
    of VALUE_CONTENT: result.content = cssString(d)
    of VALUE_WHITE_SPACE: result.whitespace = cssWhiteSpace(d)
    of VALUE_INTEGER:
      if ptype == PROPERTY_FONT_WEIGHT:
        result.integer = cssFontWeight(d)
    of VALUE_TEXT_DECORATION: result.textdecoration = cssTextDecoration(d)
    of VALUE_WORD_BREAK: result.wordbreak = cssWordBreak(d)
    of VALUE_NONE: discard
  except CSSValueError:
    result.globalValue = VALUE_UNSET

  if result.globalValue == VALUE_NOGLOBAL:
    result.globalValue = cssGlobal(d)

func getInitialColor(t: CSSPropertyType): CSSColor =
  case t
  of PROPERTY_COLOR:
    return colors["white"]
  else:
    return colors["black"]

func getInitialLength(t: CSSPropertyType): CSSLength =
  case t
  of PROPERTY_WIDTH, PROPERTY_HEIGHT:
    return CSSLength(auto: true)
  else:
    return CSSLength()

func calcDefault(t: CSSPropertyType): CSSComputedValue =
  let v = valueType(t)
  var nv: CSSComputedValue
  case v
  of VALUE_COLOR:
    nv = CSSComputedValue(t: t, v: v, color: getInitialColor(t))
  of VALUE_DISPLAY:
    nv = CSSComputedValue(t: t, v: v, display: DISPLAY_INLINE)
  of VALUE_WORD_BREAK:
    nv = CSSComputedValue(t: t, v: v, wordbreak: WORD_BREAK_NORMAL)
  of VALUE_LENGTH:
    nv = CSSComputedValue(t: t, v: v, length: getInitialLength(t))
  else:
    nv = CSSComputedValue(t: t, v: v)
  return nv

func getDefaultTable(): array[low(CSSPropertyType)..high(CSSPropertyType), CSSComputedValue] =
  for i in low(result)..high(result):
    result[i] = calcDefault(i)

let defaultTable = getDefaultTable()

func getDefault(t: CSSPropertyType): CSSComputedValue = {.cast(noSideEffect).}:
  assert defaultTable[t] != nil
  return defaultTable[t]

func getComputedValue*(prop: CSSSpecifiedValue, current: CSSComputedValues): CSSComputedValue =
  case prop.globalValue
  of VALUE_INHERIT:
    if inherited(prop.t):
      return current[prop.t]
  of VALUE_INITIAL:
    return getDefault(prop.t)
  of VALUE_UNSET:
    if inherited(prop.t):
      return current[prop.t]
    return getDefault(prop.t)
  of VALUE_REVERT:
    #TODO
    discard
  of VALUE_NOGLOBAL: discard

  case prop.v
  of VALUE_COLOR:
    return CSSComputedValue(t: prop.t, v: VALUE_COLOR, color: prop.color)
  of VALUE_LENGTH:
    return CSSComputedValue(t: prop.t, v: VALUE_LENGTH, length: prop.length)
  of VALUE_DISPLAY:
    return CSSComputedValue(t: prop.t, v: VALUE_DISPLAY, display: prop.display)
  of VALUE_FONT_STYLE:
    return CSSComputedValue(t: prop.t, v: VALUE_FONT_STYLE, fontstyle: prop.fontstyle)
  of VALUE_CONTENT:
    return CSSComputedValue(t: prop.t, v: VALUE_CONTENT, content: prop.content)
  of VALUE_WHITESPACE:
    return CSSComputedValue(t: prop.t, v: VALUE_WHITESPACE, whitespace: prop.whitespace)
  of VALUE_INTEGER:
    return CSSComputedValue(t: prop.t, v: VALUE_INTEGER, integer: prop.integer)
  of VALUE_TEXT_DECORATION:
    return CSSComputedValue(t: prop.t, v: VALUE_TEXT_DECORATION, textdecoration: prop.textdecoration)
  of VALUE_WORD_BREAK:
    return CSSComputedValue(t: prop.t, v: VALUE_WORD_BREAK, wordbreak: prop.wordbreak)
  of VALUE_NONE: return CSSComputedValue(t: prop.t, v: VALUE_NONE)

func getComputedValue*(d: CSSDeclaration, current: CSSComputedValues): CSSComputedValue =
  return getComputedValue(getSpecifiedValue(d), current)

proc rootProperties*(vals: var CSSComputedValues) =
  new(vals)
  for prop in low(CSSPropertyType)..high(CSSPropertyType):
    vals[prop] = getDefault(prop)

proc inheritProperties*(vals: var CSSComputedValues, parent: CSSComputedValues) =
  if vals == nil:
    new(vals)
  for prop in low(CSSPropertyType)..high(CSSPropertyType):
    if vals[prop] == nil:
      vals[prop] = getDefault(prop)
    if inherited(prop) and parent[prop] != nil and vals[prop] == getDefault(prop):
      vals[prop] = parent[prop]
