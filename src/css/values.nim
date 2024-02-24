import std/macros
import std/options
import std/strutils
import std/tables
import std/unicode

import css/cssparser
import css/selectorparser
import display/winattrs
import img/bitmap
import layout/layoutunit
import types/color
import types/opt
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
    PROPERTY_CHA_COLSPAN, PROPERTY_CHA_ROWSPAN, PROPERTY_FLOAT,
    PROPERTY_VISIBILITY, PROPERTY_BOX_SIZING, PROPERTY_CLEAR,
    PROPERTY_TEXT_TRANSFORM, PROPERTY_BGCOLOR_IS_CANVAS

  CSSValueType* = enum
    VALUE_NONE, VALUE_LENGTH, VALUE_COLOR, VALUE_CONTENT, VALUE_DISPLAY,
    VALUE_FONT_STYLE, VALUE_WHITE_SPACE, VALUE_INTEGER, VALUE_TEXT_DECORATION,
    VALUE_WORD_BREAK, VALUE_LIST_STYLE_TYPE, VALUE_VERTICAL_ALIGN,
    VALUE_TEXT_ALIGN, VALUE_LIST_STYLE_POSITION, VALUE_POSITION,
    VALUE_CAPTION_SIDE, VALUE_LENGTH2, VALUE_BORDER_COLLAPSE, VALUE_QUOTES,
    VALUE_COUNTER_RESET, VALUE_IMAGE, VALUE_FLOAT, VALUE_VISIBILITY,
    VALUE_BOX_SIZING, VALUE_CLEAR, VALUE_TEXT_TRANSFORM, VALUE_BGCOLOR_IS_CANVAS

  CSSGlobalValueType* = enum
    VALUE_NOGLOBAL, VALUE_INITIAL, VALUE_INHERIT, VALUE_REVERT, VALUE_UNSET

  CSSDisplay* = enum
    DISPLAY_NONE, DISPLAY_INLINE, DISPLAY_BLOCK, DISPLAY_LIST_ITEM,
    DISPLAY_INLINE_BLOCK, DISPLAY_TABLE, DISPLAY_INLINE_TABLE,
    DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP,
    DISPLAY_TABLE_FOOTER_GROUP, DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_ROW,
    DISPLAY_TABLE_COLUMN, DISPLAY_TABLE_CELL, DISPLAY_TABLE_CAPTION,
    DISPLAY_FLOW_ROOT

  CSSWhitespace* = enum
    WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE, WHITESPACE_PRE_LINE,
    WHITESPACE_PRE_WRAP

  CSSFontStyle* = enum
    FONT_STYLE_NORMAL, FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE

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
    LIST_STYLE_TYPE_DISCLOSURE_CLOSED, LIST_STYLE_TYPE_DISCLOSURE_OPEN,
    LIST_STYLE_TYPE_CJK_EARTHLY_BRANCH, LIST_STYLE_TYPE_CJK_HEAVENLY_STEM,
    LIST_STYLE_TYPE_LOWER_ROMAN, LIST_STYLE_TYPE_UPPER_ROMAN,
    LIST_STYLE_TYPE_LOWER_ALPHA, LIST_STYLE_TYPE_UPPER_ALPHA,
    LIST_STYLE_TYPE_LOWER_GREEK,
    LIST_STYLE_TYPE_HIRAGANA, LIST_STYLE_TYPE_HIRAGANA_IROHA,
    LIST_STYLE_TYPE_KATAKANA, LIST_STYLE_TYPE_KATAKANA_IROHA,
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

  CSSFloat* = enum
    FLOAT_NONE, FLOAT_LEFT, FLOAT_RIGHT

  CSSVisibility* = enum
    VISIBILITY_VISIBLE, VISIBILITY_HIDDEN, VISIBILITY_COLLAPSE

  CSSBoxSizing* = enum
    BOX_SIZING_CONTENT_BOX, BOX_SIZING_BORDER_BOX

  CSSClear* = enum
    CLEAR_NONE, CLEAR_LEFT, CLEAR_RIGHT, CLEAR_BOTH, CLEAR_INLINE_START,
    CLEAR_INLINE_END

  CSSTextTransform* = enum
    TEXT_TRANSFORM_NONE, TEXT_TRANSFORM_CAPITALIZE, TEXT_TRANSFORM_UPPERCASE,
    TEXT_TRANSFORM_LOWERCASE, TEXT_TRANSFORM_FULL_WIDTH,
    TEXT_TRANSFORM_FULL_SIZE_KANA, TEXT_TRANSFORM_CHA_HALF_WIDTH

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
    bmp*: Bitmap

  CSSQuotes* = object
    auto*: bool
    qs*: seq[tuple[s, e: string]]

  CSSCounterReset* = object
    name*: string
    num*: int

  CSSComputedValue* = ref object
    case v*: CSSValueType
    of VALUE_COLOR:
      color*: CellColor
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
    of VALUE_WHITE_SPACE:
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
    of VALUE_FLOAT:
      float*: CSSFloat
    of VALUE_VISIBILITY:
      visibility*: CSSVisibility
    of VALUE_BOX_SIZING:
      boxsizing*: CSSBoxSizing
    of VALUE_CLEAR:
      clear*: CSSClear
    of VALUE_TEXT_TRANSFORM:
      texttransform*: CSSTextTransform
    of VALUE_BGCOLOR_IS_CANVAS:
      bgcoloriscanvas*: bool
    of VALUE_NONE: discard

  CSSComputedValues* = ref array[CSSPropertyType, CSSComputedValue]

  CSSOrigin* = enum
    ORIGIN_USER_AGENT
    ORIGIN_USER
    ORIGIN_AUTHOR

  CSSComputedEntry = tuple
    t: CSSPropertyType
    val: CSSComputedValue
    global: CSSGlobalValueType

  CSSComputedEntries = seq[CSSComputedEntry]

  CSSComputedValuesBuilder* = object
    parent*: CSSComputedValues
    normalProperties: array[CSSOrigin, CSSComputedEntries]
    importantProperties: array[CSSOrigin, CSSComputedEntries]
    preshints*: CSSComputedValues

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
  "-cha-rowspan": PROPERTY_CHA_ROWSPAN,
  "float": PROPERTY_FLOAT,
  "visibility": PROPERTY_VISIBILITY,
  "box-sizing": PROPERTY_BOX_SIZING,
  "clear": PROPERTY_CLEAR,
  "text-transform": PROPERTY_TEXT_TRANSFORM,
  "-cha-bgcolor-is-canvas": PROPERTY_BGCOLOR_IS_CANVAS
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
  PROPERTY_CHA_ROWSPAN: VALUE_INTEGER,
  PROPERTY_FLOAT: VALUE_FLOAT,
  PROPERTY_VISIBILITY: VALUE_VISIBILITY,
  PROPERTY_BOX_SIZING: VALUE_BOX_SIZING,
  PROPERTY_CLEAR: VALUE_CLEAR,
  PROPERTY_TEXT_TRANSFORM: VALUE_TEXT_TRANSFORM,
  PROPERTY_BGCOLOR_IS_CANVAS: VALUE_BGCOLOR_IS_CANVAS
]

