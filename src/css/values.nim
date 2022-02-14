import unicode
import tables
import sugar
import sequtils
import options
import macros
import strutils

import css/parser
import css/selparser
import io/term
import types/color
import utils/twtstr

export selparser.PseudoElem

type
  CSSUnit* = enum
    UNIT_CM, UNIT_MM, UNIT_IN, UNIT_PX, UNIT_PT, UNIT_PC,
    UNIT_EM, UNIT_EX, UNIT_CH, UNIT_REM, UNIT_VW, UNIT_VH, UNIT_VMIN,
    UNIT_VMAX, UNIT_PERC, UNIT_IC

  CSSPropertyType* = enum
    PROPERTY_NONE, PROPERTY_ALL, PROPERTY_COLOR, PROPERTY_MARGIN,
    PROPERTY_MARGIN_TOP, PROPERTY_MARGIN_LEFT, PROPERTY_MARGIN_RIGHT,
    PROPERTY_MARGIN_BOTTOM, PROPERTY_FONT_STYLE, PROPERTY_DISPLAY,
    PROPERTY_CONTENT, PROPERTY_WHITE_SPACE, PROPERTY_FONT_WEIGHT,
    PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK, PROPERTY_WIDTH,
    PROPERTY_HEIGHT, PROPERTY_LIST_STYLE_TYPE, PROPERTY_PADDING,
    PROPERTY_PADDING_TOP, PROPERTY_PADDING_LEFT, PROPERTY_PADDING_RIGHT,
    PROPERTY_PADDING_BOTTOM, PROPERTY_WORD_SPACING, PROPERTY_VERTICAL_ALIGN,
    PROPERTY_LINE_HEIGHT, PROPERTY_TEXT_ALIGN, PROPERTY_LIST_STYLE_POSITION,
    PROPERTY_BACKGROUND_COLOR

  CSSValueType* = enum
    VALUE_NONE, VALUE_LENGTH, VALUE_COLOR, VALUE_CONTENT, VALUE_DISPLAY,
    VALUE_FONT_STYLE, VALUE_WHITE_SPACE, VALUE_INTEGER, VALUE_TEXT_DECORATION,
    VALUE_WORD_BREAK, VALUE_LIST_STYLE_TYPE, VALUE_VERTICAL_ALIGN,
    VALUE_TEXT_ALIGN, VALUE_LIST_STYLE_POSITION

  CSSGlobalValueType* = enum
    VALUE_NOGLOBAL, VALUE_INITIAL, VALUE_INHERIT, VALUE_REVERT, VALUE_UNSET

  CSSDisplay* = enum
    DISPLAY_NONE, DISPLAY_INLINE, DISPLAY_BLOCK, DISPLAY_LIST_ITEM,
    DISPLAY_INLINE_BLOCK, DISPLAY_TABLE, DISPLAY_TABLE_ROW_GROUP,
    DISPLAY_TABLE_HEADER_GROUP, DISPLAY_TABLE_FOOTER_GROUP,
    DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_ROW, DISPLAY_TABLE_COLUMN,
    DISPLAY_TABLE_CELL

  CSSWhitespace* = enum
    WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE, WHITESPACE_PRE_LINE,
    WHITESPACE_PRE_WRAP

  CSSFontStyle* = enum
    FONTSTYLE_NORMAL, FONTSTYLE_ITALIC, FONTSTYLE_OBLIQUE

  CSSPosition* = enum
    POSITION_STATIC, POSITION_RELATIVE, POSITION_ABSOLUTE, POSITION_FIXED,
    POSITION_INHERIT

  CSSTextDecoration* = enum
    TEXT_DECORATION_NONE, TEXT_DECORATION_UNDERLINE, TEXT_DECORATION_OVERLINE,
    TEXT_DECORATION_LINE_THROUGH, TEXT_DECORATION_BLINK

  CSSWordBreak* = enum
    WORD_BREAK_NORMAL, WORD_BREAK_BREAK_ALL, WORD_BREAK_KEEP_ALL

  CSSListStyleType* = enum
    LIST_STYLE_TYPE_NONE, LIST_STYLE_TYPE_DISC, LIST_STYLE_TYPE_CIRCLE,
    LIST_STYLE_TYPE_SQUARE, LIST_STYLE_TYPE_DECIMAL,
    LIST_STYLE_TYPE_LOWER_ROMAN, LIST_STYLE_TYPE_UPPER_ROMAN,
    LIST_STYLE_TYPE_JAPANESE_INFORMAL

  CSSVerticalAlign2* = enum
    VERTICAL_ALIGN_BASELINE, VERTICAL_ALIGN_SUB, VERTICAL_ALIGN_SUPER,
    VERTICAL_ALIGN_TEXT_TOP, VERTICAL_ALIGN_TEXT_BOTTOM, VERTICAL_ALIGN_MIDDLE,
    VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM

  CSSTextAlign* = enum
    TEXT_ALIGN_START, TEXT_ALIGN_END, TEXT_ALIGN_LEFT, TEXT_ALIGN_RIGHT,
    TEXT_ALIGN_CENTER, TEXT_ALIGN_JUSTIFY, TEXT_ALIGN_MOZ_CENTER

  CSSListStylePosition* = enum
    LIST_STYLE_POSITION_OUTSIDE, LIST_STYLE_POSITION_INSIDE

