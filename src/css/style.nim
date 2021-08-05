import unicode
import terminal
import tables


import ../utils/twtstr
import ../utils/eprint

import ../types/enums

import ./cssparser

type
  CSSLength* = object
    num*: float64
    unit*: CSSUnit
    auto*: bool

  CSS2Properties* = ref object
    rawtext*: string
    fmttext*: seq[string]
    x*: int
    y*: int
    ex*: int
    ey*: int
    width*: int
    height*: int
    hidden*: bool
    before*: CSS2Properties
    after*: CSS2Properties
    margintop*: CSSLength
    marginbottom*: CSSLength
    marginleft*: CSSLength
    marginright*: CSSLength
    centered*: bool
    display*: DisplayType
    bold*: bool
    fontStyle*: CSSFontStyle
    underscore*: bool
    islink*: bool
    selected*: bool
    indent*: int
    color*: CSSColor
    position*: CSSPosition
    content*: seq[Rune]

  CSSCanvas* = object
    rootBox*: CSSBox
    width*: int
    height*: int

  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref object
    display*: DisplayType
    x*: int
    y*: int
    innerEdge*: CSSRect
    paddingEdge*: CSSRect
    borderEdge*: CSSRect
    marginEdge*: CSSRect
    props*: CSS2Properties
    content*: seq[Rune]
    dispcontent*: string
    children*: seq[CSSBox]

  CSSColor* = tuple[r: uint8, g: uint8, b: uint8, a: uint8]
  
  CSSComputedValue* = object of RootObj
    case t: CSSRuleType
    of RULE_ALL: discard
    of RULE_COLOR:
      color: CSSColor
    of RULE_MARGIN, RULE_MARGIN_TOP, RULE_MARGIN_LEFT, RULE_MARGIN_RIGHT,
       RULE_MARGIN_BOTTOM:
      length: CSSLength
    of RULE_FONT_STYLE:
      fontStyle: CSSFontStyle
    of RULE_DISPLAY:
      display: DisplayType
    of RULE_CONTENT:
      content: seq[Rune]

  CSSSpecifiedValue* = object of CSSComputedValue
    hasGlobalValue: bool
    globalValue: CSSGlobalValueType


func `+`(a: CSSRect, b: CSSRect): CSSRect =
  result.x1 = a.x1 + b.x1
  result.y1 = a.y1 + b.y1
  result.x2 = a.x2 + b.x2
  result.y2 = a.y2 + b.y2

proc `+=`(a: var CSSRect, b: CSSRect) =
  a = a + b

func cells(l: CSSLength): int =
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
        eprint "ident", s
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
          eprint "too few args"
          return defaultColor
        for c in f.value:
          if c != CSS_NUMBER_TOKEN:
            eprint "not number"
            return defaultColor
        let r = CSSToken(f.value[0]).nvalue
        let g = CSSToken(f.value[1]).nvalue
        let b = CSSToken(f.value[2]).nvalue
        let a = CSSToken(f.value[3]).nvalue
        return (uint8(r), uint8(g), uint8(b), uint8(a))
      else:
        eprint "not rgba"
        return defaultColor

  return defaultColor

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

func hasColor*(style: CSS2Properties): bool =
  return style.color.r != 0 or style.color.b != 0 or style.color.g != 0 or style.color.a != 0

func termColor*(style: CSS2Properties): ForegroundColor =
  if style.color.r > 120:
    return fgRed
  elif style.color.b > 120:
    return fgBlue
  elif style.color.g > 120:
    return fgGreen
  else:
    return fgWhite

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

