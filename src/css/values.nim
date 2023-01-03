import tables
import macros
import options
import strutils
import unicode

import css/cssparser
import css/selectorparser
import io/window
import types/color
import utils/twtstr

export selectorparser.PseudoElem

type
  CSSShorthandType = enum
    SHORTHAND_NONE, SHORTHAND_ALL, SHORTHAND_MARGIN, SHORTHAND_PADDING,
    SHORTHAND_BACKGROUND, SHORTHAND_LIST_STYLE

  CSSUnit* = enum
    UNIT_CM, UNIT_MM, UNIT_IN, UNIT_PX, UNIT_PT, UNIT_PC,
    UNIT_EM, UNIT_EX, UNIT_CH, UNIT_REM, UNIT_VW, UNIT_VH, UNIT_VMIN,
    UNIT_VMAX, UNIT_PERC, UNIT_IC

  CSSPropertyType* = enum
    PROPERTY_NONE, PROPERTY_COLOR, PROPERTY_MARGIN_TOP, PROPERTY_MARGIN_LEFT,
    PROPERTY_MARGIN_RIGHT, PROPERTY_MARGIN_BOTTOM, PROPERTY_FONT_STYLE,
    PROPERTY_DISPLAY, PROPERTY_CONTENT, PROPERTY_WHITE_SPACE,
    PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK,
    PROPERTY_WIDTH, PROPERTY_HEIGHT, PROPERTY_LIST_STYLE_TYPE,
    PROPERTY_PADDING_TOP, PROPERTY_PADDING_LEFT, PROPERTY_PADDING_RIGHT,
    PROPERTY_PADDING_BOTTOM, PROPERTY_WORD_SPACING, PROPERTY_VERTICAL_ALIGN,
    PROPERTY_LINE_HEIGHT, PROPERTY_TEXT_ALIGN, PROPERTY_LIST_STYLE_POSITION,
    PROPERTY_BACKGROUND_COLOR, PROPERTY_POSITION, PROPERTY_LEFT,
    PROPERTY_RIGHT, PROPERTY_TOP, PROPERTY_BOTTOM, PROPERTY_CAPTION_SIDE,
    PROPERTY_BORDER_SPACING, PROPERTY_BORDER_COLLAPSE, PROPERTY_QUOTES,
    PROPERTY_COUNTER_RESET, PROPERTY_MAX_WIDTH, PROPERTY_MAX_HEIGHT,
    PROPERTY_MIN_WIDTH, PROPERTY_MIN_HEIGHT, PROPERTY_BACKGROUND_IMAGE,
    PROPERTY_CHA_COLSPAN, PROPERTY_CHA_ROWSPAN

  CSSValueType* = enum
    VALUE_NONE, VALUE_LENGTH, VALUE_COLOR, VALUE_CONTENT, VALUE_DISPLAY,
    VALUE_FONT_STYLE, VALUE_WHITE_SPACE, VALUE_INTEGER, VALUE_TEXT_DECORATION,
    VALUE_WORD_BREAK, VALUE_LIST_STYLE_TYPE, VALUE_VERTICAL_ALIGN,
    VALUE_TEXT_ALIGN, VALUE_LIST_STYLE_POSITION, VALUE_POSITION,
    VALUE_CAPTION_SIDE, VALUE_LENGTH2, VALUE_BORDER_COLLAPSE, VALUE_QUOTES,
    VALUE_COUNTER_RESET, VALUE_IMAGE

  CSSGlobalValueType* = enum
    VALUE_NOGLOBAL, VALUE_INITIAL, VALUE_INHERIT, VALUE_REVERT, VALUE_UNSET

  CSSDisplay* = enum
    DISPLAY_NONE, DISPLAY_INLINE, DISPLAY_BLOCK, DISPLAY_LIST_ITEM,
    DISPLAY_INLINE_BLOCK, DISPLAY_TABLE, DISPLAY_INLINE_TABLE,
    DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP,
    DISPLAY_TABLE_FOOTER_GROUP, DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_ROW,
    DISPLAY_TABLE_COLUMN, DISPLAY_TABLE_CELL, DISPLAY_TABLE_CAPTION

  CSSWhitespace* = enum
    WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE, WHITESPACE_PRE_LINE,
    WHITESPACE_PRE_WRAP

  CSSFontStyle* = enum
    FONTSTYLE_NORMAL, FONTSTYLE_ITALIC, FONTSTYLE_OBLIQUE

  CSSPosition* = enum
    POSITION_STATIC, POSITION_RELATIVE, POSITION_ABSOLUTE, POSITION_FIXED,
    POSITION_STICKY

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
    TEXT_ALIGN_CENTER, TEXT_ALIGN_JUSTIFY, TEXT_ALIGN_CHA_CENTER,
    TEXT_ALIGN_CHA_LEFT, TEXT_ALIGN_CHA_RIGHT

  CSSListStylePosition* = enum
    LIST_STYLE_POSITION_OUTSIDE, LIST_STYLE_POSITION_INSIDE

  CSSCaptionSide* = enum
    CAPTION_SIDE_TOP, CAPTION_SIDE_BOTTOM, CAPTION_SIDE_LEFT,
    CAPTION_SIDE_RIGHT, CAPTION_SIDE_BLOCK_START, CAPTION_SIDE_BLOCK_END,
    CAPTION_SIDE_INLINE_START, CAPTION_SIDE_INLINE_END

  CSSBorderCollapse* = enum
    BORDER_COLLAPSE_SEPARATE, BORDER_COLLAPSE_COLLAPSE

  CSSContentType* = enum
    CONTENT_STRING, CONTENT_OPEN_QUOTE, CONTENT_CLOSE_QUOTE,
    CONTENT_NO_OPEN_QUOTE, CONTENT_NO_CLOSE_QUOTE, CONTENT_IMAGE,
    CONTENT_NEWLINE

const RowGroupBox* = {DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP,
                      DISPLAY_TABLE_FOOTER_GROUP}