type
  CSSLength* = object
    num*: float64
    unit*: CSSUnit
    auto*: bool

  CSSColor* = object
    rgba*: RGBAColor
    termcolor: int

  CSSVerticalAlign* = object
    length*: CSSLength
    keyword*: CSSVerticalAlign2
  
  CSSSpecifiedValue* = ref object
    t*: CSSPropertyType
    case v: CSSValueType
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
    of VALUE_LIST_STYLE_TYPE:
      liststyletype*: CSSListStyleType
    of VALUE_VERTICAL_ALIGN:
      verticalalign*: CSSVerticalAlign
    of VALUE_TEXT_ALIGN:
      textalign*: CSSTextAlign
    of VALUE_LIST_STYLE_POSITION:
      liststyleposition*: CSSListStylePosition
    of VALUE_NONE: discard

  CSSSpecifiedValues* = ref array[CSSPropertyType, CSSSpecifiedValue]

  CSSValueError* = object of ValueError

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
  "list-style-type": PROPERTY_LIST_STYLE_TYPE,
  "padding": PROPERTY_PADDING,
  "padding-top": PROPERTY_PADDING_TOP,
  "padding-bottom": PROPERTY_PADDING_BOTTOM,
  "padding-left": PROPERTY_PADDING_LEFT,
  "padding-right": PROPERTY_PADDING_RIGHT,
  "word-spacing": PROPERTY_WORD_SPACING,
  "vertical-align": PROPERTY_VERTICAL_ALIGN,
  "line-height": PROPERTY_LINE_HEIGHT,
  "text-align": PROPERTY_TEXT_ALIGN,
  "list-style-position": PROPERTY_LIST_STYLE_POSITION,
  "background-color": PROPERTY_BACKGROUND_COLOR,
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
  PROPERTY_LIST_STYLE_TYPE: VALUE_LIST_STYLE_TYPE,
  PROPERTY_PADDING: VALUE_LENGTH,
  PROPERTY_PADDING_TOP: VALUE_LENGTH,
  PROPERTY_PADDING_LEFT: VALUE_LENGTH,
  PROPERTY_PADDING_RIGHT: VALUE_LENGTH,
  PROPERTY_PADDING_BOTTOM: VALUE_LENGTH,
  PROPERTY_WORD_SPACING: VALUE_LENGTH,
  PROPERTY_VERTICAL_ALIGN: VALUE_VERTICAL_ALIGN,
  PROPERTY_LINE_HEIGHT: VALUE_LENGTH,
  PROPERTY_TEXT_ALIGN: VALUE_TEXT_ALIGN,
  PROPERTY_LIST_STYLE_POSITION: VALUE_LIST_STYLE_POSITION,
  PROPERTY_BACKGROUND_COLOR: VALUE_COLOR,
]