const InheritedProperties = {
  PROPERTY_COLOR, PROPERTY_FONT_STYLE, PROPERTY_WHITE_SPACE,
  PROPERTY_FONT_WEIGHT, PROPERTY_TEXT_DECORATION, PROPERTY_WORD_BREAK,
  PROPERTY_LIST_STYLE_TYPE, PROPERTY_WORD_SPACING, PROPERTY_LINE_HEIGHT,
  PROPERTY_TEXT_ALIGN, PROPERTY_LIST_STYLE_POSITION, PROPERTY_CAPTION_SIDE,
  PROPERTY_BORDER_SPACING, PROPERTY_BORDER_COLLAPSE, PROPERTY_QUOTES,
  PROPERTY_VISIBILITY, PROPERTY_TEXT_TRANSFORM
}

func getPropInheritedArray(): array[CSSPropertyType, bool] =
  for prop in CSSPropertyType:
    if prop in InheritedProperties:
      result[prop] = true
    else:
      result[prop] = false

const InheritedArray = getPropInheritedArray()

func shorthandType(s: string): CSSShorthandType =
  return ShorthandNames.getOrDefault(s.toLowerAscii(), SHORTHAND_NONE)

func propertyType(s: string): CSSPropertyType =
  return PropertyNames.getOrDefault(s.toLowerAscii(), PROPERTY_NONE)

func valueType(prop: CSSPropertyType): CSSValueType =
  return ValueTypes[prop]

func isSupportedProperty*(s: string): bool =
  return s in PropertyNames

func `$`*(length: CSSLength): string =
  if length.auto:
    return "auto"
  let ss = ($length.unit).split('_')
  let us = ss.toOpenArray(1, ss.high).join('_').toLowerAscii()
  return $length.num & us

func `$`*(content: CSSContent): string =
  if content.s != "":
    return "url(" & content.s & ")"
  return "none"

func `$`*(val: CSSComputedValue): string =
  case val.v
  of VALUE_COLOR:
    result &= $val.color
  of VALUE_IMAGE:
    result &= $val.image
  of VALUE_LENGTH:
    result &= $val.length
  else:
    result = $val.v

macro `{}`*(vals: CSSComputedValues, s: string): untyped =
  let t = propertyType($s)
  let vs = $valueType(t)
  let vss = vs.split('_')
  let s = vss.toOpenArray(1, vss.high).join('_').toLowerAscii()
  return newDotExpr(newTree(nnkBracketExpr, vals, newLit(t)), newIdentNode(s))

macro `{}=`*(vals: CSSComputedValues, s: string, val: typed) =
  let t = propertyType($s)
  let v = valueType(t)
  let vs = $v
  let vss = vs.split('_')
  let s = vss.toOpenArray(1, vss.high).join('_').toLowerAscii()
  let id = ident(s)
  let expr = newTree(nnkBracketExpr, vals, newLit(t))
  return quote do:
    `expr` = CSSComputedValue(v: CSSValueType(`v`), `id`: `val`)

func inherited(t: CSSPropertyType): bool =
  return InheritedArray[t]

func em_to_px(em: float64, window: WindowAttributes): LayoutUnit =
  em * float64(window.ppl)

func ch_to_px(ch: float64, window: WindowAttributes): LayoutUnit =
  ch * float64(window.ppc)

# 水 width, we assume it's 2 chars
func ic_to_px(ic: float64, window: WindowAttributes): LayoutUnit =
  ic * float64(window.ppc) * 2

# x-letter height, we assume it's em/2
func ex_to_px(ex: float64, window: WindowAttributes): LayoutUnit =
  ex * float64(window.ppc) / 2

func px*(l: CSSLength, window: WindowAttributes, p: LayoutUnit): LayoutUnit
    {.inline.} =
  case l.unit
  of UNIT_EM, UNIT_REM: em_to_px(l.num, window)
  of UNIT_CH: ch_to_px(l.num, window)
  of UNIT_IC: ic_to_px(l.num, window)
  of UNIT_EX: ex_to_px(l.num, window)
  of UNIT_PERC: toLayoutUnit(toFloat64(p) * l.num / 100)
  of UNIT_PX: toLayoutUnit(l.num)
  of UNIT_CM: toLayoutUnit(l.num * 37.8)
  of UNIT_MM: toLayoutUnit(l.num * 3.78)
  of UNIT_IN: toLayoutUnit(l.num * 96)
  of UNIT_PC: toLayoutUnit(l.num * 16)
  of UNIT_PT: toLayoutUnit(l.num * 4 / 3)
  of UNIT_VW: toLayoutUnit(float64(window.width_px) * l.num / 100)
  of UNIT_VH: toLayoutUnit(float64(window.height_px) * l.num / 100)
  of UNIT_VMIN:
    toLayoutUnit(min(window.width_px, window.width_px) / 100 * l.num)
  of UNIT_VMAX:
    toLayoutUnit(max(window.width_px, window.width_px) / 100 * l.num)

const UpperAlphaMap = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".toRunes()
const LowerAlphaMap = "abcdefghijklmnopqrstuvwxyz".toRunes()
const LowerGreekMap = "αβγδεζηθικλμνξοπρστυφχψω".toRunes()
const HiraganaMap = ("あいうえおかきくけこさしすせそたちつてとなにぬねの" &
  "はひふへほまみむめもやゆよらりるれろわゐゑをん").toRunes()
const HiraganaIrohaMap = ("いろはにほへとちりぬるをわかよたれそつねならむ" &
  "うゐのおくやまけふこえてあさきゆめみしゑひもせす").toRunes()
const KatakanaMap = ("アイウエオカキクケコサシスセソタチツテトナニヌネノ" &
  "ハヒフヘホマミムメモヤユヨラリルレロワヰヱヲン").toRunes()