const ProperTableChild* = {DISPLAY_TABLE_ROW, DISPLAY_TABLE_COLUMN,
                           DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_CAPTION} +
                           RowGroupBox
const ProperTableRowParent* = {DISPLAY_TABLE, DISPLAY_INLINE_TABLE} + RowGroupBox
const InternalTableBox* = {DISPLAY_TABLE_CELL, DISPLAY_TABLE_ROW,
                           DISPLAY_TABLE_COLUMN, DISPLAY_TABLE_COLUMN_GROUP} +
                           RowGroupBox
const TabularContainer* = {DISPLAY_TABLE_ROW} + ProperTableRowParent

type
  CSSLength* = object
    num*: float64
    unit*: CSSUnit
    auto*: bool

  CSSVerticalAlign* = object
    length*: CSSLength
    keyword*: CSSVerticalAlign2

  CSSContent* = object
    t*: CSSContentType
    s*: string

  CSSQuotes* = object
    auto*: bool
    qs*: seq[tuple[s, e: string]]

  CSSCounterReset* = object
    name*: string
    num*: int
  
  CSSComputedValue* = ref object
    t*: CSSPropertyType
    case v*: CSSValueType
    of VALUE_COLOR:
      color*: RGBAColor
    of VALUE_LENGTH:
      length*: CSSLength
    of VALUE_FONT_STYLE:
      fontstyle*: CSSFontStyle
    of VALUE_DISPLAY:
      display*: CSSDisplay
    of VALUE_CONTENT:
      content*: seq[CSSContent]
    of VALUE_QUOTES:
      quotes*: CSSQuotes
    of VALUE_WHITESPACE:
      whitespace*: CSSWhitespace
    of VALUE_INTEGER:
      integer*: int
    of VALUE_TEXT_DECORATION:
      textdecoration*: set[CSSTextDecoration]
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
    of VALUE_POSITION:
      position*: CSSPosition
    of VALUE_CAPTION_SIDE:
      captionside*: CSSCaptionSide
    of VALUE_LENGTH2:
      length2*: tuple[a, b: CSSLength]
    of VALUE_BORDER_COLLAPSE:
      bordercollapse*: CSSBorderCollapse
    of VALUE_COUNTER_RESET:
      counterreset*: seq[CSSCounterReset]
    of VALUE_IMAGE:
      image*: CSSContent
    of VALUE_NONE: discard

  CSSComputedValues* = ref array[CSSPropertyType, CSSComputedValue]

  CSSOrigin* = enum
    ORIGIN_USER_AGENT
    ORIGIN_USER
    ORIGIN_AUTHOR

  CSSComputedValueBuilder = object
    global: CSSGlobalValueType
    val: CSSComputedValue

  CSSComputedValueBuilders = seq[CSSComputedValueBuilder]

  CSSComputedValuesBuilder* = object
    parent: CSSComputedValues
    normalProperties: array[CSSOrigin, CSSComputedValueBuilders]
    importantProperties: array[CSSOrigin, CSSComputedValueBuilders]
    preshints*: CSSComputedValues

  CSSValueError* = object of ValueError

const ShorthandNames = {
  "all": SHORTHAND_ALL,
  "margin": SHORTHAND_MARGIN,
  "padding": SHORTHAND_PADDING,
  "background": SHORTHAND_BACKGROUND,
  "list-style": SHORTHAND_LIST_STYLE
}.toTable()

const PropertyNames = {
  "color": PROPERTY_COLOR,
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
  "position": PROPERTY_POSITION,
  "left": PROPERTY_LEFT,
  "right": PROPERTY_RIGHT,
  "top": PROPERTY_TOP,
  "bottom": PROPERTY_BOTTOM,
  "caption-side": PROPERTY_CAPTION_SIDE,
  "border-spacing": PROPERTY_BORDER_SPACING,
  "border-collapse": PROPERTY_BORDER_COLLAPSE,
  "quotes": PROPERTY_QUOTES,
  "counter-reset": PROPERTY_COUNTER_RESET,
  "max-width": PROPERTY_MAX_WIDTH,
  "max-height": PROPERTY_MAX_HEIGHT,
  "min-width": PROPERTY_MIN_WIDTH,
  "min-height": PROPERTY_MIN_HEIGHT,
  "background-image": PROPERTY_BACKGROUND_IMAGE,
  "-cha-colspan": PROPERTY_CHA_COLSPAN,
  "-cha-rowspan": PROPERTY_CHA_ROWSPAN
}.toTable()

const ValueTypes* = [
  PROPERTY_NONE: VALUE_NONE,
  PROPERTY_COLOR: VALUE_COLOR,
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
  PROPERTY_POSITION: VALUE_POSITION,
  PROPERTY_LEFT: VALUE_LENGTH,
  PROPERTY_RIGHT: VALUE_LENGTH,
  PROPERTY_TOP: VALUE_LENGTH,
  PROPERTY_BOTTOM: VALUE_LENGTH,
  PROPERTY_CAPTION_SIDE: VALUE_CAPTION_SIDE,
  PROPERTY_BORDER_SPACING: VALUE_LENGTH2,
  PROPERTY_BORDER_COLLAPSE: VALUE_BORDER_COLLAPSE,
  PROPERTY_QUOTES: VALUE_QUOTES,
  PROPERTY_COUNTER_RESET: VALUE_COUNTER_RESET,
  PROPERTY_MAX_WIDTH: VALUE_LENGTH,
  PROPERTY_MAX_HEIGHT: VALUE_LENGTH,
  PROPERTY_MIN_WIDTH: VALUE_LENGTH,
  PROPERTY_MIN_HEIGHT: VALUE_LENGTH,
  PROPERTY_BACKGROUND_IMAGE: VALUE_IMAGE,
  PROPERTY_CHA_COLSPAN: VALUE_INTEGER,
  PROPERTY_CHA_ROWSPAN: VALUE_INTEGER
]

