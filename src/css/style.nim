import streams
import unicode
import terminal
import tables

import ../io/twtio

import ../utils/twtstr

import ../types/enums

import cssparser

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
    italic*: bool
    underscore*: bool
    islink*: bool
    selected*: bool
    indent*: int
    color*: CSSColor
    position*: CSSPosition

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
    color*: CSSColor
    props*: CSS2Properties
    content*: seq[Rune]
    dispcontent*: string
    children*: seq[CSSBox]

  CSSColor* = tuple[r: uint8, g: uint8, b: uint8, a: uint8]

func `+`(a: CSSRect, b: CSSRect): CSSRect =
  result.x1 = a.x1 + b.x1
  result.y1 = a.y1 + b.y1
  result.x2 = a.x2 + b.x2
  result.y2 = a.y2 + b.y2

proc `+=`(a: var CSSRect, b: CSSRect) =
  a = a + b

func cells(l: CSSLength): int =
  case l.unit
  of EM_UNIT:
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
  of "%": return CSSLength(num: val, unit: PERC_UNIT)
  of "cm": return CSSLength(num: val, unit: CM_UNIT)
  of "mm": return CSSLength(num: val, unit: MM_UNIT)
  of "in": return CSSLength(num: val, unit: IN_UNIT)
  of "px": return CSSLength(num: val, unit: PX_UNIT)
  of "pt": return CSSLength(num: val, unit: PT_UNIT)
  of "pc": return CSSLength(num: val, unit: PC_UNIT)
  of "em": return CSSLength(num: val, unit: EM_UNIT)
  of "ex": return CSSLength(num: val, unit: EX_UNIT)
  of "ch": return CSSLength(num: val, unit: CH_UNIT)
  of "rem": return CSSLength(num: val, unit: REM_UNIT)
  of "vw": return CSSLength(num: val, unit: VW_UNIT)
  of "vh": return CSSLength(num: val, unit: VH_UNIT)
  of "vmin": return CSSLength(num: val, unit: VMIN_UNIT)
  of "vmax": return CSSLength(num: val, unit: VMAX_UNIT)
  else: return CSSLength(num: 0, unit: EM_UNIT)

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
    elif d of CSSFunction:
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
        return CSSLength(num: 0, unit: EM_UNIT, auto: true)
    else:
      return CSSLength(num: 0, unit: EM_UNIT)

  return CSSLength(num: 0, unit: EM_UNIT)

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

proc applyProperties*(box: CSSBox, s: string) =
  let decls = parseCSSListOfDeclarations(newStringStream(s))
  if box.props == nil:
    box.props = CSS2Properties()
  let props = box.props

  for item in decls:
    if item of CSSDeclaration:
      let d = CSSDeclaration(item)
      case $d.name
      of "color":
        props.color = cssColor(d)
        eprint props.color #TODO
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