const KatakanaIrohaMap = ("イロハニホヘトチリヌルヲワカヨタレソツネナラム" &
  "ウヰノオクヤマケフコエテアサキユメミシヱヒモセス").toRunes()
const EarthlyBranchMap = "子丑寅卯辰巳午未申酉戌亥".toRunes()
const HeavenlyStemMap = "甲乙丙丁戊己庚辛壬癸".toRunes()

func numToBase(n: int, map: openArray[Rune]): string =
  if n <= 0:
    return $n
  var tmp: seq[Rune]
  var n = n
  while n != 0:
    n -= 1
    tmp &= map[n mod map.len]
    n = n div map.len
  result = ""
  for i in countdown(tmp.high, 0):
    result &= $tmp[i]

func numToFixed(n: int, map: openArray[Rune]): string =
  let n = n - 1
  if n notin 0 .. map.high:
    return $n
  return $map[n]

func listMarker*(t: CSSListStyleType, i: int): string =
  case t
  of LIST_STYLE_TYPE_NONE: return ""
  of LIST_STYLE_TYPE_DISC: return "• " # U+2022
  of LIST_STYLE_TYPE_CIRCLE: return "○ " # U+25CB
  of LIST_STYLE_TYPE_SQUARE: return "□ " # U+25A1
  of LIST_STYLE_TYPE_DISCLOSURE_OPEN: return "▶ " # U+25B6
  of LIST_STYLE_TYPE_DISCLOSURE_CLOSED: return "▼ " # U+25BC
  of LIST_STYLE_TYPE_DECIMAL: return $i & ". "
  of LIST_STYLE_TYPE_UPPER_ROMAN: return romanNumber(i) & ". "
  of LIST_STYLE_TYPE_LOWER_ROMAN: return romanNumberLower(i) & ". "
  of LIST_STYLE_TYPE_UPPER_ALPHA: return numToBase(i, UpperAlphaMap) & ". "
  of LIST_STYLE_TYPE_LOWER_ALPHA: return numToBase(i, LowerAlphaMap) & ". "
  of LIST_STYLE_TYPE_LOWER_GREEK: return numToBase(i, LowerGreekMap) & ". "
  of LIST_STYLE_TYPE_HIRAGANA: return numToBase(i, HiraganaMap) & "、"
  of LIST_STYLE_TYPE_HIRAGANA_IROHA:
    return numToBase(i, HiraganaIrohaMap) & "、"
  of LIST_STYLE_TYPE_KATAKANA: return numToBase(i, KatakanaMap) & "、"
  of LIST_STYLE_TYPE_KATAKANA_IROHA:
    return numToBase(i, KatakanaIrohaMap) & "、"
  of LIST_STYLE_TYPE_CJK_EARTHLY_BRANCH:
    return numToFixed(i, EarthlyBranchMap) & "、"
  of LIST_STYLE_TYPE_CJK_HEAVENLY_STEM:
    return numToFixed(i, HeavenlyStemMap) & "、"
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

func cssLength(val: float64, unit: string): Opt[CSSLength] =
  if unit in Units:
    return ok(CSSLength(num: val, unit: Units[unit]))
  return err()

const CSSLengthAuto* = CSSLength(auto: true)

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

func skipWhitespace(vals: openArray[CSSComponentValue], i: var int) =
  while i < vals.len:
    if vals[i] != CSS_WHITESPACE_TOKEN:
      break
    inc i

func parseRGBA(value: openArray[CSSComponentValue]): Opt[CellColor] =
  var i = 0
  var commaMode = false
  template check_err(slash: bool) =
    #TODO calc, percentages, etc (cssnumber function or something)
    if not slash and i >= value.len or i < value.len and
        value[i] != CSS_NUMBER_TOKEN:
      return err()
  template next_value(first = false, slash = false) =
    inc i
    value.skipWhitespace(i)
    if i < value.len:
      if value[i] == CSS_COMMA_TOKEN and (commaMode or first):
        # legacy compatibility
        inc i
        value.skipWhitespace(i)
        commaMode = true
      elif commaMode:
        return err()
      elif slash:
        let tok = value[i]
        if tok != CSS_DELIM_TOKEN or CSSToken(tok).cvalue != '/':
          return err()
        inc i
        value.skipWhitespace(i)
    check_err slash
  value.skipWhitespace(i)
  check_err false
  let r = CSSToken(value[i]).nvalue
  next_value true
  let g = CSSToken(value[i]).nvalue
  next_value
  let b = CSSToken(value[i]).nvalue
  next_value false, true
  let a = if i < value.len:
    CSSToken(value[i]).nvalue
  else:
    1
  value.skipWhitespace(i)
  if i < value.len:
    return err()
  return ok(rgba(int(r), int(g), int(b), int(a * 255)).cellColor())

# syntax: -cha-ansi( number | ident )
# where number is an ANSI color (0..255)
# and ident is in NameTable and may start with "bright-"
func parseANSI(value: openArray[CSSComponentValue]): Opt[CellColor] =
  var i = 0
  value.skipWhitespace(i)
  if i != value.high or not (value[i] of CSSToken): # only 1 param is valid
    #TODO numeric functions
    return err()
  let tok = CSSToken(value[i])
  if tok.tokenType == CSS_NUMBER_TOKEN:
    if tok.nvalue notin 0..255:
      return err() # invalid numeric ANSI color
    return ok(ANSIColor(tok.nvalue).cellColor())
  elif tok.tokenType == CSS_IDENT_TOKEN:
    var name = tok.value
    if name.equalsIgnoreCase("default"):
      return ok(defaultColor)
    var bright = false
    if name.startsWithIgnoreCase("bright-"):
      bright = true
      name = name.substr("bright-".len)
    const NameTable = [
      "black",
      "red",
      "green",
      "yellow",
      "blue",
      "magenta",
      "cyan",
      "white"
    ]
    for i, it in NameTable:
      if it.equalsIgnoreCase(name):
        var i = int(i)
        if bright:
          i += 8
        return ok(ANSIColor(i).cellColor())
  return err()