const InheritedProperties = {
  PROPERTY_COLOR, PROPERTY_FONT_STYLE, PROPERTY_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK,
  PROPERTY_LIST_STYLE_TYPE, PROPERTY_WORD_SPACING, PROPERTY_LINE_HEIGHT,
  PROPERTY_TEXT_ALIGN, PROPERTY_LIST_STYLE_POSITION, PROPERTY_BACKGROUND_COLOR
}

func getPropInheritedArray(): array[CSSPropertyType, bool] =
  for prop in CSSPropertyType:
    if prop in InheritedProperties:
      result[prop] = true
    else:
      result[prop] = false

const InheritedArray = getPropInheritedArray()

func propertyType(s: string): CSSPropertyType =
  return PropertyNames.getOrDefault(s, PROPERTY_NONE)

func valueType(prop: CSSPropertyType): CSSValueType =
  return ValueTypes[prop]

macro `{}`*(vals: CSSSpecifiedValues, s: string): untyped =
  let t = propertyType($s)
  let vs = $valueType(t)
  let s = vs.split(Rune('_'))[1..^1].join("_").tolower()
  result = newDotExpr(newTree(nnkBracketExpr, vals, newLit(t)), newIdentNode(s))

macro `{}=`*(vals: CSSSpecifiedValues, s: string, v: typed): untyped =
  let t = propertyType($s)
  let vs = $valueType(t)
  let s = vs.split(Rune('_'))[1..^1].join("_").tolower()
  let expr = newDotExpr(newTree(nnkBracketExpr, vals, newLit(t)), newIdentNode(s))
  result = quote do:
    `expr` = `v`

func inherited(t: CSSPropertyType): bool =
  return InheritedArray[t]

func px(n: float64, d: int): int {.inline.} =
  return int(n / float(d))

func cells*(l: CSSLength, d: int, term: TermAttributes, p: Option[int], o: bool): int =
  let w = term.width_px
  let h = term.height_px
  case l.unit
  of UNIT_EM, UNIT_REM:
    if o: int(l.num * term.cell_ratio) #horizontal
    else: int(l.num) #vertical
  of UNIT_CH:
    if o: int(l.num) #horizontal
    else: int(l.num / term.cell_ratio) #vertical
  of UNIT_IC:
    if o: int(l.num * term.cell_ratio) #horizontal
    else: int(l.num) #vertical
  of UNIT_EX: # x-letter height, we assume it's em/2
    if o: int(l.num / 2) #horizontal
    else: int(l.num / term.cell_ratio / 2) #vertical
  of UNIT_PERC: int(p.get / 100 * l.num)
  of UNIT_PX: px(l.num, d)
  of UNIT_CM: px(l.num * 37.8, d)
  of UNIT_MM: px(l.num * 3.78, d)
  of UNIT_IN: px(l.num * 96, d)
  of UNIT_PC: px(l.num * 96 / 6, d)
  of UNIT_PT: px(l.num * 96 / 72, d)
  of UNIT_VW: px(w / 100 * l.num, d)
  of UNIT_VH: px(h / 100 * l.num, d)
  of UNIT_VMIN: px(min(w, h) / 100 * l.num, d)
  of UNIT_VMAX: px(max(w, h) / 100 * l.num, d)

func em_to_px(em: float64, term: TermAttributes): int =
  int(em * float64(term.ppl))

func ch_to_px(ch: float64, term: TermAttributes): int =
  int(ch * float64(term.ppc))

# 水 width, we assume it's 2 chars
func ic_to_px(ic: float64, term: TermAttributes): int =
  int(ic * float64(term.ppc) * 2)

# x-letter height, we assume it's em/2
func ex_to_px(ex: float64, term: TermAttributes): int =
  int(ex * float64(term.ppc) / 2)