const InheritedProperties = {
  PROPERTY_COLOR, PROPERTY_FONT_STYLE, PROPERTY_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK,
  PROPERTY_LIST_STYLE_TYPE, PROPERTY_WORD_SPACING, PROPERTY_LINE_HEIGHT,
  PROPERTY_TEXT_ALIGN, PROPERTY_LIST_STYLE_POSITION, PROPERTY_CAPTION_SIDE,
  PROPERTY_BORDER_SPACING, PROPERTY_BORDER_COLLAPSE, PROPERTY_QUOTES
}

func getPropInheritedArray(): array[CSSPropertyType, bool] =
  for prop in CSSPropertyType:
    if prop in InheritedProperties:
      result[prop] = true
    else:
      result[prop] = false

const InheritedArray = getPropInheritedArray()

func shorthandType(s: string): CSSShorthandType =
  return ShorthandNames.getOrDefault(s, SHORTHAND_NONE)

func propertyType(s: string): CSSPropertyType =
  return PropertyNames.getOrDefault(s, PROPERTY_NONE)

func valueType(prop: CSSPropertyType): CSSValueType =
  return ValueTypes[prop]

func `$`*(val: CSSComputedValue): string =
  result = ($val.t).toLowerAscii().split('_')[1..^1].join('-') & ": "
  case val.v
  of VALUE_COLOR:
    result &= $val.color
  else: discard

macro `{}`*(vals: CSSComputedValues, s: string): untyped =
  let t = propertyType($s)
  let vs = $valueType(t)
  let s = vs.split('_')[1..^1].join("_").tolower()
  result = newDotExpr(newTree(nnkBracketExpr, vals, newLit(t)), newIdentNode(s))

macro `{}=`*(vals: CSSComputedValues, s: string, val: typed) =
  let t = propertyType($s)
  let v = valueType(t)
  let vs = $v
  let s = vs.split('_')[1..^1].join("_").tolower()
  let id = ident(s)
  let expr = newTree(nnkBracketExpr, vals, newLit(t))
  result = quote do:
    `expr` = CSSComputedValue(t: CSSPropertyType(`t`), v: CSSValueType(`v`), `id`: `val`)

func inherited(t: CSSPropertyType): bool =
  return InheritedArray[t]

func em_to_px(em: float64, window: WindowAttributes): int =
  int(em * float64(window.ppl))

func ch_to_px(ch: float64, window: WindowAttributes): int =
  int(ch * float64(window.ppc))

# 水 width, we assume it's 2 chars
func ic_to_px(ic: float64, window: WindowAttributes): int =
  int(ic * float64(window.ppc) * 2)

# x-letter height, we assume it's em/2
func ex_to_px(ex: float64, window: WindowAttributes): int =
  int(ex * float64(window.ppc) / 2)

func px*(l: CSSLength, window: WindowAttributes, p: int): int {.inline.} =
  case l.unit
  of UNIT_EM, UNIT_REM: em_to_px(l.num, window)
  of UNIT_CH: ch_to_px(l.num, window)
  of UNIT_IC: ic_to_px(l.num, window)
  of UNIT_EX: ex_to_px(l.num, window)
  of UNIT_PERC: int(p / 100 * l.num)
  of UNIT_PX: int(l.num)
  of UNIT_CM: int(l.num * 37.8)
  of UNIT_MM: int(l.num * 3.78)
  of UNIT_IN: int(l.num * 96)
  of UNIT_PC: int(l.num * 96 / 6)
  of UNIT_PT: int(l.num * 96 / 72)
  of UNIT_VW: int(window.width_px / 100 * l.num)
  of UNIT_VH: int(window.height_px / 100 * l.num)
  of UNIT_VMIN: int(min(window.width_px, window.width_px) / 100 * l.num)
  of UNIT_VMAX: int(max(window.width_px, window.width_px) / 100 * l.num)

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

#TODO this should change by language
func quoteStart*(level: int): string =
  if level == 0:
    return "“"
  return "‘"

func quoteEnd*(level: int): string =
  if level == 0:
    return "“"
  return "‘"