func cssColor*(val: CSSComponentValue): Opt[CellColor] =
  if val of CSSToken:
    let tok = CSSToken(val)
    case tok.tokenType
    of CSS_HASH_TOKEN:
      let c = parseHexColor(tok.value)
      if c.isSome:
        return ok(c.get.cellColor())
    of CSS_IDENT_TOKEN:
      let s = tok.value.toLowerAscii()
      if s in Colors:
        return ok(Colors[s].cellColor())
    else: discard
  elif val of CSSFunction:
    let f = CSSFunction(val)
    if f.name.equalsIgnoreCase("rgb") or f.name.equalsIgnoreCase("rgba"):
      return parseRGBA(f.value)
    elif f.name.equalsIgnoreCase("-cha-ansi"):
      return parseANSI(f.value)
  return err()

func isToken(cval: CSSComponentValue): bool {.inline.} = cval of CSSToken

func getToken(cval: CSSComponentValue): CSSToken = (CSSToken)cval

func cssIdent[T](map: static openArray[(string, T)], cval: CSSComponentValue):
    Opt[T] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      # cmp when len is small enough, otherwise lowercase & hashmap
      when map.len <= 4:
        for (k, v) in map:
          if k.equalsIgnoreCase(tok.value):
            return ok(v)
      else:
        const MapTable = map.toTable()
        let val = tok.value.toLowerAscii()
        if val in MapTable:
          return ok(MapTable[val])
  return err()

func cssIdentFirst[T](map: static openArray[(string, T)], d: CSSDeclaration):
    Opt[T] =
  if d.value.len == 1:
    return cssIdent(map, d.value[0])
  return err()

func cssLength*(val: CSSComponentValue, has_auto: static bool = true,
    allow_negative: static bool = true): Opt[CSSLength] =
  block nofail:
    if val of CSSToken:
      let tok = CSSToken(val)
      case tok.tokenType
      of CSS_NUMBER_TOKEN:
        if tok.nvalue == 0:
          return ok(CSSLength(num: 0, unit: UNIT_PX))
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
          if tok.value.equalsIgnoreCase("auto"):
            return ok(CSSLengthAuto)
      else: discard
  return err()

func cssAbsoluteLength(val: CSSComponentValue): Opt[CSSLength] =
  if val of CSSToken:
    let tok = CSSToken(val)
    case tok.tokenType
    of CSS_NUMBER_TOKEN:
      if tok.nvalue == 0:
        return ok(CSSLength(num: 0, unit: UNIT_PX))
    of CSS_DIMENSION_TOKEN:
      if tok.nvalue >= 0:
        return cssLength(tok.nvalue, tok.unit)
    else: discard
  return err()

func cssWordSpacing(cval: CSSComponentValue): Opt[CSSLength] =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of CSS_DIMENSION_TOKEN:
      return cssLength(tok.nvalue, tok.unit)
    of CSS_IDENT_TOKEN:
      if tok.value.equalsIgnoreCase("normal"):
        return ok(CSSLengthAuto)
    else: discard
  return err()

func cssGlobal(d: CSSDeclaration): CSSGlobalValueType =
  const GlobalMap = {
    "inherit": VALUE_INHERIT,
    "initial": VALUE_INITIAL,
    "unset": VALUE_UNSET,
    "revert": VALUE_REVERT
  }
  return cssIdentFirst(GlobalMap, d).get(VALUE_NOGLOBAL)

func cssQuotes(d: CSSDeclaration): Opt[CSSQuotes] =
  template die =
    return err()
  if d.value.len == 0:
    die
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
        if tok.value.equalsIgnoreCase("auto"):
          res.auto = true
        elif tok.value.equalsIgnoreCase("none"):
          if d.value.len != 1:
            die
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
  return ok(res)

func cssContent(d: CSSDeclaration): seq[CSSContent] =
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      case tok.tokenType
      of CSS_IDENT_TOKEN:
        if tok.value == "/":
          break
        elif tok.value.equalsIgnoreCase("open-quote"):
          result.add(CSSContent(t: CONTENT_OPEN_QUOTE))
        elif tok.value.equalsIgnoreCase("no-open-quote"):
          result.add(CSSContent(t: CONTENT_NO_OPEN_QUOTE))
        elif tok.value.equalsIgnoreCase("close-quote"):
          result.add(CSSContent(t: CONTENT_CLOSE_QUOTE))
        elif tok.value.equalsIgnoreCase("no-close-quote"):
          result.add(CSSContent(t: CONTENT_NO_CLOSE_QUOTE))
      of CSS_STRING_TOKEN:
        result.add(CSSContent(t: CONTENT_STRING, s: tok.value))
      else: return

func cssDisplay(cval: CSSComponentValue): Opt[CSSDisplay] =
  const DisplayMap = {
    "block": DISPLAY_BLOCK,
    "inline": DISPLAY_INLINE,
    "list-item": DISPLAY_LIST_ITEM,
    "inline-block": DISPLAY_INLINE_BLOCK,
    "table": DISPLAY_TABLE,
    "table-row": DISPLAY_TABLE_ROW,
    "table-cell": DISPLAY_TABLE_CELL,
    "table-column": DISPLAY_TABLE_COLUMN,
    "table-column-group": DISPLAY_TABLE_COLUMN_GROUP,
    "inline-table": DISPLAY_INLINE_TABLE,
    "table-row-group": DISPLAY_TABLE_ROW_GROUP,
    "table-header-group": DISPLAY_TABLE_HEADER_GROUP,
    "table-footer-group": DISPLAY_TABLE_FOOTER_GROUP,
    "table-caption": DISPLAY_TABLE_CAPTION,
    "flow-root": DISPLAY_FLOW_ROOT,
    "none": DISPLAY_NONE
  }
  return cssIdent(DisplayMap, cval)

func cssFontStyle(cval: CSSComponentValue): Opt[CSSFontStyle] =
  const FontStyleMap = {
    "normal": FONT_STYLE_NORMAL,
    "italic": FONT_STYLE_ITALIC,
    "oblique": FONT_STYLE_OBLIQUE
  }
  return cssIdent(FontStyleMap, cval)

func cssWhiteSpace(cval: CSSComponentValue): Opt[CSSWhitespace] =
  const WhiteSpaceMap = {
    "normal": WHITESPACE_NORMAL,
    "nowrap": WHITESPACE_NOWRAP,
    "pre": WHITESPACE_PRE,
    "pre-line": WHITESPACE_PRE_LINE,
    "pre-wrap": WHITESPACE_PRE_WRAP
  }
  return cssIdent(WhiteSpaceMap, cval)

