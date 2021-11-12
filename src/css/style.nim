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

  CSSValues* = array[low(CSSRuleType)..high(CSSRuleType), CSSComputedValue]

  CSSColor* = tuple[r: uint8, g: uint8, b: uint8, a: uint8]
  
  CSSComputedValue* = object of RootObj
    t*: CSSRuleType
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
    of VALUE_NONE: discard

  CSSComputedValues* = array[low(CSSRuleType)..high(CSSRuleType), CSSComputedValue]

  CSSSpecifiedValue* = object of CSSComputedValue
    hasGlobalValue: bool
    globalValue: CSSGlobalValueType

const ValueTypes = {
  RULE_ALL: VALUE_NONE,
  RULE_COLOR: VALUE_COLOR,
  RULE_MARGIN: VALUE_LENGTH,
  RULE_MARGIN_TOP: VALUE_LENGTH,
  RULE_MARGIN_BOTTOM: VALUE_LENGTH,
  RULE_MARGIN_LEFT: VALUE_LENGTH,
  RULE_MARGIN_RIGHT: VALUE_LENGTH,
  RULE_FONT_STYLE: VALUE_FONT_STYLE,
  RULE_DISPLAY: VALUE_DISPLAY,
  RULE_CONTENT: VALUE_CONTENT,
  RULE_WHITESPACE: VALUE_WHITESPACE,
  RULE_FONT_WEIGHT: VALUE_INTEGER,
}.toTable()

func getValueType*(rule: CSSRuleType): CSSValueType =
  return ValueTypes[rule]

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
  else: return CSSLength(num: 0, unit: UNIT_EM)

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
              return
          let r = hexValue(s[0]) * 0x10 + hexValue(s[0])
          let g = hexValue(s[1]) * 0x10 + hexValue(s[1])
          let b = hexValue(s[2]) * 0x10 + hexValue(s[2])

          return (uint8(r), uint8(g), uint8(b), 0x00u8)
        elif s.len == 6:
          for r in s:
            if hexValue(r) == -1:
              return
          let r = hexValue(s[0]) * 0x10 + hexValue(s[1])
          let g = hexValue(s[2]) * 0x10 + hexValue(s[3])
          let b = hexValue(s[4]) * 0x10 + hexValue(s[5])
          return (uint8(r), uint8(g), uint8(b), 0x00u8)
        else:
          return defaultColor
      of CSS_IDENT_TOKEN:
        let s = tok.value
        if $s in colors:
          return colors[$s]
        else:
          return defaultColor
      else:
        eprint "else", tok.tokenType
        return defaultColor
    elif d.value[0] of CSSFunction:
      let f = CSSFunction(d.value[0])
      eprint "func", f.name
      #todo calc etc (cssnumber function or something)
      case $f.name
      of "rgb":
        if f.value.len != 3:
          return defaultColor
        for c in f.value:
          if c != CSS_NUMBER_TOKEN:
            return defaultColor
        let r = CSSToken(f.value[0]).nvalue
        let g = CSSToken(f.value[1]).nvalue
        let b = CSSToken(f.value[2]).nvalue
        return (uint8(r), uint8(g), uint8(b), 0x00u8)
      of "rgba":
        if f.value.len != 4:
          return defaultColor
        for c in f.value:
          if c != CSS_NUMBER_TOKEN:
            return defaultColor
        let r = CSSToken(f.value[0]).nvalue
        let g = CSSToken(f.value[1]).nvalue
        let b = CSSToken(f.value[2]).nvalue
        let a = CSSToken(f.value[3]).nvalue
        return (uint8(r), uint8(g), uint8(b), uint8(a))
      else:
        return defaultColor

  return defaultColor

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
  return DISPLAY_INLINE

func cssFontStyle(d: CSSDeclaration): CSSFontStyle =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "normal": return FONTSTYLE_NORMAL
      of "italic": return FONTSTYLE_ITALIC
      of "oblique": return FONTSTYLE_OBLIQUE
      else: return FONTSTYLE_NORMAL
  return FONTSTYLE_NORMAL

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
  return WHITESPACE_NORMAL

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
      else: return 400

    elif tok.tokenType == CSS_NUMBER_TOKEN:
      return int(tok.nvalue)

  return 400