func px*(l: CSSLength, term: TermAttributes, p: int): int {.inline.} =
  case l.unit
  of UNIT_EM, UNIT_REM: em_to_px(l.num, term)
  of UNIT_CH: ch_to_px(l.num, term)
  of UNIT_IC: ic_to_px(l.num, term)
  of UNIT_EX: ex_to_px(l.num, term)
  of UNIT_PERC: int(p / 100 * l.num)
  of UNIT_PX: int(l.num)
  of UNIT_CM: int(l.num * 37.8)
  of UNIT_MM: int(l.num * 3.78)
  of UNIT_IN: int(l.num * 96)
  of UNIT_PC: int(l.num * 96 / 6)
  of UNIT_PT: int(l.num * 96 / 72)
  of UNIT_VW: int(term.width_px / 100 * l.num)
  of UNIT_VH: int(term.height_px / 100 * l.num)
  of UNIT_VMIN: int(min(term.width_px, term.width_px) / 100 * l.num)
  of UNIT_VMAX: int(max(term.width_px, term.width_px) / 100 * l.num)

func listMarker*(t: CSSListStyleType, i: int): string =
  case t
  of LIST_STYLE_TYPE_NONE: return ""
  of LIST_STYLE_TYPE_DISC: return "• "
  of LIST_STYLE_TYPE_CIRCLE: return "○ "
  of LIST_STYLE_TYPE_SQUARE: return "□ "
  of LIST_STYLE_TYPE_DECIMAL: return $i & ". "
  of LIST_STYLE_TYPE_UPPER_ROMAN: return romanNumber(i) & ". "
  of LIST_STYLE_TYPE_LOWER_ROMAN: return romanNumber_lower(i) & ". "
  of LIST_STYLE_TYPE_JAPANESE_INFORMAL: return japaneseNumber(i) & "、"