func cssFontWeight(cval: CSSComponentValue): Opt[int] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      const FontWeightMap = {
        "normal": 400,
        "bold": 700,
        "lighter": 400,
        "bolder": 700
      }
      return cssIdent(FontWeightMap, cval)
    elif tok.tokenType == CSS_NUMBER_TOKEN:
      if tok.nvalue in 1f64..1000f64:
        return ok(int(tok.nvalue))
  return err()

func cssTextDecoration(d: CSSDeclaration): Opt[set[CSSTextDecoration]] =
  var s: set[CSSTextDecoration]
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      if tok.tokenType == CSS_IDENT_TOKEN:
        if tok.value.equalsIgnoreCase("none"):
          if d.value.len != 1:
            return err()
          return ok(s)
        elif tok.value.equalsIgnoreCase("underline"):
          s.incl(TEXT_DECORATION_UNDERLINE)
        elif tok.value.equalsIgnoreCase("overline"):
          s.incl(TEXT_DECORATION_OVERLINE)
        elif tok.value.equalsIgnoreCase("line-through"):
          s.incl(TEXT_DECORATION_LINE_THROUGH)
        elif tok.value.equalsIgnoreCase("blink"):
          s.incl(TEXT_DECORATION_BLINK)
        else:
          return err()
  return ok(s)

func cssWordBreak(cval: CSSComponentValue): Opt[CSSWordBreak] =
  const WordBreakMap = {
    "normal": WORD_BREAK_NORMAL,
    "break-all": WORD_BREAK_BREAK_ALL,
    "keep-all": WORD_BREAK_KEEP_ALL
  }
  return cssIdent(WordBreakMap, cval)

func cssListStyleType(cval: CSSComponentValue): Opt[CSSListStyleType] =
  const ListStyleMap = {
    "none": LIST_STYLE_TYPE_NONE,
    "disc": LIST_STYLE_TYPE_DISC,
    "circle": LIST_STYLE_TYPE_CIRCLE,
    "square": LIST_STYLE_TYPE_SQUARE,
    "decimal": LIST_STYLE_TYPE_DECIMAL,
    "disclosure-open": LIST_STYLE_TYPE_DISCLOSURE_OPEN,
    "disclosure-closed": LIST_STYLE_TYPE_DISCLOSURE_CLOSED,
    "cjk-earthly-branch": LIST_STYLE_TYPE_CJK_EARTHLY_BRANCH,
    "cjk-heavenly-stem": LIST_STYLE_TYPE_CJK_HEAVENLY_STEM,
    "upper-roman": LIST_STYLE_TYPE_UPPER_ROMAN,
    "lower-roman": LIST_STYLE_TYPE_LOWER_ROMAN,
    "upper-latin": LIST_STYLE_TYPE_UPPER_ALPHA,
    "lower-latin": LIST_STYLE_TYPE_LOWER_ALPHA,
    "upper-alpha": LIST_STYLE_TYPE_UPPER_ALPHA,
    "lower-alpha": LIST_STYLE_TYPE_UPPER_ALPHA,
    "lower-greek": LIST_STYLE_TYPE_LOWER_GREEK,
    "hiragana": LIST_STYLE_TYPE_HIRAGANA,
    "hiragana-iroha": LIST_STYLE_TYPE_HIRAGANA_IROHA,
    "katakana": LIST_STYLE_TYPE_KATAKANA,
    "katakana-iroha": LIST_STYLE_TYPE_KATAKANA_IROHA,
    "japanese-informal": LIST_STYLE_TYPE_JAPANESE_INFORMAL
  }
  return cssIdent(ListStyleMap, cval)

func cssVerticalAlign(cval: CSSComponentValue): Opt[CSSVerticalAlign] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN:
      const VerticalAlignMap = {
        "baseline": VERTICAL_ALIGN_BASELINE,
        "sub": VERTICAL_ALIGN_SUB,
        "super": VERTICAL_ALIGN_SUPER,
        "text-top": VERTICAL_ALIGN_TEXT_BOTTOM,
        "middle": VERTICAL_ALIGN_MIDDLE,
        "top": VERTICAL_ALIGN_TOP,
        "bottom": VERTICAL_ALIGN_BOTTOM
      }
      let va2 = ?cssIdent(VerticalAlignMap, cval)
      return ok(CSSVerticalAlign(
        keyword: va2
      ))
    else:
      return ok(CSSVerticalAlign(
        keyword: VERTICAL_ALIGN_BASELINE,
        length: ?cssLength(tok, has_auto = false)
      ))
  return err()

func cssLineHeight(cval: CSSComponentValue): Opt[CSSLength] =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of CSS_NUMBER_TOKEN:
      return cssLength(tok.nvalue * 100, "%")
    of CSS_IDENT_TOKEN:
      if tok.value == "normal":
        return ok(CSSLengthAuto)
    else:
      return cssLength(tok, has_auto = false)
  return err()

func cssTextAlign(cval: CSSComponentValue): Opt[CSSTextAlign] =
  const TextAlignMap = {
    "start": TEXT_ALIGN_START,
    "end": TEXT_ALIGN_END,
    "left": TEXT_ALIGN_LEFT,
    "right": TEXT_ALIGN_RIGHT,
    "center": TEXT_ALIGN_CENTER,
    "justify": TEXT_ALIGN_JUSTIFY,
    "-cha-center": TEXT_ALIGN_CHA_CENTER
  }
  return cssIdent(TextAlignMap, cval)

func cssListStylePosition(cval: CSSComponentValue): Opt[CSSListStylePosition] =
  const ListStylePositionMap = {
    "inside": LIST_STYLE_POSITION_INSIDE,
    "outside": LIST_STYLE_POSITION_OUTSIDE
  }
  return cssIdent(ListStylePositionMap, cval)

func cssPosition(cval: CSSComponentValue): Opt[CSSPosition] =
  const PositionMap = {
    "static": POSITION_STATIC,
    "relative": POSITION_RELATIVE,
    "absolute": POSITION_ABSOLUTE,
    "fixed": POSITION_FIXED,
    "sticky": POSITION_STICKY
  }
  return cssIdent(PositionMap, cval)

func cssCaptionSide(cval: CSSComponentValue): Opt[CSSCaptionSide] =
  const CaptionSideMap = {
    "top": CAPTION_SIDE_TOP,
    "bottom": CAPTION_SIDE_BOTTOM,
    "left": CAPTION_SIDE_LEFT,
    "right": CAPTION_SIDE_RIGHT,
    "block-start": CAPTION_SIDE_BLOCK_START,
    "block-end": CAPTION_SIDE_BLOCK_END,
    "inline-start": CAPTION_SIDE_INLINE_START,
    "inline-end": CAPTION_SIDE_INLINE_END
  }
  return cssIdent(CaptionSideMap, cval)

