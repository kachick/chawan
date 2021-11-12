import unicode
import tables

import utils/twtstr
import types/enums
import css/parser
import types/color

type
  CSSLength* = object
    num*: float64
    unit*: CSSUnit
    auto*: bool

  CSSComputedValues* = array[low(CSSPropertyType)..high(CSSPropertyType), CSSComputedValue]

  CSSColor* = tuple[r: uint8, g: uint8, b: uint8, a: uint8]
  
  CSSComputedValue* = object of RootObj
    t*: CSSPropertyType
    case v*: CSSValueType
    of VALUE_COLOR:
      color*: CSSColor
    of VALUE_LENGTH:
      length*: CSSLength
    of VALUE_FONT_STYLE:
      fontstyle*: CSSFontStyle
    of VALUE_DISPLAY:
      display*: DisplayType
    of VALUE_CONTENT:
      content*: seq[Rune]
    of VALUE_WHITESPACE:
      whitespace*: WhitespaceType
    of VALUE_INTEGER:
      integer*: int
    of VALUE_TEXT_DECORATION:
      textdecoration*: CSSTextDecoration
    of VALUE_NONE: discard

  CSSSpecifiedValue* = object of CSSComputedValue
    globalValue: CSSGlobalValueType

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
}.toTable()

const ValueTypes = {
  PROPERTY_NONE: VALUE_NONE,
  PROPERTY_ALL: VALUE_NONE,
  PROPERTY_COLOR: VALUE_COLOR,
  PROPERTY_MARGIN: VALUE_LENGTH,
  PROPERTY_MARGIN_TOP: VALUE_LENGTH,
  PROPERTY_MARGIN_BOTTOM: VALUE_LENGTH,
  PROPERTY_MARGIN_LEFT: VALUE_LENGTH,
  PROPERTY_MARGIN_RIGHT: VALUE_LENGTH,
  PROPERTY_FONT_STYLE: VALUE_FONT_STYLE,
  PROPERTY_DISPLAY: VALUE_DISPLAY,
  PROPERTY_CONTENT: VALUE_CONTENT,
  PROPERTY_WHITE_SPACE: VALUE_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT: VALUE_INTEGER,
  PROPERTY_TEXT_DECORATION: VALUE_TEXT_DECORATION,
}.toTable()