func getSpecifiedValue*(d: CSSDeclaration): CSSSpecifiedValue =
  case $d.name
  of "color":
    return CSSSpecifiedValue(t: RULE_COLOR, v: VALUE_COLOR, color: cssColor(d))
  of "margin":
    return CSSSpecifiedValue(t: RULE_MARGIN, v: VALUE_LENGTH, length: cssLength(d))
  of "margin-top":
    return CSSSpecifiedValue(t: RULE_MARGIN_TOP, v: VALUE_LENGTH, length: cssLength(d))
  of "margin-left":
    return CSSSpecifiedValue(t: RULE_MARGIN_LEFT, v: VALUE_LENGTH, length: cssLength(d))
  of "margin-bottom":
    return CSSSpecifiedValue(t: RULE_MARGIN_BOTTOM, v: VALUE_LENGTH, length: cssLength(d))
  of "margin-right":
    return CSSSpecifiedValue(t: RULE_MARGIN_RIGHT, v: VALUE_LENGTH, length: cssLength(d))
  of "font-style":
    return CSSSpecifiedValue(t: RULE_FONT_STYLE, v: VALUE_FONT_STYLE, fontstyle: cssFontStyle(d))
  of "display":
    return CSSSpecifiedValue(t: RULE_DISPLAY, v: VALUE_DISPLAY, display: cssDisplay(d))
  of "content":
    return CSSSpecifiedValue(t: RULE_CONTENT, v: VALUE_CONTENT, content: cssString(d))
  of "white-space":
    return CSSSpecifiedValue(t: RULE_WHITESPACE, v: VALUE_WHITESPACE, whitespace: cssWhiteSpace(d))
  of "font-weight":
    return CSSSpecifiedValue(t: RULE_FONT_WEIGHT, v: VALUE_INTEGER, integer: cssFontWeight(d))

func getInitialColor*(t: CSSRuleType): CSSColor =
  case t
  of RULE_COLOR:
    return (r: 255u8, g: 255u8, b: 255u8, a: 255u8)
  else:
    return (r: 0u8, g: 0u8, b: 0u8, a: 255u8)

func getComputedValue*(rule: CSSSpecifiedValue, parent: CSSValues): CSSComputedValue =
  let inherit = rule.hasGlobalValue and (rule.globalValue == VALUE_INHERIT)
  let initial = rule.hasGlobalValue and (rule.globalValue == VALUE_INITIAL)
  let unset = rule.hasGlobalValue and (rule.globalValue == VALUE_UNSET)
  let revert = rule.hasGlobalValue and (rule.globalValue == VALUE_REVERT)
  case rule.v
  of VALUE_COLOR:
    var val = rule.color
    if inherit: #TODO and inherited(rule.t):
      val = parent[rule.t].color
    if initial:
      val = getInitialColor(rule.t)
    if unset:
      val = getInitialColor(rule.t)
      #TODO if inherited
    if revert:
      #TODO
      discard
    return CSSComputedValue(t: rule.t, v: VALUE_COLOR, color: val)
  of VALUE_LENGTH:
    return CSSComputedValue(t: rule.t, v: VALUE_LENGTH, length: rule.length)
  of VALUE_DISPLAY:
    return CSSComputedValue(t: rule.t, v: VALUE_DISPLAY, display: rule.display)
  of VALUE_FONT_STYLE:
    return CSSComputedValue(t: rule.t, v: VALUE_FONT_STYLE, fontstyle: rule.fontstyle)
  of VALUE_CONTENT:
    return CSSComputedValue(t: rule.t, v: VALUE_CONTENT, content: rule.content)
  of VALUE_WHITESPACE:
    return CSSComputedValue(t: rule.t, v: VALUE_WHITESPACE, whitespace: rule.whitespace)
  of VALUE_INTEGER:
    return CSSComputedValue(t: rule.t, v: VALUE_INTEGER, integer: rule.integer)
  of VALUE_NONE: return CSSComputedValue(t: rule.t, v: VALUE_NONE)

func getComputedValue*(d: CSSDeclaration, parent: CSSValues): CSSComputedValue =
  return getComputedValue(getSpecifiedValue(d), parent)

func getInitialProperties*(): array[low(CSSRuleType)..high(CSSRuleType), CSSComputedValue] =
  for i in low(result)..high(result):
    let t = CSSRuleType(i)
    let v = getValueType(t)
    case v
    of VALUE_COLOR:
      result[i] = CSSComputedValue(t: t, v: v, color: getInitialColor(t))
    of VALUE_DISPLAY:
      result[i] = CSSComputedValue(t: t, v: v, display: DISPLAY_INLINE)
    else:
      result[i] = CSSComputedValue(t: t, v: v)