func cssBorderCollapse(cval: CSSComponentValue): Opt[CSSBorderCollapse] =
  const BorderCollapseMap = {
    "collapse": BORDER_COLLAPSE_COLLAPSE,
    "separate": BORDER_COLLAPSE_SEPARATE
  }
  return cssIdent(BorderCollapseMap, cval)

func cssCounterReset(d: CSSDeclaration): Opt[seq[CSSCounterReset]] =
  template die =
    return err()
  var r: CSSCounterReset
  var s = false
  var res: seq[CSSCounterReset]
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
        res.add(r)
        s = false
      else:
        die
  return ok(res)

func cssMaxMinSize(cval: CSSComponentValue): Opt[CSSLength] =
  if isToken(cval):
    let tok = getToken(cval)
    case tok.tokenType
    of CSS_IDENT_TOKEN:
      if tok.value.equalsIgnoreCase("none"):
        return ok(CSSLengthAuto)
    of CSS_NUMBER_TOKEN, CSS_DIMENSION_TOKEN, CSS_PERCENTAGE_TOKEN:
      return cssLength(tok, allow_negative = false)
    else: discard
  return err()

#TODO should be URL (parsed with baseurl of document...)
func cssURL(cval: CSSComponentValue): Option[string] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok == CSS_URL_TOKEN:
      return some(tok.value)
  elif cval of CSSFunction:
    let fun = CSSFunction(cval)
    if fun.name.equalsIgnoreCase("url") or fun.name.equalsIgnoreCase("src"):
      for x in fun.value:
        if not isToken(x):
          break
        let x = getToken(x)
        if x == CSS_WHITESPACE_TOKEN:
          discard
        elif x == CSS_STRING_TOKEN:
          return some(x.value)
        else:
          break

#TODO this should be bg-image, add gradient, etc etc
func cssImage(cval: CSSComponentValue): Opt[CSSContent] =
  if isToken(cval):
    #TODO bg-image only
    let tok = getToken(cval)
    if tok.tokenType == CSS_IDENT_TOKEN and tok.value == "none":
      return ok(CSSContent(t: CONTENT_IMAGE, s: ""))
  let url = cssURL(cval)
  if url.isSome:
    return ok(CSSContent(t: CONTENT_IMAGE, s: url.get))
  return err()

func cssInteger(cval: CSSComponentValue, range: Slice[int]): Opt[int] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == CSS_NUMBER_TOKEN:
      if tok.nvalue in float64(range.a)..float64(range.b):
        return ok(int(tok.nvalue))
  return err()

func cssFloat(cval: CSSComponentValue): Opt[CSSFloat] =
  const FloatMap = {
    "none": FLOAT_NONE,
    "left": FLOAT_LEFT,
    "right": FLOAT_RIGHT
  }
  return cssIdent(FloatMap, cval)

func cssVisibility(cval: CSSComponentValue): Opt[CSSVisibility] =
  const VisibilityMap = {
    "visible": VISIBILITY_VISIBLE,
    "hidden": VISIBILITY_HIDDEN,
    "collapse": VISIBILITY_COLLAPSE
  }
  return cssIdent(VisibilityMap, cval)

func cssBoxSizing(cval: CSSComponentValue): Opt[CSSBoxSizing] =
  const BoxSizingMap = {
    "border-box": BOX_SIZING_BORDER_BOX,
    "content-box": BOX_SIZING_CONTENT_BOX
  }
  return cssIdent(BoxSizingMap, cval)

func cssClear(cval: CSSComponentValue): Opt[CSSClear] =
  const ClearMap = {
    "none": CLEAR_NONE,
    "left": CLEAR_LEFT,
    "right": CLEAR_RIGHT,
    "both": CLEAR_BOTH,
    "inline-start": CLEAR_INLINE_START,
    "inline-end": CLEAR_INLINE_END
  }
  return cssIdent(ClearMap, cval)

func cssTextTransform(cval: CSSComponentValue): Opt[CSSTextTransform] =
  const TextTransformMap = {
    "none": TEXT_TRANSFORM_NONE,
    "capitalize": TEXT_TRANSFORM_CAPITALIZE,
    "uppercase": TEXT_TRANSFORM_UPPERCASE,
    "lowercase": TEXT_TRANSFORM_LOWERCASE,
    "full-width": TEXT_TRANSFORM_FULL_WIDTH,
    "full-size-kana": TEXT_TRANSFORM_FULL_SIZE_KANA,
    "-cha-half-width": TEXT_TRANSFORM_CHA_HALF_WIDTH
  }
  return cssIdent(TextTransformMap, cval)