const InheritedProperties = {
  PROPERTY_COLOR, PROPERTY_FONT_STYLE, PROPERTY_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION
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
  else:
    #TODO
    return int(l.num / 8)

const colors = {
  "maroon":  (0x80u8, 0x00u8, 0x00u8, 0x00u8),
  "red":     (0xffu8, 0x00u8, 0x00u8, 0x00u8),
  "orange":  (0xffu8, 0xa5u8, 0x00u8, 0x00u8),
  "yellow":  (0xffu8, 0xffu8, 0x00u8, 0x00u8),
  "olive":   (0x80u8, 0x80u8, 0x00u8, 0x00u8),
  "purple":  (0x80u8, 0x00u8, 0x80u8, 0x00u8),
  "fuchsia": (0xffu8, 0x00u8, 0x00u8, 0x00u8),
  "white":   (0xffu8, 0xffu8, 0xffu8, 0x00u8),
  "lime":    (0x00u8, 0xffu8, 0x00u8, 0x00u8),
  "green":   (0x00u8, 0x80u8, 0x00u8, 0x00u8),
  "navy":    (0x00u8, 0x00u8, 0x80u8, 0x00u8),
  "blue":    (0x00u8, 0x00u8, 0xffu8, 0x00u8),
  "aqua":    (0x00u8, 0xffu8, 0xffu8, 0x00u8),
  "teal":    (0x00u8, 0x80u8, 0x80u8, 0x00u8),
  "black":   (0x00u8, 0x00u8, 0x00u8, 0x00u8),
  "silver":  (0xc0u8, 0xc0u8, 0xc0u8, 0x00u8),
  "gray":    (0x80u8, 0x80u8, 0x80u8, 0x00u8),
}.toTable()

const defaultColor = (0xffu8, 0xffu8, 0xffu8, 0x00u8)

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
          let r = hexValue(s[0]) * 0x10 + hexValue(s[0])
          let g = hexValue(s[1]) * 0x10 + hexValue(s[1])
          let b = hexValue(s[2]) * 0x10 + hexValue(s[2])

          return (uint8(r), uint8(g), uint8(b), 0x00u8)
        elif s.len == 6:
          for r in s:
            if hexValue(r) == -1:
              raise newException(CSSValueError, "Invalid color")
          let r = hexValue(s[0]) * 0x10 + hexValue(s[1])
          let g = hexValue(s[2]) * 0x10 + hexValue(s[3])
          let b = hexValue(s[4]) * 0x10 + hexValue(s[5])
          return (uint8(r), uint8(g), uint8(b), 0x00u8)
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
      eprint "func", f.name
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
        return (uint8(r), uint8(g), uint8(b), 0x00u8)
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
        return (uint8(r), uint8(g), uint8(b), uint8(a))
      else: discard

  raise newException(CSSValueError, "Invalid color")

func cellColor*(color: CSSColor): CellColor =
  #TODO better would be to store color names and return term colors on demand
  #option)
  return CellColor(rgb: true, rgbcolor: (r: color.r, g: color.g, b: color.b))

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

func cssString(d: CSSDeclaration): seq[Rune] =
  if isToken(d):
    let tok = getToken(d)
    case tok.tokenType
    of CSS_IDENT_TOKEN, CSS_STRING_TOKEN:
      return tok.value
    else: return

func cssDisplay(d: CSSDeclaration): DisplayType =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "block": return DISPLAY_BLOCK
      of "inline": return DISPLAY_INLINE
      of "inline-block": return DISPLAY_INLINE_BLOCK
      of "list-item": return DISPLAY_LIST_ITEM
      of "table-column": return DISPLAY_TABLE_COLUMN
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

func cssWhiteSpace(d: CSSDeclaration): WhitespaceType =
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
      case ptype
      of PROPERTY_FONT_WEIGHT:
        result.integer = cssFontWeight(d)
      else: discard #???
    of VALUE_TEXT_DECORATION: result.textdecoration = cssTextDecoration(d)
    of VALUE_NONE: discard
  except CSSValueError:
    result.globalValue = VALUE_UNSET

  if result.globalValue == VALUE_NOGLOBAL:
    result.globalValue = cssGlobal(d)

func getInitialColor*(t: CSSPropertyType): CSSColor =
  case t
  of PROPERTY_COLOR:
    return (r: 255u8, g: 255u8, b: 255u8, a: 255u8)
  else:
    return (r: 0u8, g: 0u8, b: 0u8, a: 255u8)

func getDefault(t: CSSPropertyType): CSSComputedValue =
  let v = valueType(t)
  var nv: CSSComputedValue
  case v
  of VALUE_COLOR:
    nv = CSSComputedValue(t: t, v: v, color: getInitialColor(t))
  of VALUE_DISPLAY:
    nv = CSSComputedValue(t: t, v: v, display: DISPLAY_INLINE)
  else:
    nv = CSSComputedValue(t: t, v: v)
  return nv

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
  of VALUE_NONE: return CSSComputedValue(t: prop.t, v: VALUE_NONE)

func getComputedValue*(d: CSSDeclaration, current: CSSComputedValues): CSSComputedValue =
  return getComputedValue(getSpecifiedValue(d), current)

func inheritProperties*(parent: CSSComputedValues): CSSComputedValues =
  for prop in low(CSSPropertyType)..high(CSSPropertyType):
    if inherited(prop):
      result[prop] = parent[prop]
    else:
      result[prop] = getDefault(prop)

func rootProperties*(): CSSComputedValues =
  for prop in low(CSSPropertyType)..high(CSSPropertyType):
    result[prop] = getDefault(prop)