const ColorsRGB = {
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

const Colors: Table[string, CSSColor] = ((func (): Table[string, CSSColor] =
  for name, rgb in ColorsRGB:
    result[name] = CSSColor(rgba: rgb)
  result["transparent"] = CSSColor(rgba: rgba(0x00, 0x00, 0x00, 0x00))
)())

const Units = {
  "%": UNIT_PERC,
  "cm": UNIT_CM,
  "mm": UNIT_MM,
  "in": UNIT_IN,
  "px": UNIT_PX,
  "pt": UNIT_PT,
  "pc": UNIT_PC,
  "em": UNIT_EM,
  "ex": UNIT_EX,
  "ch": UNIT_CH,
  "ic": UNIT_CH,
  "rem": UNIT_REM,
  "vw": UNIT_VW,
  "vh": UNIT_VH,
  "vmin": UNIT_VMIN,
  "vmax": UNIT_VMAX,
}.toTable()

func cssLength(val: float64, unit: string): CSSLength =
  if unit in Units:
    CSSLength(num: val, unit: Units[unit])
  else:
    raise newException(CSSValueError, "Invalid unit")

func color(r, g, b: int): CSSColor =
  return CSSColor(rgba: rgba(r, g, b, 256))

func color(r, g, b, a: int): CSSColor =
  return CSSColor(rgba: rgba(r, g, b, a))

func cssColor(d: CSSDeclaration): CSSColor =
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
        if $s in Colors:
          return Colors[$s]
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
  return CellColor(rgb: true, rgbcolor: RGBColor(color.rgba))

func isToken(d: CSSDeclaration): bool {.inline.} = d.value.len > 0 and d.value[0] of CSSToken

func cssLength(d: CSSDeclaration): CSSLength =
  if isToken(d):
    let tok = CSSToken(d.value[0])
    case tok.tokenType
    of CSS_PERCENTAGE_TOKEN:
      return cssLength(tok.nvalue, "%")
    of CSS_DIMENSION_TOKEN:
      return cssLength(tok.nvalue, $tok.unit)
    of CSS_IDENT_TOKEN:
      if $tok.value == "auto":
        return CSSLength(auto: true)
    else: discard
  raise newException(CSSValueError, "Invalid length")

func cssWordSpacing(d: CSSDeclaration): CSSLength =
  if isToken(d):
    let tok = CSSToken(d.value[0])
    case tok.tokenType
    of CSS_DIMENSION_TOKEN:
      return cssLength(tok.nvalue, $tok.unit)
    of CSS_IDENT_TOKEN:
      if $tok.value == "normal":
        return CSSLength(auto: true)
    else: discard
  raise newException(CSSValueError, "Invalid word spacing")

func getToken(d: CSSDeclaration): CSSToken = (CSSToken)d.value[0]

func cssGlobal*(d: CSSDeclaration): CSSGlobalValueType =
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
      of "list-item": return DISPLAY_LIST_ITEM
      of "inline-block": return DISPLAY_INLINE_BLOCK
      # of "table": return DISPLAY_TABLE
      # of "table-row": return DISPLAY_TABLE_ROW
      # of "table-cell": return DISPLAY_TABLE_CELL
      # of "table-column": return DISPLAY_TABLE_COLUMN
      # of "table-row-group": return DISPLAY_TABLE_ROW_GROUP
      # of "table-header-group": return DISPLAY_TABLE_HEADER_GROUP
      # of "table-footer-group": return DISPLAY_TABLE_FOOTER_GROUP
      # of "table-column-group": return DISPLAY_TABLE_COLUMN_GROUP
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
      of "none": return TEXT_DECORATION_NONE
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

func cssListStyleType(d: CSSDeclaration): CSSListStyleType =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "none": return LIST_STYLE_TYPE_NONE
      of "disc": return LIST_STYLE_TYPE_DISC
      of "circle": return LIST_STYLE_TYPE_CIRCLE
      of "square": return LIST_STYLE_TYPE_SQUARE
      of "decimal": return LIST_STYLE_TYPE_DECIMAL
      of "upper-roman": return LIST_STYLE_TYPE_UPPER_ROMAN
      of "lower-roman": return LIST_STYLE_TYPE_LOWER_ROMAN
      of "japanese-informal": return LIST_STYLE_TYPE_JAPANESE_INFORMAL
  raise newException(CSSValueError, "Invalid list style")

func cssVerticalAlign(d: CSSDeclaration): CSSVerticalAlign =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case $tok.value
      of "baseline": result.keyword = VERTICAL_ALIGN_BASELINE
      of "sub": result.keyword = VERTICAL_ALIGN_SUB
      of "super": result.keyword = VERTICAL_ALIGN_SUPER
      of "text-top": result.keyword = VERTICAL_ALIGN_TEXT_BOTTOM
      of "middle": result.keyword = VERTICAL_ALIGN_MIDDLE
      of "top": result.keyword = VERTICAL_ALIGN_TOP
      of "bottom": result.keyword = VERTICAL_ALIGN_BOTTOM
      else:
        raise newException(CSSValueError, "Invalid vertical align")
      return result
    else:
      result.keyword = VERTICAL_ALIGN_BASELINE
      result.length = cssLength(d)
      return result
  raise newException(CSSValueError, "Invalid vertical align")

func cssLineHeight(d: CSSDeclaration): CSSLength =
  if isToken(d):
    let tok = CSSToken(d.value[0])
    case tok.tokenType
    of CSS_NUMBER_TOKEN:
      return cssLength(tok.nvalue * 100, "%")
    of CSS_IDENT_TOKEN:
      if $tok.value == "normal":
        return CSSLength(auto: true)
    else:
      return cssLength(d)
  raise newException(CSSValueError, "Invalid line height")

func cssTextAlign(d: CSSDeclaration): CSSTextAlign =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      return case $tok.value
      of "start": TEXT_ALIGN_START
      of "end": TEXT_ALIGN_END
      of "left": TEXT_ALIGN_LEFT
      of "right": TEXT_ALIGN_RIGHT
      of "center": TEXT_ALIGN_CENTER
      of "justify": TEXT_ALIGN_JUSTIFY
      of "-moz-center": TEXT_ALIGN_MOZ_CENTER
      else: raise newException(CSSValueError, "Invalid text align")
  raise newException(CSSValueError, "Invalid text align")

func cssListStylePosition(d: CSSDeclaration): CSSListStylePosition =
  if isToken(d):
    let tok = getToken(d)
    if tok.tokenType == CSS_IDENT_TOKEN:
      return case $tok.value
      of "outside": LIST_STYLE_POSITION_OUTSIDE
      of "inside": LIST_STYLE_POSITION_INSIDE
      else: raise newException(CSSValueError, "Invalid list style position")
  raise newException(CSSValueError, "Invalid list style position")

proc getValueFromDecl(val: CSSSpecifiedValue, d: CSSDeclaration, vtype: CSSValueType, ptype: CSSPropertyType) =
  case vtype
  of VALUE_COLOR: val.color = cssColor(d)
  of VALUE_LENGTH:
    case ptype
    of PROPERTY_WORD_SPACING:
      val.length = cssWordSpacing(d)
    of PROPERTY_LINE_HEIGHT:
      val.length = cssLineHeight(d)
    else:
      val.length = cssLength(d)
  of VALUE_FONT_STYLE: val.fontstyle = cssFontStyle(d)
  of VALUE_DISPLAY: val.display = cssDisplay(d)
  of VALUE_CONTENT: val.content = cssString(d)
  of VALUE_WHITE_SPACE: val.whitespace = cssWhiteSpace(d)
  of VALUE_INTEGER:
    if ptype == PROPERTY_FONT_WEIGHT:
      val.integer = cssFontWeight(d)
  of VALUE_TEXT_DECORATION: val.textdecoration = cssTextDecoration(d)
  of VALUE_WORD_BREAK: val.wordbreak = cssWordBreak(d)
  of VALUE_LIST_STYLE_TYPE: val.liststyletype = cssListStyleType(d)
  of VALUE_VERTICAL_ALIGN: val.verticalalign = cssVerticalAlign(d)
  of VALUE_TEXT_ALIGN: val.textalign = cssTextAlign(d)
  of VALUE_LIST_STYLE_POSITION: val.liststyleposition = cssListStylePosition(d)
  of VALUE_NONE: discard

func getInitialColor(t: CSSPropertyType): CSSColor =
  case t
  of PROPERTY_COLOR:
    return Colors["white"]
  of PROPERTY_BACKGROUND_COLOR:
    return Colors["transparent"]
  else:
    return Colors["black"]

func getInitialLength(t: CSSPropertyType): CSSLength =
  case t
  of PROPERTY_WIDTH, PROPERTY_HEIGHT, PROPERTY_WORD_SPACING, PROPERTY_LINE_HEIGHT:
    return CSSLength(auto: true)
  else:
    return CSSLength()

func calcInitial(t: CSSPropertyType): CSSSpecifiedValue =
  let v = valueType(t)
  var nv: CSSSpecifiedValue
  case v
  of VALUE_COLOR:
    nv = CSSSpecifiedValue(t: t, v: v, color: getInitialColor(t))
  of VALUE_DISPLAY:
    nv = CSSSpecifiedValue(t: t, v: v, display: DISPLAY_INLINE)
  of VALUE_WORD_BREAK:
    nv = CSSSpecifiedValue(t: t, v: v, wordbreak: WORD_BREAK_NORMAL)
  of VALUE_LENGTH:
    nv = CSSSpecifiedValue(t: t, v: v, length: getInitialLength(t))
  else:
    nv = CSSSpecifiedValue(t: t, v: v)
  return nv

func getInitialTable(): array[CSSPropertyType, CSSSpecifiedValue] =
  for i in low(result)..high(result):
    result[i] = calcInitial(i)

let defaultTable = getInitialTable()

func getDefault(t: CSSPropertyType): CSSSpecifiedValue = {.cast(noSideEffect).}:
  assert defaultTable[t] != nil
  return defaultTable[t]

func getSpecifiedValue(d: CSSDeclaration, parent: CSSSpecifiedValues): tuple[a:CSSSpecifiedValue,b:CSSGlobalValueType] =
  let name = $d.name
  let ptype = propertyType(name)
  let vtype = valueType(ptype)

  var val = CSSSpecifiedValue(t: ptype, v: vtype)
  try:
    val.getValueFromDecl(d, vtype, ptype)
  except CSSValueError:
    val = getDefault(ptype)

  return (val, cssGlobal(d))

func equals*(a, b: CSSSpecifiedValue): bool =
  if a == b:
    return true
  if a == nil or b == nil:
    return false
  case valueType(a.t)
  of VALUE_COLOR: return a.color == b.color
  of VALUE_LENGTH: return a.length == b.length
  of VALUE_FONT_STYLE: return a.fontstyle == b.fontstyle
  of VALUE_DISPLAY: return a.display == b.display
  of VALUE_CONTENT: return a.content == b.content
  of VALUE_WHITESPACE: return a.whitespace == b.whitespace
  of VALUE_INTEGER: return a.integer == a.integer
  of VALUE_TEXT_DECORATION: return a.textdecoration == b.textdecoration
  of VALUE_WORD_BREAK: return a.wordbreak == b.wordbreak
  of VALUE_LIST_STYLE_TYPE: return a.liststyletype == b.liststyletype
  of VALUE_VERTICAL_ALIGN: return a.verticalalign == b.verticalalign
  of VALUE_TEXT_ALIGN: return a.textalign == b.textalign
  of VALUE_LIST_STYLE_POSITION: return a.liststyleposition == b.liststyleposition
  of VALUE_NONE: return true
  return false

proc applyValue(vals, parent: CSSSpecifiedValues, t: CSSPropertyType, val: CSSSpecifiedValue, global: CSSGlobalValueType) =
  case global
  of VALUE_INHERIT, VALUE_UNSET:
    if inherited(t):
      if parent[t] != nil:
        vals[t] = parent[t]
    vals[t] = getDefault(t)
  of VALUE_INITIAL:
    vals[t] = getDefault(t)
  of VALUE_REVERT:
    vals[t] = getDefault(t) #TODO
  of VALUE_NOGLOBAL:
    vals[t] = val

proc applyValue*(vals, parent: CSSSpecifiedValues, d: CSSDeclaration) =
  let vv = getSpecifiedValue(d, parent)
  let val = vv.a
  case val.t
  of PROPERTY_ALL:
    let global = cssGlobal(d)
    if global != VALUE_NOGLOBAL:
      for t in CSSPropertyType:
        vals.applyValue(parent, t, nil, global)
  of PROPERTY_MARGIN:
    let left = CSSSpecifiedValue(t: PROPERTY_MARGIN_LEFT, v: VALUE_LENGTH, length: val.length)
    let right = CSSSpecifiedValue(t: PROPERTY_MARGIN_RIGHT, v: VALUE_LENGTH, length: val.length)
    let top = CSSSpecifiedValue(t: PROPERTY_MARGIN_TOP, v: VALUE_LENGTH, length: val.length)
    let bottom = CSSSpecifiedValue(t: PROPERTY_MARGIN_BOTTOM, v: VALUE_LENGTH, length: val.length)
    for val in [left, right, top, bottom]:
      vals.applyValue(parent, val.t, val, vv.b)
  of PROPERTY_PADDING:
    let left = CSSSpecifiedValue(t: PROPERTY_PADDING_LEFT, v: VALUE_LENGTH, length: val.length)
    let right = CSSSpecifiedValue(t: PROPERTY_PADDING_RIGHT, v: VALUE_LENGTH, length: val.length)
    let top = CSSSpecifiedValue(t: PROPERTY_PADDING_TOP, v: VALUE_LENGTH, length: val.length)
    let bottom = CSSSpecifiedValue(t: PROPERTY_PADDING_BOTTOM, v: VALUE_LENGTH, length: val.length)
    for val in [left, right, top, bottom]:
      vals.applyValue(parent, val.t, val, vv.b)
  else:
    vals.applyValue(parent, val.t, vv.a, vv.b)

func inheritProperties*(parent: CSSSpecifiedValues): CSSSpecifiedValues =
  new(result)
  for prop in CSSPropertyType:
    if inherited(prop) and parent[prop] != nil:
      result[prop] = parent[prop]
    else:
      result[prop] = getDefault(prop)

func copyProperties*(parent: CSSSpecifiedValues): CSSSpecifiedValues =
  new(result)
  for prop in CSSPropertyType:
    result[prop] = parent[prop]

func rootProperties*(): CSSSpecifiedValues =
  new(result)
  for prop in CSSPropertyType:
    result[prop] = getDefault(prop)