proc getValueFromDecl(val: CSSComputedValue, d: CSSDeclaration,
    vtype: CSSValueType, ptype: CSSPropertyType): Err[void] =
  var i = 0
  d.value.skipWhitespace(i)
  if i >= d.value.len:
    return err()
  let cval = d.value[i]
  inc i
  case vtype
  of VALUE_COLOR:
    val.color = ?cssColor(cval)
  of VALUE_LENGTH:
    case ptype
    of PROPERTY_WORD_SPACING:
      val.length = ?cssWordSpacing(cval)
    of PROPERTY_LINE_HEIGHT:
      val.length = ?cssLineHeight(cval)
    of PROPERTY_MAX_WIDTH, PROPERTY_MAX_HEIGHT, PROPERTY_MIN_WIDTH,
       PROPERTY_MIN_HEIGHT:
      val.length = ?cssMaxMinSize(cval)
    of PROPERTY_PADDING_LEFT, PROPERTY_PADDING_RIGHT, PROPERTY_PADDING_TOP,
       PROPERTY_PADDING_BOTTOM:
      val.length = ?cssLength(cval, has_auto = false)
    else:
      val.length = ?cssLength(cval)
  of VALUE_FONT_STYLE:
    val.fontstyle = ?cssFontStyle(cval)
  of VALUE_DISPLAY:
    val.display = ?cssDisplay(cval)
  of VALUE_CONTENT:
    val.content = cssContent(d)
  of VALUE_WHITE_SPACE:
    val.whitespace = ?cssWhiteSpace(cval)
  of VALUE_INTEGER:
    if ptype == PROPERTY_FONT_WEIGHT:
      val.integer = ?cssFontWeight(cval)
    elif ptype == PROPERTY_CHA_COLSPAN:
      val.integer = ?cssInteger(cval, 1 .. 1000)
    elif ptype == PROPERTY_CHA_ROWSPAN:
      val.integer = ?cssInteger(cval, 0 .. 65534)
  of VALUE_TEXT_DECORATION:
    val.textdecoration = ?cssTextDecoration(d)
  of VALUE_WORD_BREAK:
    val.wordbreak = ?cssWordBreak(cval)
  of VALUE_LIST_STYLE_TYPE:
    val.liststyletype = ?cssListStyleType(cval)
  of VALUE_VERTICAL_ALIGN:
    val.verticalalign = ?cssVerticalAlign(cval)
  of VALUE_TEXT_ALIGN:
    val.textalign = ?cssTextAlign(cval)
  of VALUE_LIST_STYLE_POSITION:
    val.liststyleposition = ?cssListStylePosition(cval)
  of VALUE_POSITION:
    val.position = ?cssPosition(cval)
  of VALUE_CAPTION_SIDE:
    val.captionside = ?cssCaptionSide(cval)
  of VALUE_BORDER_COLLAPSE:
    val.bordercollapse = ?cssBorderCollapse(cval)
  of VALUE_LENGTH2:
    val.length2.a = ?cssAbsoluteLength(cval)
    d.value.skipWhitespace(i)
    if i >= d.value.len:
      val.length2.b = val.length2.a
    else:
      let cval = d.value[i]
      val.length2.b = ?cssAbsoluteLength(cval)
  of VALUE_QUOTES:
    val.quotes = ?cssQuotes(d)
  of VALUE_COUNTER_RESET:
    val.counterreset = ?cssCounterReset(d)
  of VALUE_IMAGE:
    val.image = ?cssImage(cval)
  of VALUE_FLOAT:
    val.float = ?cssFloat(cval)
  of VALUE_VISIBILITY:
    val.visibility = ?cssVisibility(cval)
  of VALUE_BOX_SIZING:
    val.boxsizing = ?cssBoxSizing(cval)
  of VALUE_CLEAR:
    val.clear = ?cssClear(cval)
  of VALUE_TEXT_TRANSFORM:
    val.texttransform = ?cssTextTransform(cval)
  of VALUE_BGCOLOR_IS_CANVAS:
    return err() # internal value
  of VALUE_NONE:
    discard
  return ok()

func getInitialColor(t: CSSPropertyType): CellColor =
  case t
  of PROPERTY_COLOR:
    return Colors["white"].cellColor()
  of PROPERTY_BACKGROUND_COLOR:
    return Colors["transparent"].cellColor()
  else:
    return Colors["black"].cellColor()

func getInitialLength(t: CSSPropertyType): CSSLength =
  case t
  of PROPERTY_WIDTH, PROPERTY_HEIGHT, PROPERTY_WORD_SPACING,
     PROPERTY_LINE_HEIGHT, PROPERTY_LEFT, PROPERTY_RIGHT, PROPERTY_TOP,
     PROPERTY_BOTTOM, PROPERTY_MAX_WIDTH, PROPERTY_MAX_HEIGHT,
     PROPERTY_MIN_WIDTH, PROPERTY_MIN_HEIGHT:
    return CSSLengthAuto
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
    nv = CSSComputedValue(v: v, color: getInitialColor(t))
  of VALUE_DISPLAY:
    nv = CSSComputedValue(v: v, display: DISPLAY_INLINE)
  of VALUE_WORD_BREAK:
    nv = CSSComputedValue(v: v, wordbreak: WORD_BREAK_NORMAL)
  of VALUE_LENGTH:
    nv = CSSComputedValue(v: v, length: getInitialLength(t))
  of VALUE_INTEGER:
    nv = CSSComputedValue(v: v, integer: getInitialInteger(t))
  of VALUE_QUOTES:
    nv = CSSComputedValue(v: v, quotes: CSSQuotes(auto: true))
  else:
    nv = CSSComputedValue(v: v)
  return nv

func getInitialTable(): array[CSSPropertyType, CSSComputedValue] =
  for i in low(result)..high(result):
    result[i] = calcInitial(i)

let defaultTable = getInitialTable()

template getDefault(t: CSSPropertyType): CSSComputedValue =
  {.cast(noSideEffect).}:
    defaultTable[t]

func getComputedValue(d: CSSDeclaration, ptype: CSSPropertyType,
    vtype: CSSValueType): Opt[CSSComputedEntry] =
  let global = cssGlobal(d)
  let val = CSSComputedValue(v: vtype)
  if global != VALUE_NOGLOBAL:
    return ok((ptype, val, global))
  ?val.getValueFromDecl(d, vtype, ptype)
  return ok((ptype, val, global))

func lengthShorthand(d: CSSDeclaration, props: array[4, CSSPropertyType]):
    Opt[seq[CSSComputedEntry]] =
  var i = 0
  var cvals: seq[CSSComponentValue]
  while i < d.value.len:
    if d.value[i] != CSS_WHITESPACE_TOKEN:
      cvals.add(d.value[i])
    inc i
  var res: seq[CSSComputedEntry]
  case cvals.len
  of 1: # top, bottom, left, right
    for ptype in props:
      let vtype = valueType(ptype)
      let val = CSSComputedValue(v: vtype)
      ?val.getValueFromDecl(d, vtype, ptype)
      res.add((ptype, val, cssGlobal(d)))
  of 2: # top, bottom | left, right
    for i in 0 ..< props.len:
      let ptype = props[i]
      let vtype = valueType(ptype)
      let val = CSSComputedValue(v: vtype)
      val.length = ?cssLength(cvals[i mod 2])
      res.add((ptype, val, cssGlobal(d)))
  of 3: # top | left, right | bottom
    for i in 0 ..< props.len:
      let ptype = props[i]
      let vtype = valueType(ptype)
      let val = CSSComputedValue(v: vtype)
      let j = if i == 0:
        0 # top
      elif i == 3:
        2 # bottom
      else:
        1 # left, right
      val.length = ?cssLength(cvals[j])
      res.add((ptype, val, cssGlobal(d)))
  of 4: # top | right | bottom | left
    for i in 0 ..< props.len:
      let ptype = props[i]
      let vtype = valueType(ptype)
      let val = CSSComputedValue(v: vtype)
      val.length = ?cssLength(cvals[i])
      res.add((ptype, val, cssGlobal(d)))
  else: discard
  return ok(res)