const Colors: Table[string, RGBAColor] = ((func (): Table[string, RGBAColor] =
  for name, rgb in ColorsRGB:
    result[name] = rgb
  result["transparent"] = rgba(0x00, 0x00, 0x00, 0x00)
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

func parseDimensionValues*(s: string): Option[CSSLength] =
  if s == "": return
  var i = 0
  while s[i] in AsciiWhitespace: inc i
  if i >= s.len or s[i] notin AsciiDigit: return
  var n: float64
  while s[i] in AsciiDigit:
    n *= 10
    n += float64(decValue(s[i]))
    inc i
    if i >= s.len: return some(CSSLength(num: n, unit: UNIT_PX))
  if s[i] == '.':
    inc i
    if i >= s.len: return some(CSSLength(num: n, unit: UNIT_PX))
    var d = 1
    while i < s.len and s[i] in AsciiDigit:
      n += float64(decValue(s[i])) / float64(d)
      inc d
      inc i
  if i >= s.len: return some(CSSLength(num: n, unit: UNIT_PX))
  if s[i] == '%': return some(CSSLength(num: n, unit: UNIT_PERC))
  return some(CSSLength(num: n, unit: UNIT_PX))

func skipWhitespace(vals: seq[CSSComponentValue], i: var int) =
  while i < vals.len:
    if vals[i] != CSS_WHITESPACE_TOKEN:
      break
    inc i

func cssColor(val: CSSComponentValue): RGBAColor =
  if val of CSSToken:
    let tok = CSSToken(val)
    case tok.tokenType
    of CSS_HASH_TOKEN:
      let c = parseHexColor(tok.value)
      if c.isSome:
        return c.get
    of CSS_IDENT_TOKEN:
      let s = tok.value
      if s in Colors:
        return Colors[s]
    else: discard
  elif val of CSSFunction:
    let f = CSSFunction(val)
    var i = 0
    var commaMode = false
    template check_err =
      #TODO calc, percentages, etc (cssnumber function or something)
      if i >= f.value.len or f.value[i] != CSS_NUMBER_TOKEN:
        raise newException(CSSValueError, "Invalid color")
    template next_value(first = false, slash = false) =
      inc i
      f.value.skipWhitespace(i)
      if i < f.value.len:
        if f.value[i] == CSS_COMMA_TOKEN and (commaMode or first):
          # legacy compatibility
          inc i
          f.value.skipWhitespace(i)
          commaMode = true
        elif commaMode:
          raise newException(CSSValueError, "Invalid color")
        if slash:
          if f.value[i] != CSS_DELIM_TOKEN or CSSToken(f.value[i]).rvalue != Rune('/'):
            raise newException(CSSValueError, "Invalid color")
          inc i
          f.value.skipWhitespace(i)
      check_err
    case f.name
    of "rgb":
      f.value.skipWhitespace(i)
      check_err
      let r = CSSToken(f.value[i]).nvalue
      next_value true
      let g = CSSToken(f.value[i]).nvalue
      next_value
      let b = CSSToken(f.value[i]).nvalue
      return rgba(int(r), int(g), int(b), 255)
    of "rgba":
      f.value.skipWhitespace(i)
      check_err
      let r = CSSToken(f.value[i]).nvalue
      next_value true
      let g = CSSToken(f.value[i]).nvalue
      next_value
      let b = CSSToken(f.value[i]).nvalue
      next_value false, true
      let a = CSSToken(f.value[i]).nvalue
      return rgba(int(r), int(g), int(b), int(a))
    else: discard
  raise newException(CSSValueError, "Invalid color")

func isToken(cval: CSSComponentValue): bool {.inline.} = cval of CSSToken

func cssLength(val: CSSComponentValue, has_auto: static bool = true, allow_negative: static bool = true): CSSLength =
  block nofail:
    if val of CSSToken:
      let tok = CSSToken(val)
      case tok.tokenType
      of CSS_NUMBER_TOKEN:
        if tok.nvalue == 0:
          return CSSLength(num: 0, unit: UNIT_PX)
      of CSS_PERCENTAGE_TOKEN:
        when not allow_negative:
          if tok.nvalue < 0:
            break nofail
        return cssLength(tok.nvalue, "%")
      of CSS_DIMENSION_TOKEN:
        when not allow_negative:
          if tok.nvalue < 0:
            break nofail
        return cssLength(tok.nvalue, tok.unit)
      of CSS_IDENT_TOKEN:
        when has_auto:
          if tok.value == "auto":
            return CSSLength(auto: true)
      else: discard
  raise newException(CSSValueError, "Invalid length")

func cssAbsoluteLength(val: CSSComponentValue): CSSLength =
  if val of CSSToken:
    let tok = CSSToken(val)
    case tok.tokenType
    of CSS_NUMBER_TOKEN:
      if tok.nvalue == 0:
        return CSSLength(num: 0, unit: UNIT_PX)
    of CSS_DIMENSION_TOKEN:
      if tok.nvalue >= 0:
        return cssLength(tok.nvalue, tok.unit)
    else: discard
  raise newException(CSSValueError, "Invalid length")

func cssWordSpacing(cval: CSSComponentValue): CSSLength =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of CSS_DIMENSION_TOKEN:
      return cssLength(tok.nvalue, tok.unit)
    of CSS_IDENT_TOKEN:
      if tok.value == "normal":
        return CSSLength(auto: true)
    else: discard
  raise newException(CSSValueError, "Invalid word spacing")

func getToken(cval: CSSComponentValue): CSSToken = (CSSToken)cval

func cssGlobal*(d: CSSDeclaration): CSSGlobalValueType =
  if d.value.len > 0 and isToken(d.value[0]):
    let tok = getToken(d.value[0])
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "inherit": return VALUE_INHERIT
      of "initial": return VALUE_INITIAL
      of "unset": return VALUE_UNSET
      of "revert": return VALUE_REVERT
  return VALUE_NOGLOBAL

func cssQuotes(d: CSSDeclaration): CSSQuotes =
  template die =
    raise newException(CSSValueError, "Invalid quotes")
  var res: CSSQuotes
  var sa = false
  var pair: tuple[s, e: string]
  for cval in d.value:
    if res.auto: die
    if isToken(cval):
      let tok = getToken(cval)
      case tok.tokenType
      of CSS_IDENT_TOKEN:
        if res.qs.len > 0: die
        case tok.value
        of "auto": res.auto = true
        of "none":
          die
      of CSS_STRING_TOKEN:
        if sa:
          pair.e = tok.value
          res.qs.add(pair)
          sa = false
        else:
          pair.s = tok.value
          sa = true
      of CSS_WHITESPACE_TOKEN: discard
      else: die
  if sa:
    die
  return res

func cssContent(d: CSSDeclaration): seq[CSSContent] =
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      case tok.tokenType
      of CSS_IDENT_TOKEN:
        case tok.value
        of "/": break
        of "open-quote": result.add(CSSContent(t: CONTENT_OPEN_QUOTE))
        of "no-open-quote": result.add(CSSContent(t: CONTENT_NO_OPEN_QUOTE))
        of "close-quote": result.add(CSSContent(t: CONTENT_CLOSE_QUOTE))
        of "no-close-quote": result.add(CSSContent(t: CONTENT_NO_CLOSE_QUOTE))
      of CSS_STRING_TOKEN:
        result.add(CSSContent(t: CONTENT_STRING, s: tok.value))
      else: return

func cssDisplay(cval: CSSComponentValue): CSSDisplay =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "block": return DISPLAY_BLOCK
      of "inline": return DISPLAY_INLINE
      of "list-item": return DISPLAY_LIST_ITEM
      of "inline-block": return DISPLAY_INLINE_BLOCK
      of "table": return DISPLAY_TABLE
      of "table-row": return DISPLAY_TABLE_ROW
      of "table-cell": return DISPLAY_TABLE_CELL
      of "table-column": return DISPLAY_TABLE_COLUMN
      of "table-column-group": return DISPLAY_TABLE_COLUMN_GROUP
      of "inline-table": return DISPLAY_INLINE_TABLE
      of "table-row-group": return DISPLAY_TABLE_ROW_GROUP
      of "table-header-group": return DISPLAY_TABLE_HEADER_GROUP
      of "table-footer-group": return DISPLAY_TABLE_FOOTER_GROUP
      of "table-caption": return DISPLAY_TABLE_CAPTION
      of "none": return DISPLAY_NONE
  raise newException(CSSValueError, "Invalid display")

func cssFontStyle(cval: CSSComponentValue): CSSFontStyle =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "normal": return FONTSTYLE_NORMAL
      of "italic": return FONTSTYLE_ITALIC
      of "oblique": return FONTSTYLE_OBLIQUE
  raise newException(CSSValueError, "Invalid font style")

func cssWhiteSpace(cval: CSSComponentValue): CSSWhitespace =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "normal": return WHITESPACE_NORMAL
      of "nowrap": return WHITESPACE_NOWRAP
      of "pre": return WHITESPACE_PRE
      of "pre-line": return WHITESPACE_PRE_LINE
      of "pre-wrap": return WHITESPACE_PRE_WRAP
  raise newException(CSSValueError, "Invalid whitespace")

func cssFontWeight(cval: CSSComponentValue): int =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "normal": return 400
      of "bold": return 700
      of "lighter": return 400
      of "bolder": return 700
    elif tok.tokenType == CSS_NUMBER_TOKEN:
      return int(tok.nvalue)
  raise newException(CSSValueError, "Invalid font weight")

func cssTextDecoration(d: CSSDeclaration): set[CSSTextDecoration] =
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      if tok.tokenType == CSS_IDENT_TOKEN:
        case tok.value
        of "none": result.incl(TEXT_DECORATION_NONE)
        of "underline": result.incl(TEXT_DECORATION_UNDERLINE)
        of "overline": result.incl(TEXT_DECORATION_OVERLINE)
        of "line-through": result.incl(TEXT_DECORATION_LINE_THROUGH)
        of "blink": result.incl(TEXT_DECORATION_BLINK)

func cssWordBreak(cval: CSSComponentValue): CSSWordBreak =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "normal": return WORD_BREAK_NORMAL
      of "break-all": return WORD_BREAK_BREAK_ALL
      of "keep-all": return WORD_BREAK_KEEP_ALL
  raise newException(CSSValueError, "Invalid text decoration")

func cssListStyleType(cval: CSSComponentValue): CSSListStyleType =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "none": return LIST_STYLE_TYPE_NONE
      of "disc": return LIST_STYLE_TYPE_DISC
      of "circle": return LIST_STYLE_TYPE_CIRCLE
      of "square": return LIST_STYLE_TYPE_SQUARE
      of "decimal": return LIST_STYLE_TYPE_DECIMAL
      of "upper-roman": return LIST_STYLE_TYPE_UPPER_ROMAN
      of "lower-roman": return LIST_STYLE_TYPE_LOWER_ROMAN
      of "japanese-informal": return LIST_STYLE_TYPE_JAPANESE_INFORMAL
  raise newException(CSSValueError, "Invalid list style")

func cssVerticalAlign(cval: CSSComponentValue): CSSVerticalAlign =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
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
      result.length = cssLength(tok, has_auto = false)
      return result
  raise newException(CSSValueError, "Invalid vertical align")

func cssLineHeight(cval: CSSComponentValue): CSSLength =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of CSS_NUMBER_TOKEN:
      return cssLength(tok.nvalue * 100, "%")
    of CSS_IDENT_TOKEN:
      if tok.value == "normal":
        return CSSLength(auto: true)
    else:
      return cssLength(tok, has_auto = false)
  raise newException(CSSValueError, "Invalid line height")

func cssTextAlign(cval: CSSComponentValue): CSSTextAlign =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "start": return TEXT_ALIGN_START
      of "end": return TEXT_ALIGN_END
      of "left": return TEXT_ALIGN_LEFT
      of "right": return TEXT_ALIGN_RIGHT
      of "center": return TEXT_ALIGN_CENTER
      of "justify": return TEXT_ALIGN_JUSTIFY
      of "-cha-center": return TEXT_ALIGN_CHA_CENTER
  raise newException(CSSValueError, "Invalid text align")

func cssListStylePosition(cval: CSSComponentValue): CSSListStylePosition =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "outside": return LIST_STYLE_POSITION_OUTSIDE
      of "inside": return LIST_STYLE_POSITION_INSIDE
  raise newException(CSSValueError, "Invalid list style position")

func cssPosition(cval: CSSComponentValue): CSSPosition =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "static": return POSITION_STATIC
      of "relative": return POSITION_RELATIVE
      of "absolute": return POSITION_ABSOLUTE
      of "fixed": return POSITION_FIXED
      of "sticky": return POSITION_STICKY
      else: raise newException(CSSValueError, "Invalid list style position")
  raise newException(CSSValueError, "Invalid list style position")

func cssCaptionSide(cval: CSSComponentValue): CSSCaptionSide =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "top": return CAPTION_SIDE_TOP
      of "bottom": return CAPTION_SIDE_BOTTOM
      of "left": return CAPTION_SIDE_LEFT
      of "right": return CAPTION_SIDE_RIGHT
      of "block-start": return CAPTION_SIDE_BLOCK_START
      of "block-end": return CAPTION_SIDE_BLOCK_END
      of "inline-start": return CAPTION_SIDE_INLINE_START
      of "inline-end": return CAPTION_SIDE_INLINE_END
  raise newException(CSSValueError, "Invalid caption side")

func cssBorderCollapse(cval: CSSComponentValue): CSSBorderCollapse =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      case tok.value
      of "collapse": return BORDER_COLLAPSE_COLLAPSE
      of "separate": return BORDER_COLLAPSE_SEPARATE
  raise newException(CSSValueError, "Invalid border collapse")

func cssCounterReset(d: CSSDeclaration): seq[CSSCounterReset] =
  template die =
    raise newException(CSSValueError, "Invalid counter-reset")
  var r: CSSCounterReset
  var s = false
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      case tok.tokenType
      of CSS_WHITESPACE_TOKEN: discard
      of CSS_IDENT_TOKEN:
        if s:
          die
        r.name = tok.value
        s = true
      of CSS_NUMBER_TOKEN:
        if not s:
          die
        r.num = int(tok.nvalue)
        result.add(r)
        s = false
      else:
        die

func cssMaxMinSize(cval: CSSComponentValue): CSSLength =
  if isToken(cval):
    let tok = getToken(cval)
    case tok.tokenType
    of CSS_IDENT_TOKEN:
      if tok.value == "none":
        return CSSLength(auto: true)
    of CSS_NUMBER_TOKEN, CSS_DIMENSION_TOKEN:
      return cssLength(tok, allow_negative = false)
    else: discard
  raise newException(CSSValueError, "Invalid min/max-size")

#TODO this should be a separate type
func cssImage(cval: CSSComponentValue): CSSContent =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_URL_TOKEN or tok.tokenType == CSS_BAD_URL_TOKEN:
      return CSSContent(t: CONTENT_IMAGE, s: "[img]")
  raise newException(CSSValueError, "Invalid image")

func cssInteger(cval: CSSComponentValue, range: Slice[int]): int =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_NUMBER_TOKEN:
      let i = int(tok.nvalue)
      if float64(i) == tok.nvalue and i in range:
        return i
  raise newException(CSSValueError, "Invalid integer")

proc getValueFromDecl(val: CSSComputedValue, d: CSSDeclaration, vtype: CSSValueType, ptype: CSSPropertyType) =
  var i = 0
  d.value.skipWhitespace(i)
  if i >= d.value.len: 
    raise newException(CSSValueError, "Empty value")
  let cval = d.value[i]
  inc i
  case vtype
  of VALUE_COLOR:
    val.color = cssColor(cval)
  of VALUE_LENGTH:
    case ptype
    of PROPERTY_WORD_SPACING:
      val.length = cssWordSpacing(cval)
    of PROPERTY_LINE_HEIGHT:
      val.length = cssLineHeight(cval)
    of PROPERTY_MAX_WIDTH, PROPERTY_MAX_HEIGHT, PROPERTY_MIN_WIDTH,
       PROPERTY_MIN_HEIGHT:
      val.length = cssMaxMinSize(cval)
    of PROPERTY_PADDING_LEFT, PROPERTY_PADDING_RIGHT, PROPERTY_PADDING_TOP,
       PROPERTY_PADDING_BOTTOM:
      val.length = cssLength(cval, has_auto = false)
    else:
      val.length = cssLength(cval)
  of VALUE_FONT_STYLE: val.fontstyle = cssFontStyle(cval)
  of VALUE_DISPLAY: val.display = cssDisplay(cval)
  of VALUE_CONTENT: val.content = cssContent(d)
  of VALUE_WHITE_SPACE: val.whitespace = cssWhiteSpace(cval)
  of VALUE_INTEGER:
    if ptype == PROPERTY_FONT_WEIGHT:
      val.integer = cssFontWeight(cval)
    elif ptype == PROPERTY_CHA_COLSPAN:
      val.integer = cssInteger(cval, 1 .. 1000)
    elif ptype == PROPERTY_CHA_ROWSPAN:
      val.integer = cssInteger(cval, 0 .. 65534)
  of VALUE_TEXT_DECORATION: val.textdecoration = cssTextDecoration(d)
  of VALUE_WORD_BREAK: val.wordbreak = cssWordBreak(cval)
  of VALUE_LIST_STYLE_TYPE: val.liststyletype = cssListStyleType(cval)
  of VALUE_VERTICAL_ALIGN: val.verticalalign = cssVerticalAlign(cval)
  of VALUE_TEXT_ALIGN: val.textalign = cssTextAlign(cval)
  of VALUE_LIST_STYLE_POSITION: val.liststyleposition = cssListStylePosition(cval)
  of VALUE_POSITION: val.position = cssPosition(cval)
  of VALUE_CAPTION_SIDE: val.captionside = cssCaptionSide(cval)
  of VALUE_BORDER_COLLAPSE: val.bordercollapse = cssBorderCollapse(cval)
  of VALUE_LENGTH2:
    val.length2.a = cssAbsoluteLength(cval)
    d.value.skipWhitespace(i)
    if i >= d.value.len:
      val.length2.b = val.length2.a
    else:
      let cval = d.value[i]
      val.length2.b = cssAbsoluteLength(cval)
  of VALUE_QUOTES: val.quotes = cssQuotes(d)
  of VALUE_COUNTER_RESET: val.counterreset = cssCounterReset(d)
  of VALUE_IMAGE: val.image = cssImage(d)
  of VALUE_NONE: discard

func getInitialColor(t: CSSPropertyType): RGBAColor =
  case t
  of PROPERTY_COLOR:
    return Colors["white"]
  of PROPERTY_BACKGROUND_COLOR:
    return Colors["transparent"]
  else:
    return Colors["black"]

func getInitialLength(t: CSSPropertyType): CSSLength =
  case t
  of PROPERTY_WIDTH, PROPERTY_HEIGHT, PROPERTY_WORD_SPACING,
     PROPERTY_LINE_HEIGHT, PROPERTY_LEFT, PROPERTY_RIGHT, PROPERTY_TOP,
     PROPERTY_BOTTOM, PROPERTY_MAX_WIDTH, PROPERTY_MAX_HEIGHT,
     PROPERTY_MIN_WIDTH, PROPERTY_MIN_HEIGHT:
    return CSSLength(auto: true)
  else:
    return CSSLength(auto: false, unit: UNIT_PX, num: 0)

func getInitialInteger(t: CSSPropertyType): int =
  case t
  of PROPERTY_CHA_COLSPAN, PROPERTY_CHA_ROWSPAN:
    return 1
  of PROPERTY_FONT_WEIGHT:
    return 400 # normal
  else: discard

func calcInitial(t: CSSPropertyType): CSSComputedValue =
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
  of VALUE_INTEGER:
    nv = CSSComputedValue(t: t, v: v, integer: getInitialInteger(t))
  of VALUE_QUOTES:
    nv = CSSComputedValue(t: t, v: v, quotes: CSSQuotes(auto: true))
  else:
    nv = CSSComputedValue(t: t, v: v)
  return nv

func getInitialTable(): array[CSSPropertyType, CSSComputedValue] =
  for i in low(result)..high(result):
    result[i] = calcInitial(i)

let defaultTable = getInitialTable()

template getDefault(t: CSSPropertyType): CSSComputedValue = {.cast(noSideEffect).}:
  defaultTable[t]

# WARNING: may raise an exception.
func getComputedValue(d: CSSDeclaration, ptype: CSSPropertyType, vtype: CSSValueType): (CSSComputedValue, CSSGlobalValueType) =
  var val = CSSComputedValue(t: ptype, v: vtype)
  val.getValueFromDecl(d, vtype, ptype)
  return (val, cssGlobal(d))

func lengthShorthand(d: CSSDeclaration, props: array[4, CSSPropertyType]): seq[(CSSComputedValue, CSSGlobalValueType)] =
  var i = 0
  var cvals: seq[CSSComponentValue]
  while i < d.value.len:
    if d.value[i] != CSS_WHITESPACE_TOKEN:
      cvals.add(d.value[i])
    inc i
  case cvals.len
  of 1: # top, bottom, left, right
    try:
      for ptype in props:
        let vtype = valueType(ptype)
        let val = CSSComputedValue(t: ptype, v: vtype)
        val.getValueFromDecl(d, vtype, ptype)
        result.add((val, cssGlobal(d)))
    except CSSValueError: discard
  of 2: # top, bottom | left, right
    try:
      for i in 0 ..< props.len:
        let ptype = props[i]
        let vtype = valueType(ptype)
        let val = CSSComputedValue(t: ptype, v: vtype)
        val.length = cssLength(cvals[i mod 2])
        result.add((val, cssGlobal(d)))
    except CSSValueError:
      discard
  of 3: # top | left, right | bottom
    try:
      for i in 0 ..< props.len:
        let ptype = props[i]
        let vtype = valueType(ptype)
        let val = CSSComputedValue(t: ptype, v: vtype)
        let j = if i == 0:
          0 # top
        elif i == 3:
          2 # bottom
        else:
          1 # left, right
        val.length = cssLength(cvals[j])
        result.add((val, cssGlobal(d)))
    except CSSValueError:
      discard
  of 4: # top | right | bottom | left
    try:
      for i in 0 ..< props.len:
        let ptype = props[i]
        let vtype = valueType(ptype)
        let val = CSSComputedValue(t: ptype, v: vtype)
        val.length = cssLength(cvals[i])
        result.add((val, cssGlobal(d)))
    except CSSValueError:
      discard
  else: discard

proc getComputedValues(d: CSSDeclaration): seq[(CSSComputedValue, CSSGlobalValueType)] =
  let name = d.name
  case shorthandType(name)
  of SHORTHAND_NONE:
    let ptype = propertyType(name)
    let vtype = valueType(ptype)
    try:
      result.add(getComputedValue(d, ptype, vtype))
    except CSSValueError:
      discard
  of SHORTHAND_ALL:
    let global = cssGlobal(d)
    if global != VALUE_NOGLOBAL:
      for ptype in CSSPropertyType:
        let vtype = valueType(ptype)
        let val = CSSComputedValue(t: ptype, v: vtype)
        result.add((val, global))
  of SHORTHAND_MARGIN:
    result.add(lengthShorthand(d, [PROPERTY_MARGIN_TOP,
                                   PROPERTY_MARGIN_RIGHT,
                                   PROPERTY_MARGIN_BOTTOM,
                                   PROPERTY_MARGIN_LEFT]))
  of SHORTHAND_PADDING:
    result.add(lengthShorthand(d, [PROPERTY_PADDING_TOP,
                                   PROPERTY_PADDING_RIGHT,
                                   PROPERTY_PADDING_BOTTOM,
                                   PROPERTY_PADDING_LEFT]))
  of SHORTHAND_BACKGROUND:
    let global = cssGlobal(d)
    let bgcolorptype = PROPERTY_BACKGROUND_COLOR
    let bgcolorval = CSSComputedValue(t: bgcolorptype, v: valueType(bgcolorptype))
    let bgimageptype = PROPERTY_BACKGROUND_IMAGE
    let bgimageval = CSSComputedValue(t: bgimageptype, v: valueType(bgimageptype))
    if global == VALUE_NOGLOBAL:
      for tok in d.value:
        try:
          bgimageval.image = cssImage(tok)
          result.add((bgimageval, global))
        except CSSValueError:
          try:
            bgcolorval.color = cssColor(tok)
            result.add((bgcolorval, global))
          except CSSValueError:
            discard
    else:
      result.add((bgcolorval, global))
  of SHORTHAND_LIST_STYLE:
    let global = cssGlobal(d)
    let positionptype = PROPERTY_LIST_STYLE_POSITION
    let positionval = CSSComputedValue(t: positionptype, v: valueType(positionptype))
    let typeptype = PROPERTY_LIST_STYLE_TYPE
    let typeval = CSSComputedValue(t: typeptype, v: valueType(typeptype))
    if global == VALUE_NOGLOBAL:
      for tok in d.value:
        try:
          positionval.liststyleposition = cssListStylePosition(tok)
          result.add((positionval, global))
        except CSSValueError:
          try:
            typeval.liststyletype = cssListStyleType(tok)
            result.add((typeval, global))
          except CSSValueError:
            #TODO list-style-image
            discard

func equals*(a, b: CSSComputedValue): bool =
  if a == b:
    return true
  if a == nil or b == nil:
    return false
  if a.v != b.v:
    return false
  case a.v
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
  of VALUE_POSITION: return a.position == b.position
  of VALUE_CAPTION_SIDE: return a.captionside == b.captionside
  of VALUE_LENGTH2: return a.length2 == b.length2
  of VALUE_BORDER_COLLAPSE: return a.bordercollapse == b.bordercollapse
  of VALUE_QUOTES: return a.quotes == b.quotes
  of VALUE_COUNTER_RESET: return a.counterreset == b.counterreset
  of VALUE_IMAGE: return a.image == b.image
  of VALUE_NONE: return true
  return false

proc newComputedValueBuilder*(parent: CSSComputedValues): CSSComputedValuesBuilder =
  result.parent = parent

proc addValuesImportant*(builder: var CSSComputedValuesBuilder, decls: seq[CSSDeclaration], origin: CSSOrigin) =
  for decl in decls:
    if decl.important:
      let vals = getComputedValues(decl)
      for vg in vals:
        let (val, global) = vg
        builder.importantProperties[origin].add(CSSComputedValueBuilder(val: val, global: global))

proc addValuesNormal*(builder: var CSSComputedValuesBuilder, decls: seq[CSSDeclaration], origin: CSSOrigin) =
  for decl in decls:
    if not decl.important:
      let vals = getComputedValues(decl)
      for vg in vals:
        let (val, global) = vg
        builder.normalProperties[origin].add(CSSComputedValueBuilder(val: val, global: global))

proc addValues*(builder: var CSSComputedValuesBuilder, decls: seq[CSSDeclaration], origin: CSSOrigin) =
  for decl in decls:
    let vals = getComputedValues(decl)
    for vg in vals:
      let (val, global) = vg
      if decl.important:
        builder.importantProperties[origin].add(CSSComputedValueBuilder(val: val, global: global))
      else:
        builder.normalProperties[origin].add(CSSComputedValueBuilder(val: val, global: global))

proc applyValue(vals: CSSComputedValues, val: CSSComputedValue, global: CSSGlobalValueType, parent: CSSComputedValues, previousOrigin: CSSComputedValues) =
  let prop = val.t
  let parentVal = if parent != nil:
    parent[prop]
  else:
    nil
  case global
  of VALUE_INHERIT:
    if parentVal != nil:
      vals[prop] = parentVal
    else:
      vals[prop] = getDefault(prop)
  of VALUE_INITIAL:
    vals[prop] = getDefault(prop)
  of VALUE_UNSET:
    if inherited(prop):
      # inherit
      if parentVal != nil:
        vals[prop] = parentVal
      else:
        vals[prop] = getDefault(prop)
    else:
      # initial
      vals[prop] = getDefault(prop)
  of VALUE_REVERT:
    if previousOrigin != nil:
      vals[prop] = previousOrigin[prop]
    else:
      vals[prop] = getDefault(prop)
  of VALUE_NOGLOBAL:
    vals[prop] = val

func inheritProperties*(parent: CSSComputedValues): CSSComputedValues =
  new(result)
  for prop in CSSPropertyType:
    if inherited(prop) and parent[prop] != nil:
      result[prop] = parent[prop]
    else:
      result[prop] = getDefault(prop)

func copyProperties*(props: CSSComputedValues): CSSComputedValues =
  new(result)
  for prop in CSSPropertyType:
    result[prop] = props[prop]

func rootProperties*(): CSSComputedValues =
  new(result)
  for prop in CSSPropertyType:
    result[prop] = getDefault(prop)

func hasValues*(builder: CSSComputedValuesBuilder): bool =
  for origin in CSSOrigin:
    if builder.normalProperties[origin].len > 0:
      return true
    if builder.importantProperties[origin].len > 0:
      return true
  return false

func buildComputedValues*(builder: CSSComputedValuesBuilder): CSSComputedValues =
  new(result)
  var previousOrigins: array[CSSOrigin, CSSComputedValues]
  block:
    let origin = ORIGIN_USER_AGENT
    for build in builder.normalProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, nil)
    previousOrigins[origin] = result.copyProperties()
  # Presentational hints override user agent style, but respect user/author style.
  if builder.preshints != nil:
    for prop in CSSPropertyType:
      if builder.preshints[prop] != nil:
        result[prop] = builder.preshints[prop]
  block:
    let origin = ORIGIN_USER
    let prevOrigin = ORIGIN_USER_AGENT
    for build in builder.normalProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, previousOrigins[prevOrigin])
    previousOrigins[origin] = result.copyProperties() # save user origins so author can use them
  block:
    let origin = ORIGIN_AUTHOR
    let prevOrigin = ORIGIN_USER
    for build in builder.normalProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, previousOrigins[prevOrigin])
    # no need to save user origins
  block:
    let origin = ORIGIN_AUTHOR
    let prevOrigin = ORIGIN_USER
    for build in builder.importantProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, previousOrigins[prevOrigin])
    # important, so no need to save origins
  block:
    let origin = ORIGIN_USER
    let prevOrigin = ORIGIN_USER_AGENT
    for build in builder.importantProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, previousOrigins[prevOrigin])
    # important, so no need to save origins
  block:
    let origin = ORIGIN_USER_AGENT
    for build in builder.importantProperties[origin]:
      result.applyValue(build.val, build.global, builder.parent, nil)
    # important, so no need to save origins
  # set defaults
  for prop in CSSPropertyType:
    if result[prop] == nil:
      if inherited(prop) and builder.parent != nil and builder.parent[prop] != nil:
        result[prop] = builder.parent[prop]
      else:
        result[prop] = getDefault(prop)