func getSpecifiedValue*(d: CSSDeclaration): CSSSpecifiedValue =
  case $d.name
  of "color":
    return CSSSpecifiedValue(t: RULE_COLOR, color: cssColor(d))
  of "margin":
    return CSSSpecifiedValue(t: RULE_MARGIN, length: cssLength(d))
  of "margin-top":
    return CSSSpecifiedValue(t: RULE_MARGIN_TOP, length: cssLength(d))
  of "margin-left":
    return CSSSpecifiedValue(t: RULE_MARGIN_LEFT, length: cssLength(d))
  of "margin-bottom":
    return CSSSpecifiedValue(t: RULE_MARGIN_BOTTOM, length: cssLength(d))
  of "margin-right":
    return CSSSpecifiedValue(t: RULE_MARGIN_RIGHT, length: cssLength(d))
  of "font-style":
    return CSSSpecifiedValue(t: RULE_FONT_STYLE, fontStyle: cssFontStyle(d))
  of "display":
    return CSSSpecifiedValue(t: RULE_DISPLAY, display: cssDisplay(d))
  of "content":
    return CSSSpecifiedValue(t: RULE_CONTENT, content: cssString(d))

func getComputedValue*(rule: CSSSpecifiedValue): CSSComputedValue =
  let inherit = rule.hasGlobalValue and (rule.globalValue == VALUE_INHERIT)
  let initial = rule.hasGlobalValue and (rule.globalValue == VALUE_INHERIT)
  let unset = rule.hasGlobalValue and (rule.globalValue == VALUE_INHERIT)
  let revert = rule.hasGlobalValue and (rule.globalValue == VALUE_INHERIT)
  #case rule.t
  #of RULE_COLOR:
  #  return CSSComputedValue(t: rule.t, 

func getComputedValue*(d: CSSDeclaration): CSSComputedValue =
  return getComputedValue(getSpecifiedValue(d))

proc applyProperty*(props: CSS2Properties, d: CSSDeclaration) =
  case $d.name
  of "color":
    props.color = cssColor(d)
  of "margin":
    let l = cssLength(d)
    props.margintop = l
    props.marginbottom = l
    props.marginleft = l
    props.marginright = l
  of "margin-top":
    props.margintop = cssLength(d)
  of "margin-left":
    props.marginleft = cssLength(d)
  of "margin-right":
    props.marginright = cssLength(d)
  of "margin-bottom":
    props.marginbottom = cssLength(d)
  of "font-style":
    props.fontStyle = cssFontStyle(d)
  of "display":
    props.display = cssDisplay(d)
  of "content":
    props.content = cssString(d)
  else:
    printc(d) #TODO

func getLength(s: seq[Rune], start: int, wlimit: int): tuple[wrap: bool, len: int, width: int] =
  var len = 0
  var width = 0
  var i = start
  while i < s.len:
    let r = s[i]
    let cw = r.width()
    if width + cw > wlimit:
      return (wrap: true, len: len, width: width)
    width += cw
    len += 1
  
  return (wrap: false, len: len, width: width)

proc arrangeBoxes*(canvas: CSSCanvas) =
  var stack: seq[CSSBox]
  stack.add(canvas.rootBox)
  var x = 0
  var y = 0

  while stack.len > 0:
    let box = stack.pop()

    #arrange box
    box.marginEdge.x1 = x
    box.marginEdge.y1 = y
    x += box.props.marginleft.cells()
    y += box.props.margintop.cells()

    if box.display == DISPLAY_BLOCK:
      x = 0
      inc y

    if x > canvas.width:
      x = 0
      inc y

    box.x = x
    box.y = y

    var l = 0
    while l < box.content.len:
      let (wrap, wraplen, wrapwidth) = box.content.getLength(l, canvas.width - x)
      var wrapbox = new(CSSBox)
      wrapbox.content = box.content.substr(l, l + wraplen)
      box.children.add(wrapbox)
      l += wraplen
      x += wrapwidth
      if wrap:
        inc y
        x = 0

    x += box.props.marginright.cells()
    y += box.props.marginbottom.cells()
    box.marginEdge.x2 = x
    box.marginEdge.y2 = y

    var i = box.children.len - 1
    while i >= 0:
      stack.add(box.children[i])
      i -= 1