const PropertyMarginSpec = [
  PROPERTY_MARGIN_TOP, PROPERTY_MARGIN_RIGHT, PROPERTY_MARGIN_BOTTOM,
  PROPERTY_MARGIN_LEFT
]

const PropertyPaddingSpec = [
  PROPERTY_PADDING_TOP, PROPERTY_PADDING_RIGHT, PROPERTY_PADDING_BOTTOM,
  PROPERTY_PADDING_LEFT
]

proc getComputedValues0(res: var seq[CSSComputedEntry], d: CSSDeclaration):
    Err[void] =
  case shorthandType(d.name)
  of SHORTHAND_NONE:
    let ptype = propertyType(d.name)
    let vtype = valueType(ptype)
    res.add(?getComputedValue(d, ptype, vtype))
  of SHORTHAND_ALL:
    let global = cssGlobal(d)
    if global != VALUE_NOGLOBAL:
      for ptype in CSSPropertyType:
        let vtype = valueType(ptype)
        let val = CSSComputedValue(v: vtype)
        res.add((ptype, val, global))
  of SHORTHAND_MARGIN:
    res.add(?lengthShorthand(d, PropertyMarginSpec))
  of SHORTHAND_PADDING:
    res.add(?lengthShorthand(d, PropertyPaddingSpec))
  of SHORTHAND_BACKGROUND:
    let global = cssGlobal(d)
    let bgcolorptype = PROPERTY_BACKGROUND_COLOR
    let bgcolorval = CSSComputedValue(v: valueType(bgcolorptype))
    let bgimageptype = PROPERTY_BACKGROUND_IMAGE
    let bgimageval = CSSComputedValue(v: valueType(bgimageptype))
    if global == VALUE_NOGLOBAL:
      for tok in d.value:
        if tok == CSS_WHITESPACE_TOKEN:
          continue
        let r = cssImage(tok)
        if r.isOk:
          bgimageval.image = r.get
          res.add((bgimageptype, bgimageval, global))
        else:
          let r = cssColor(tok)
          if r.isOk:
            bgcolorval.color = r.get
            res.add((bgcolorptype, bgcolorval, global))
    else:
      res.add((bgcolorptype, bgcolorval, global))
  of SHORTHAND_LIST_STYLE:
    let global = cssGlobal(d)
    let positionptype = PROPERTY_LIST_STYLE_POSITION
    let positionval = CSSComputedValue(v: valueType(positionptype))
    let typeptype = PROPERTY_LIST_STYLE_TYPE
    let typeval = CSSComputedValue(v: valueType(typeptype))
    if global == VALUE_NOGLOBAL:
      for tok in d.value:
        let r = cssListStylePosition(tok)
        if r.isOk:
          positionval.liststyleposition = r.get
          res.add((positionptype, positionval, global))
        else:
          let r = cssListStyleType(tok)
          if r.isOk:
            typeval.liststyletype = r.get
            res.add((typeptype, typeval, global))
          else:
            #TODO list-style-image
            discard
  return ok()

proc getComputedValues(d: CSSDeclaration): seq[CSSComputedEntry] =
  var res: seq[CSSComputedEntry] = @[]
  if res.getComputedValues0(d).isOk:
    return res
  return @[]

proc addValues*(builder: var CSSComputedValuesBuilder,
    decls: seq[CSSDeclaration], origin: CSSOrigin) =
  for decl in decls:
    if decl.important:
      builder.importantProperties[origin].add(getComputedValues(decl))
    else:
      builder.normalProperties[origin].add(getComputedValues(decl))

proc applyValue(vals: CSSComputedValues, prop: CSSPropertyType,
    val: CSSComputedValue, global: CSSGlobalValueType,
    parent: CSSComputedValues, previousOrigin: CSSComputedValues) =
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
  result[] = props[]

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

func buildComputedValues*(builder: CSSComputedValuesBuilder):
    CSSComputedValues =
  new(result)
  var previousOrigins: array[CSSOrigin, CSSComputedValues]
  block:
    let origin = ORIGIN_USER_AGENT
    for build in builder.normalProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent, nil)
    previousOrigins[origin] = result.copyProperties()
  # Presentational hints override user agent style, but respect user/author
  # style.
  if builder.preshints != nil:
    for prop in CSSPropertyType:
      if builder.preshints[prop] != nil:
        result[prop] = builder.preshints[prop]
  block:
    let origin = ORIGIN_USER
    let prevOrigin = ORIGIN_USER_AGENT
    for build in builder.normalProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[prevOrigin])
    # save user origins so author can use them
    previousOrigins[origin] = result.copyProperties()
  block:
    let origin = ORIGIN_AUTHOR
    let prevOrigin = ORIGIN_USER
    for build in builder.normalProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[prevOrigin])
    # no need to save user origins
  block:
    let origin = ORIGIN_AUTHOR
    let prevOrigin = ORIGIN_USER
    for build in builder.importantProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[prevOrigin])
    # important, so no need to save origins
  block:
    let origin = ORIGIN_USER
    let prevOrigin = ORIGIN_USER_AGENT
    for build in builder.importantProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[prevOrigin])
    # important, so no need to save origins
  block:
    let origin = ORIGIN_USER_AGENT
    for build in builder.importantProperties[origin]:
      result.applyValue(build.t, build.val, build.global, builder.parent, nil)
    # important, so no need to save origins
  # set defaults
  for prop in CSSPropertyType:
    if result[prop] == nil:
      if inherited(prop) and builder.parent != nil and
          builder.parent[prop] != nil:
        result[prop] = builder.parent[prop]
      else:
        result[prop] = getDefault(prop)
  if result{"float"} != FLOAT_NONE:
    case result{"display"}
    of DISPLAY_BLOCK, DISPLAY_TABLE, DISPLAY_LIST_ITEM, DISPLAY_NONE,
        DISPLAY_FLOW_ROOT:
       #TODO flex, grid
      discard
      {.linearScanEnd.}
    of DISPLAY_INLINE, DISPLAY_INLINE_BLOCK, DISPLAY_TABLE_ROW,
        DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_COLUMN,
        DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_CELL, DISPLAY_TABLE_CAPTION,
        DISPLAY_TABLE_HEADER_GROUP, DISPLAY_TABLE_FOOTER_GROUP:
      result{"display"} = DISPLAY_BLOCK
    of DISPLAY_INLINE_TABLE:
      result{"display"} = DISPLAY_TABLE
