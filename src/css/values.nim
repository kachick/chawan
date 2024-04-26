import std/macros
import std/options
import std/strutils
import std/tables
import std/unicode

import css/cssparser
import css/selectorparser
import img/bitmap
import layout/layoutunit
import types/color
import types/opt
import types/winattrs
import utils/twtstr

export selectorparser.PseudoElem

type
  CSSShorthandType = enum
    cstNone = ""
    cstAll = "all"
    cstMargin = "margin"
    cstPadding = "padding"
    cstBackground = "background"
    cstListStyle = "list-style"
    cstFlex = "flex"
    cstFlexFlow = "flex-flow"

  CSSUnit* = enum
    cuCm, cuMm, cuIn, cuPx, cuPt, cuPc, cuEm, cuEx, cuCh, cuRem, cuVw, cuVh,
    cuVmin, cuVmax, cuPerc, cuIc

  CSSPropertyType* = enum
    cptNone = ""
    cptColor = "color"
    cptMarginTop = "margin-top"
    cptMarginLeft = "margin-left"
    cptMarginRight = "margin-right"
    cptMarginBottom = "margin-bottom"
    cptFontStyle = "font-style"
    cptDisplay = "display"
    cptContent = "content"
    cptWhiteSpace = "white-space"
    cptFontWeight = "font-weight"
    cptTextDecoration = "text-decoration"
    cptWordBreak = "word-break"
    cptWidth = "width"
    cptHeight = "height"
    cptListStyleType = "list-style-type"
    cptPaddingTop = "padding-top"
    cptPaddingLeft = "padding-left"
    cptPaddingRight = "padding-right"
    cptPaddingBottom = "padding-bottom"
    cptWordSpacing = "word-spacing"
    cptVerticalAlign = "vertical-align"
    cptLineHeight = "line-height"
    cptTextAlign = "text-align"
    cptListStylePosition = "list-style-position"
    cptBackgroundColor = "background-color"
    cptPosition = "position"
    cptLeft = "left"
    cptRight = "right"
    cptTop = "top"
    cptBottom = "bottom"
    cptCaptionSide = "caption-side"
    cptBorderSpacing = "border-spacing"
    cptBorderCollapse = "border-collapse"
    cptQuotes = "quotes"
    cptCounterReset = "counter-reset"
    cptMaxWidth = "max-width"
    cptMaxHeight = "max-height"
    cptMinWidth = "min-width"
    cptMinHeight = "min-height"
    cptBackgroundImage = "background-image"
    cptChaColspan = "-cha-colspan"
    cptChaRowspan = "-cha-rowspan"
    cptFloat = "float"
    cptVisibility = "visibility"
    cptBoxSizing = "box-sizing"
    cptClear = "clear"
    cptTextTransform = "text-transform"
    cptBgcolorIsCanvas = "-cha-bgcolor-is-canvas"
    cptFlexDirection = "flex-direction"
    cptFlexWrap = "flex-wrap"
    cptFlexGrow = "flex-grow"
    cptFlexShrink = "flex-shrink"
    cptFlexBasis = "flex-basis"

  CSSValueType* = enum
    cvtNone = ""
    cvtLength = "length"
    cvtColor = "color"
    cvtContent = "content"
    cvtDisplay = "display"
    cvtFontStyle = "fontstyle"
    cvtWhiteSpace = "whitespace"
    cvtInteger = "integer"
    cvtTextDecoration = "textdecoration"
    cvtWordBreak = "wordbreak"
    cvtListStyleType = "liststyletype"
    cvtVerticalAlign = "verticalalign"
    cvtTextAlign = "textalign"
    cvtListStylePosition = "liststyleposition"
    cvtPosition = "position"
    cvtCaptionSide = "captionside"
    cvtLength2 = "length2"
    cvtBorderCollapse = "bordercollapse"
    cvtQuotes = "quotes"
    cvtCounterReset = "counterreset"
    cvtImage = "image"
    cvtFloat = "float"
    cvtVisibility = "visibility"
    cvtBoxSizing = "boxsizing"
    cvtClear = "clear"
    cvtTextTransform = "texttransform"
    cvtBgcolorIsCanvas = "bgcoloriscanvas"
    cvtFlexDirection = "flexdirection"
    cvtFlexWrap = "flexwrap"
    cvtNumber = "number"

  CSSGlobalValueType* = enum
    cvtNoglobal, cvtInitial, cvtInherit, cvtRevert, cvtUnset

  CSSDisplay* = enum
    DisplayNone, DisplayInline, DisplayBlock, DisplayListItem,
    DisplayInlineBlock, DisplayTable, DisplayInlineTable, DisplayTableRowGroup,
    DisplayTableHeaderGroup, DisplayTableFooterGroup, DisplayTableColumnGroup,
    DisplayTableRow, DisplayTableColumn, DisplayTableCell, DisplayTableCaption,
    DisplayFlowRoot, DisplayFlex, DisplayInlineFlex

  CSSWhitespace* = enum
    WhitespaceNormal, WhitespaceNowrap, WhitespacePre, WhitespacePreLine,
    WhitespacePreWrap

  CSSFontStyle* = enum
    FontStyleNormal, FontStyleItalic, FontStyleOblique

  CSSPosition* = enum
    PositionStatic, PositionRelative, PositionAbsolute, PositionFixed,
    PositionSticky

  CSSTextDecoration* = enum
    TextDecorationNone, TextDecorationUnderline, TextDecorationOverline,
    TextDecorationLineThrough, TextDecorationBlink

  CSSWordBreak* = enum
    WordBreakNormal, WordBreakBreakAll, WordBreakKeepAll

  CSSListStyleType* = enum
    ListStyleTypeNone, ListStyleTypeDisc, ListStyleTypeCircle,
    ListStyleTypeSquare, ListStyleTypeDecimal,
    ListStyleTypeDisclosureClosed, ListStyleTypeDisclosureOpen,
    ListStyleTypeCjkEarthlyBranch, ListStyleTypeCjkHeavenlyStem,
    ListStyleTypeLowerRoman, ListStyleTypeUpperRoman,
    ListStyleTypeLowerAlpha, ListStyleTypeUpperAlpha,
    ListStyleTypeLowerGreek,
    ListStyleTypeHiragana, ListStyleTypeHiraganaIroha,
    ListStyleTypeKatakana, ListStyleTypeKatakanaIroha,
    ListStyleTypeJapaneseInformal

  CSSVerticalAlign2* = enum
    VerticalAlignBaseline, VerticalAlignSub, VerticalAlignSuper,
    VerticalAlignTextTop, VerticalAlignTextBottom, VerticalAlignMiddle,
    VerticalAlignTop, VerticalAlignBottom

  CSSTextAlign* = enum
    TextAlignStart, TextAlignEnd, TextAlignLeft, TextAlignRight,
    TextAlignCenter, TextAlignJustify, TextAlignChaCenter,
    TextAlignChaLeft, TextAlignChaRight

  CSSListStylePosition* = enum
    ListStylePositionOutside, ListStylePositionInside

  CSSCaptionSide* = enum
    CaptionSideTop, CaptionSideBottom, CaptionSideBlockStart,
    CaptionSideBlockEnd,

  CSSBorderCollapse* = enum
    BorderCollapseSeparate, BorderCollapseCollapse

  CSSContentType* = enum
    ContentString, ContentOpenQuote, ContentCloseQuote,
    ContentNoOpenQuote, ContentNoCloseQuote, ContentImage,
    ContentVideo, ContentAudio, ContentNewline

  CSSFloat* = enum
    FloatNone, FloatLeft, FloatRight

  CSSVisibility* = enum
    VisibilityVisible, VisibilityHidden, VisibilityCollapse

  CSSBoxSizing* = enum
    BoxSizingContentBox, BoxSizingBorderBox

  CSSClear* = enum
    ClearNone, ClearLeft, ClearRight, ClearBoth, ClearInlineStart,
    ClearInlineEnd

  CSSTextTransform* = enum
    TextTransformNone, TextTransformCapitalize, TextTransformUppercase,
    TextTransformLowercase, TextTransformFullWidth,
    TextTransformFullSizeKana, TextTransformChaHalfWidth

  CSSFlexDirection* = enum
    FlexDirectionRow, FlexDirectionRowReverse, FlexDirectionColumn,
    FlexDirectionColumnReverse

  CSSFlexWrap* = enum
    FlexWrapNowrap, FlexWrapWrap, FlexWrapWrapReverse

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
    of cvtColor:
      color*: CellColor
    of cvtLength:
      length*: CSSLength
    of cvtFontStyle:
      fontstyle*: CSSFontStyle
    of cvtDisplay:
      display*: CSSDisplay
    of cvtContent:
      content*: seq[CSSContent]
    of cvtQuotes:
      quotes*: CSSQuotes
    of cvtWhiteSpace:
      whitespace*: CSSWhitespace
    of cvtInteger:
      integer*: int
    of cvtNumber:
      number*: float64
    of cvtTextDecoration:
      textdecoration*: set[CSSTextDecoration]
    of cvtWordBreak:
      wordbreak*: CSSWordBreak
    of cvtListStyleType:
      liststyletype*: CSSListStyleType
    of cvtVerticalAlign:
      verticalalign*: CSSVerticalAlign
    of cvtTextAlign:
      textalign*: CSSTextAlign
    of cvtListStylePosition:
      liststyleposition*: CSSListStylePosition
    of cvtPosition:
      position*: CSSPosition
    of cvtCaptionSide:
      captionside*: CSSCaptionSide
    of cvtLength2:
      length2*: tuple[a, b: CSSLength]
    of cvtBorderCollapse:
      bordercollapse*: CSSBorderCollapse
    of cvtCounterReset:
      counterreset*: seq[CSSCounterReset]
    of cvtImage:
      image*: CSSContent
    of cvtFloat:
      float*: CSSFloat
    of cvtVisibility:
      visibility*: CSSVisibility
    of cvtBoxSizing:
      boxsizing*: CSSBoxSizing
    of cvtClear:
      clear*: CSSClear
    of cvtTextTransform:
      texttransform*: CSSTextTransform
    of cvtBgcolorIsCanvas:
      bgcoloriscanvas*: bool
    of cvtFlexDirection:
      flexdirection*: CSSFlexDirection
    of cvtFlexWrap:
      flexwrap*: CSSFlexWrap
    of cvtNone: discard

  CSSComputedValues* = ref array[CSSPropertyType, CSSComputedValue]

  CSSOrigin* = enum
    coUserAgent
    coUser
    coAuthor

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

const ShorthandNames = block:
  var tab = initTable[string, CSSShorthandType]()
  for t in CSSShorthandType:
    if $t != "":
      tab[$t] = t
  tab

const PropertyNames = block:
  var tab = initTable[string, CSSPropertyType]()
  for t in CSSPropertyType:
    if $t != "":
      tab[$t] = t
  tab

const ValueTypes = [
  cptNone: cvtNone,
  cptColor: cvtColor,
  cptMarginTop: cvtLength,
  cptMarginLeft: cvtLength,
  cptMarginRight: cvtLength,
  cptMarginBottom: cvtLength,
  cptFontStyle: cvtFontStyle,
  cptDisplay: cvtDisplay,
  cptContent: cvtContent,
  cptWhiteSpace: cvtWhiteSpace,
  cptFontWeight: cvtInteger,
  cptTextDecoration: cvtTextDecoration,
  cptWordBreak: cvtWordBreak,
  cptWidth: cvtLength,
  cptHeight: cvtLength,
  cptListStyleType: cvtListStyleType,
  cptPaddingTop: cvtLength,
  cptPaddingLeft: cvtLength,
  cptPaddingRight: cvtLength,
  cptPaddingBottom: cvtLength,
  cptWordSpacing: cvtLength,
  cptVerticalAlign: cvtVerticalAlign,
  cptLineHeight: cvtLength,
  cptTextAlign: cvtTextAlign,
  cptListStylePosition: cvtListStylePosition,
  cptBackgroundColor: cvtColor,
  cptPosition: cvtPosition,
  cptLeft: cvtLength,
  cptRight: cvtLength,
  cptTop: cvtLength,
  cptBottom: cvtLength,
  cptCaptionSide: cvtCaptionSide,
  cptBorderSpacing: cvtLength2,
  cptBorderCollapse: cvtBorderCollapse,
  cptQuotes: cvtQuotes,
  cptCounterReset: cvtCounterReset,
  cptMaxWidth: cvtLength,
  cptMaxHeight: cvtLength,
  cptMinWidth: cvtLength,
  cptMinHeight: cvtLength,
  cptBackgroundImage: cvtImage,
  cptChaColspan: cvtInteger,
  cptChaRowspan: cvtInteger,
  cptFloat: cvtFloat,
  cptVisibility: cvtVisibility,
  cptBoxSizing: cvtBoxSizing,
  cptClear: cvtClear,
  cptTextTransform: cvtTextTransform,
  cptBgcolorIsCanvas: cvtBgcolorIsCanvas,
  cptFlexDirection: cvtFlexDirection,
  cptFlexWrap: cvtFlexWrap,
  cptFlexGrow: cvtNumber,
  cptFlexShrink: cvtNumber,
  cptFlexBasis: cvtLength
]

const InheritedProperties = {
  cptColor, cptFontStyle, cptWhiteSpace, cptFontWeight, cptTextDecoration,
  cptWordBreak, cptListStyleType, cptWordSpacing, cptLineHeight, cptTextAlign,
  cptListStylePosition, cptCaptionSide, cptBorderSpacing, cptBorderCollapse,
  cptQuotes, cptVisibility, cptTextTransform
}

func getPropInheritedArray(): array[CSSPropertyType, bool] =
  for prop in CSSPropertyType:
    if prop in InheritedProperties:
      result[prop] = true
    else:
      result[prop] = false

const InheritedArray = getPropInheritedArray()

func shorthandType(s: string): CSSShorthandType =
  return ShorthandNames.getOrDefault(s.toLowerAscii(), cstNone)

func propertyType(s: string): CSSPropertyType =
  return PropertyNames.getOrDefault(s.toLowerAscii(), cptNone)

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
  of cvtColor:
    result &= $val.color
  of cvtImage:
    result &= $val.image
  of cvtLength:
    result &= $val.length
  else:
    result = $val.v

macro `{}`*(vals: CSSComputedValues; s: static string): untyped =
  let t = propertyType(s)
  let vs = ident($valueType(t))
  return quote do:
    `vals`[CSSPropertyType(`t`)].`vs`

macro `{}=`*(vals: CSSComputedValues; s: static string, val: typed) =
  let t = propertyType(s)
  let v = valueType(t)
  let vs = ident($v)
  return quote do:
    `vals`[CSSPropertyType(`t`)] = CSSComputedValue(
      v: CSSValueType(`v`),
      `vs`: `val`
    )

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

func px*(l: CSSLength; window: WindowAttributes; p: LayoutUnit): LayoutUnit
    {.inline.} =
  case l.unit
  of cuEm, cuRem: em_to_px(l.num, window)
  of cuCh: ch_to_px(l.num, window)
  of cuIc: ic_to_px(l.num, window)
  of cuEx: ex_to_px(l.num, window)
  of cuPerc: toLayoutUnit(toFloat64(p) * l.num / 100)
  of cuPx: toLayoutUnit(l.num)
  of cuCm: toLayoutUnit(l.num * 37.8)
  of cuMm: toLayoutUnit(l.num * 3.78)
  of cuIn: toLayoutUnit(l.num * 96)
  of cuPc: toLayoutUnit(l.num * 16)
  of cuPt: toLayoutUnit(l.num * 4 / 3)
  of cuVw: toLayoutUnit(float64(window.width_px) * l.num / 100)
  of cuVh: toLayoutUnit(float64(window.height_px) * l.num / 100)
  of cuVmin:
    toLayoutUnit(min(window.width_px, window.width_px) / 100 * l.num)
  of cuVmax:
    toLayoutUnit(max(window.width_px, window.width_px) / 100 * l.num)

func blockify*(display: CSSDisplay): CSSDisplay =
  case display
  of DisplayBlock, DisplayTable, DisplayListItem, DisplayNone, DisplayFlowRoot,
      DisplayFlex:
     #TODO grid
    return display
  of DisplayInline, DisplayInlineBlock, DisplayTableRow,
      DisplayTableRowGroup, DisplayTableColumn,
      DisplayTableColumnGroup, DisplayTableCell, DisplayTableCaption,
      DisplayTableHeaderGroup, DisplayTableFooterGroup:
    return DisplayBlock
  of DisplayInlineTable:
    return DisplayTable
  of DisplayInlineFlex:
    return DisplayFlex

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

func numToBase(n: int; map: openArray[Rune]): string =
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

func numToFixed(n: int; map: openArray[Rune]): string =
  let n = n - 1
  if n notin 0 .. map.high:
    return $n
  return $map[n]

func listMarker*(t: CSSListStyleType; i: int): string =
  case t
  of ListStyleTypeNone: return ""
  of ListStyleTypeDisc: return "• " # U+2022
  of ListStyleTypeCircle: return "○ " # U+25CB
  of ListStyleTypeSquare: return "□ " # U+25A1
  of ListStyleTypeDisclosureOpen: return "▶ " # U+25B6
  of ListStyleTypeDisclosureClosed: return "▼ " # U+25BC
  of ListStyleTypeDecimal: return $i & ". "
  of ListStyleTypeUpperRoman: return romanNumber(i) & ". "
  of ListStyleTypeLowerRoman: return romanNumberLower(i) & ". "
  of ListStyleTypeUpperAlpha: return numToBase(i, UpperAlphaMap) & ". "
  of ListStyleTypeLowerAlpha: return numToBase(i, LowerAlphaMap) & ". "
  of ListStyleTypeLowerGreek: return numToBase(i, LowerGreekMap) & ". "
  of ListStyleTypeHiragana: return numToBase(i, HiraganaMap) & "、"
  of ListStyleTypeHiraganaIroha:
    return numToBase(i, HiraganaIrohaMap) & "、"
  of ListStyleTypeKatakana: return numToBase(i, KatakanaMap) & "、"
  of ListStyleTypeKatakanaIroha:
    return numToBase(i, KatakanaIrohaMap) & "、"
  of ListStyleTypeCjkEarthlyBranch:
    return numToFixed(i, EarthlyBranchMap) & "、"
  of ListStyleTypeCjkHeavenlyStem:
    return numToFixed(i, HeavenlyStemMap) & "、"
  of ListStyleTypeJapaneseInformal: return japaneseNumber(i) & "、"

#TODO this should change by language
func quoteStart*(level: int): string =
  if level == 0:
    return "“"
  return "‘"

func quoteEnd*(level: int): string =
  if level == 0:
    return "“"
  return "‘"

const Colors: Table[string, ARGBColor] = ((func (): Table[string, ARGBColor] =
  for name, rgb in ColorsRGB:
    result[name] = rgb
  result["transparent"] = rgba(0x00, 0x00, 0x00, 0x00)
)())

const Units = {
  "%": cuPerc,
  "cm": cuCm,
  "mm": cuMm,
  "in": cuIn,
  "px": cuPx,
  "pt": cuPt,
  "pc": cuPc,
  "em": cuEm,
  "ex": cuEx,
  "ch": cuCh,
  "ic": cuCh,
  "rem": cuRem,
  "vw": cuVw,
  "vh": cuVh,
  "vmin": cuVmin,
  "vmax": cuVmax,
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
    if i >= s.len: return some(CSSLength(num: n, unit: cuPx))
  if s[i] == '.':
    inc i
    if i >= s.len: return some(CSSLength(num: n, unit: cuPx))
    var d = 1
    while i < s.len and s[i] in AsciiDigit:
      n += float64(decValue(s[i])) / float64(d)
      inc d
      inc i
  if i >= s.len: return some(CSSLength(num: n, unit: cuPx))
  if s[i] == '%': return some(CSSLength(num: n, unit: cuPerc))
  return some(CSSLength(num: n, unit: cuPx))

func skipWhitespace(vals: openArray[CSSComponentValue]; i: var int) =
  while i < vals.len:
    if vals[i] != cttWhitespace:
      break
    inc i

func parseARGB(value: openArray[CSSComponentValue]): Opt[CellColor] =
  var i = 0
  var commaMode = false
  template check_err(slash: bool) =
    #TODO calc, percentages, etc (cssnumber function or something)
    if not slash and i >= value.len or i < value.len and
        value[i] != cttNumber:
      return err()
  template next_value(first = false, slash = false) =
    inc i
    value.skipWhitespace(i)
    if i < value.len:
      if value[i] == cttComma and (commaMode or first):
        # legacy compatibility
        inc i
        value.skipWhitespace(i)
        commaMode = true
      elif commaMode:
        return err()
      elif slash:
        let tok = value[i]
        if tok != cttDelim or CSSToken(tok).cvalue != '/':
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
  if tok.tokenType == cttNumber:
    if tok.nvalue notin 0..255:
      return err() # invalid numeric ANSI color
    return ok(ANSIColor(tok.nvalue).cellColor())
  elif tok.tokenType == cttIdent:
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
    of cttHash:
      let c = parseHexColor(tok.value)
      if c.isSome:
        return ok(c.get.cellColor())
    of cttIdent:
      let s = tok.value.toLowerAscii()
      if s in Colors:
        return ok(Colors[s].cellColor())
    else: discard
  elif val of CSSFunction:
    let f = CSSFunction(val)
    if f.name.equalsIgnoreCase("rgb") or f.name.equalsIgnoreCase("rgba"):
      return parseARGB(f.value)
    elif f.name.equalsIgnoreCase("-cha-ansi"):
      return parseANSI(f.value)
  return err()

func isToken(cval: CSSComponentValue): bool {.inline.} =
  cval of CSSToken

func getToken(cval: CSSComponentValue): CSSToken {.inline.} =
  CSSToken(cval)

func cssIdent[T](map: static openArray[(string, T)], cval: CSSComponentValue):
    Opt[T] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == cttIdent:
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

func cssIdentFirst[T](map: static openArray[(string, T)]; d: CSSDeclaration):
    Opt[T] =
  if d.value.len == 1:
    return cssIdent(map, d.value[0])
  return err()

func cssLength*(val: CSSComponentValue; has_auto: static bool = true;
    allow_negative: static bool = true): Opt[CSSLength] =
  block nofail:
    if val of CSSToken:
      let tok = CSSToken(val)
      case tok.tokenType
      of cttNumber:
        if tok.nvalue == 0:
          return ok(CSSLength(num: 0, unit: cuPx))
      of cttPercentage:
        when not allow_negative:
          if tok.nvalue < 0:
            break nofail
        return cssLength(tok.nvalue, "%")
      of cttDimension:
        when not allow_negative:
          if tok.nvalue < 0:
            break nofail
        return cssLength(tok.nvalue, tok.unit)
      of cttIdent:
        when has_auto:
          if tok.value.equalsIgnoreCase("auto"):
            return ok(CSSLengthAuto)
      else: discard
  return err()

func cssAbsoluteLength(val: CSSComponentValue): Opt[CSSLength] =
  if val of CSSToken:
    let tok = CSSToken(val)
    case tok.tokenType
    of cttNumber:
      if tok.nvalue == 0:
        return ok(CSSLength(num: 0, unit: cuPx))
    of cttDimension:
      if tok.nvalue >= 0:
        return cssLength(tok.nvalue, tok.unit)
    else: discard
  return err()

func cssWordSpacing(cval: CSSComponentValue): Opt[CSSLength] =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of cttDimension:
      return cssLength(tok.nvalue, tok.unit)
    of cttIdent:
      if tok.value.equalsIgnoreCase("normal"):
        return ok(CSSLengthAuto)
    else: discard
  return err()

func cssGlobal(d: CSSDeclaration): CSSGlobalValueType =
  const GlobalMap = {
    "inherit": cvtInherit,
    "initial": cvtInitial,
    "unset": cvtUnset,
    "revert": cvtRevert
  }
  return cssIdentFirst(GlobalMap, d).get(cvtNoglobal)

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
      of cttIdent:
        if res.qs.len > 0: die
        if tok.value.equalsIgnoreCase("auto"):
          res.auto = true
        elif tok.value.equalsIgnoreCase("none"):
          if d.value.len != 1:
            die
        die
      of cttString:
        if sa:
          pair.e = tok.value
          res.qs.add(pair)
          sa = false
        else:
          pair.s = tok.value
          sa = true
      of cttWhitespace: discard
      else: die
  if sa:
    die
  return ok(res)

func cssContent(d: CSSDeclaration): seq[CSSContent] =
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      case tok.tokenType
      of cttIdent:
        if tok.value == "/":
          break
        elif tok.value.equalsIgnoreCase("open-quote"):
          result.add(CSSContent(t: ContentOpenQuote))
        elif tok.value.equalsIgnoreCase("no-open-quote"):
          result.add(CSSContent(t: ContentNoOpenQuote))
        elif tok.value.equalsIgnoreCase("close-quote"):
          result.add(CSSContent(t: ContentCloseQuote))
        elif tok.value.equalsIgnoreCase("no-close-quote"):
          result.add(CSSContent(t: ContentNoCloseQuote))
      of cttString:
        result.add(CSSContent(t: ContentString, s: tok.value))
      else: return

func cssDisplay(cval: CSSComponentValue): Opt[CSSDisplay] =
  const DisplayMap = {
    "block": DisplayBlock,
    "inline": DisplayInline,
    "list-item": DisplayListItem,
    "inline-block": DisplayInlineBlock,
    "table": DisplayTable,
    "table-row": DisplayTableRow,
    "table-cell": DisplayTableCell,
    "table-column": DisplayTableColumn,
    "table-column-group": DisplayTableColumnGroup,
    "inline-table": DisplayInlineTable,
    "table-row-group": DisplayTableRowGroup,
    "table-header-group": DisplayTableHeaderGroup,
    "table-footer-group": DisplayTableFooterGroup,
    "table-caption": DisplayTableCaption,
    "flow-root": DisplayFlowRoot,
    "flex": DisplayFlex,
    "inline-flex": DisplayInlineFlex,
    "none": DisplayNone
  }
  return cssIdent(DisplayMap, cval)

func cssFontStyle(cval: CSSComponentValue): Opt[CSSFontStyle] =
  const FontStyleMap = {
    "normal": FontStyleNormal,
    "italic": FontStyleItalic,
    "oblique": FontStyleOblique
  }
  return cssIdent(FontStyleMap, cval)

func cssWhiteSpace(cval: CSSComponentValue): Opt[CSSWhitespace] =
  const WhiteSpaceMap = {
    "normal": WhitespaceNormal,
    "nowrap": WhitespaceNowrap,
    "pre": WhitespacePre,
    "pre-line": WhitespacePreLine,
    "pre-wrap": WhitespacePreWrap
  }
  return cssIdent(WhiteSpaceMap, cval)

func cssFontWeight(cval: CSSComponentValue): Opt[int] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == cttIdent:
      const FontWeightMap = {
        "normal": 400,
        "bold": 700,
        "lighter": 400,
        "bolder": 700
      }
      return cssIdent(FontWeightMap, cval)
    elif tok.tokenType == cttNumber:
      if tok.nvalue in 1f64..1000f64:
        return ok(int(tok.nvalue))
  return err()

func cssTextDecoration(d: CSSDeclaration): Opt[set[CSSTextDecoration]] =
  var s: set[CSSTextDecoration]
  for cval in d.value:
    if isToken(cval):
      let tok = getToken(cval)
      if tok.tokenType == cttIdent:
        if tok.value.equalsIgnoreCase("none"):
          if d.value.len != 1:
            return err()
          return ok(s)
        elif tok.value.equalsIgnoreCase("underline"):
          s.incl(TextDecorationUnderline)
        elif tok.value.equalsIgnoreCase("overline"):
          s.incl(TextDecorationOverline)
        elif tok.value.equalsIgnoreCase("line-through"):
          s.incl(TextDecorationLineThrough)
        elif tok.value.equalsIgnoreCase("blink"):
          s.incl(TextDecorationBlink)
        else:
          return err()
  return ok(s)

func cssWordBreak(cval: CSSComponentValue): Opt[CSSWordBreak] =
  const WordBreakMap = {
    "normal": WordBreakNormal,
    "break-all": WordBreakBreakAll,
    "keep-all": WordBreakKeepAll
  }
  return cssIdent(WordBreakMap, cval)

func cssListStyleType(cval: CSSComponentValue): Opt[CSSListStyleType] =
  const ListStyleMap = {
    "none": ListStyleTypeNone,
    "disc": ListStyleTypeDisc,
    "circle": ListStyleTypeCircle,
    "square": ListStyleTypeSquare,
    "decimal": ListStyleTypeDecimal,
    "disclosure-open": ListStyleTypeDisclosureOpen,
    "disclosure-closed": ListStyleTypeDisclosureClosed,
    "cjk-earthly-branch": ListStyleTypeCjkEarthlyBranch,
    "cjk-heavenly-stem": ListStyleTypeCjkHeavenlyStem,
    "upper-roman": ListStyleTypeUpperRoman,
    "lower-roman": ListStyleTypeLowerRoman,
    "upper-latin": ListStyleTypeUpperAlpha,
    "lower-latin": ListStyleTypeLowerAlpha,
    "upper-alpha": ListStyleTypeUpperAlpha,
    "lower-alpha": ListStyleTypeUpperAlpha,
    "lower-greek": ListStyleTypeLowerGreek,
    "hiragana": ListStyleTypeHiragana,
    "hiragana-iroha": ListStyleTypeHiraganaIroha,
    "katakana": ListStyleTypeKatakana,
    "katakana-iroha": ListStyleTypeKatakanaIroha,
    "japanese-informal": ListStyleTypeJapaneseInformal
  }
  return cssIdent(ListStyleMap, cval)

func cssVerticalAlign(cval: CSSComponentValue): Opt[CSSVerticalAlign] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == cttIdent:
      const VerticalAlignMap = {
        "baseline": VerticalAlignBaseline,
        "sub": VerticalAlignSub,
        "super": VerticalAlignSuper,
        "text-top": VerticalAlignTextBottom,
        "middle": VerticalAlignMiddle,
        "top": VerticalAlignTop,
        "bottom": VerticalAlignBottom
      }
      let va2 = ?cssIdent(VerticalAlignMap, cval)
      return ok(CSSVerticalAlign(
        keyword: va2
      ))
    else:
      return ok(CSSVerticalAlign(
        keyword: VerticalAlignBaseline,
        length: ?cssLength(tok, has_auto = false)
      ))
  return err()

func cssLineHeight(cval: CSSComponentValue): Opt[CSSLength] =
  if cval of CSSToken:
    let tok = CSSToken(cval)
    case tok.tokenType
    of cttNumber:
      return cssLength(tok.nvalue * 100, "%")
    of cttIdent:
      if tok.value == "normal":
        return ok(CSSLengthAuto)
    else:
      return cssLength(tok, has_auto = false)
  return err()

func cssTextAlign(cval: CSSComponentValue): Opt[CSSTextAlign] =
  const TextAlignMap = {
    "start": TextAlignStart,
    "end": TextAlignEnd,
    "left": TextAlignLeft,
    "right": TextAlignRight,
    "center": TextAlignCenter,
    "justify": TextAlignJustify,
    "-cha-center": TextAlignChaCenter
  }
  return cssIdent(TextAlignMap, cval)

func cssListStylePosition(cval: CSSComponentValue): Opt[CSSListStylePosition] =
  const ListStylePositionMap = {
    "inside": ListStylePositionInside,
    "outside": ListStylePositionOutside
  }
  return cssIdent(ListStylePositionMap, cval)

func cssPosition(cval: CSSComponentValue): Opt[CSSPosition] =
  const PositionMap = {
    "static": PositionStatic,
    "relative": PositionRelative,
    "absolute": PositionAbsolute,
    "fixed": PositionFixed,
    "sticky": PositionSticky
  }
  return cssIdent(PositionMap, cval)

func cssCaptionSide(cval: CSSComponentValue): Opt[CSSCaptionSide] =
  const CaptionSideMap = {
    "top": CaptionSideTop,
    "bottom": CaptionSideBottom,
    "block-start": CaptionSideBlockStart,
    "block-end": CaptionSideBlockEnd,
  }
  return cssIdent(CaptionSideMap, cval)

func cssBorderCollapse(cval: CSSComponentValue): Opt[CSSBorderCollapse] =
  const BorderCollapseMap = {
    "collapse": BorderCollapseCollapse,
    "separate": BorderCollapseSeparate
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
      of cttWhitespace: discard
      of cttIdent:
        if s:
          die
        r.name = tok.value
        s = true
      of cttNumber:
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
    of cttIdent:
      if tok.value.equalsIgnoreCase("none"):
        return ok(CSSLengthAuto)
    of cttNumber, cttDimension, cttPercentage:
      return cssLength(tok, allow_negative = false)
    else: discard
  return err()

#TODO should be URL (parsed with baseurl of document...)
func cssURL(cval: CSSComponentValue): Option[string] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok == cttUrl:
      return some(tok.value)
  elif cval of CSSFunction:
    let fun = CSSFunction(cval)
    if fun.name.equalsIgnoreCase("url") or fun.name.equalsIgnoreCase("src"):
      for x in fun.value:
        if not isToken(x):
          break
        let x = getToken(x)
        if x == cttWhitespace:
          discard
        elif x == cttString:
          return some(x.value)
        else:
          break

#TODO this should be bg-image, add gradient, etc etc
func cssImage(cval: CSSComponentValue): Opt[CSSContent] =
  if isToken(cval):
    #TODO bg-image only
    let tok = getToken(cval)
    if tok.tokenType == cttIdent and tok.value == "none":
      return ok(CSSContent(t: ContentImage, s: ""))
  let url = cssURL(cval)
  if url.isSome:
    return ok(CSSContent(t: ContentImage, s: url.get))
  return err()

func cssInteger(cval: CSSComponentValue; range: Slice[int]): Opt[int] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == cttNumber:
      if tok.nvalue in float64(range.a)..float64(range.b):
        return ok(int(tok.nvalue))
  return err()

func cssFloat(cval: CSSComponentValue): Opt[CSSFloat] =
  const FloatMap = {
    "none": FloatNone,
    "left": FloatLeft,
    "right": FloatRight
  }
  return cssIdent(FloatMap, cval)

func cssVisibility(cval: CSSComponentValue): Opt[CSSVisibility] =
  const VisibilityMap = {
    "visible": VisibilityVisible,
    "hidden": VisibilityHidden,
    "collapse": VisibilityCollapse
  }
  return cssIdent(VisibilityMap, cval)

func cssBoxSizing(cval: CSSComponentValue): Opt[CSSBoxSizing] =
  const BoxSizingMap = {
    "border-box": BoxSizingBorderBox,
    "content-box": BoxSizingContentBox
  }
  return cssIdent(BoxSizingMap, cval)

func cssClear(cval: CSSComponentValue): Opt[CSSClear] =
  const ClearMap = {
    "none": ClearNone,
    "left": ClearLeft,
    "right": ClearRight,
    "both": ClearBoth,
    "inline-start": ClearInlineStart,
    "inline-end": ClearInlineEnd
  }
  return cssIdent(ClearMap, cval)

func cssTextTransform(cval: CSSComponentValue): Opt[CSSTextTransform] =
  const TextTransformMap = {
    "none": TextTransformNone,
    "capitalize": TextTransformCapitalize,
    "uppercase": TextTransformUppercase,
    "lowercase": TextTransformLowercase,
    "full-width": TextTransformFullWidth,
    "full-size-kana": TextTransformFullSizeKana,
    "-cha-half-width": TextTransformChaHalfWidth
  }
  return cssIdent(TextTransformMap, cval)

func cssFlexDirection(cval: CSSComponentValue): Opt[CSSFlexDirection] =
  const FlexDirectionMap = {
    "row": FlexDirectionRow,
    "row-reverse": FlexDirectionRowReverse,
    "column": FlexDirectionColumn,
    "column-reverse": FlexDirectionColumnReverse,
  }
  return cssIdent(FlexDirectionMap, cval)

func cssNumber(cval: CSSComponentValue; positive: bool): Opt[float64] =
  if isToken(cval):
    let tok = getToken(cval)
    if tok.tokenType == cttNumber:
      if not positive or tok.nvalue >= 0:
        return ok(tok.nvalue)
  return err()

func cssFlexWrap(cval: CSSComponentValue): Opt[CSSFlexWrap] =
  const FlexWrapMap = {
    "nowrap": FlexWrapNowrap,
    "wrap": FlexWrapWrap,
    "wrap-reverse": FlexWrapWrapReverse
  }
  return cssIdent(FlexWrapMap, cval)

proc getValueFromDecl(val: CSSComputedValue; d: CSSDeclaration;
    vtype: CSSValueType; ptype: CSSPropertyType): Err[void] =
  var i = 0
  d.value.skipWhitespace(i)
  if i >= d.value.len:
    return err()
  let cval = d.value[i]
  inc i
  case vtype
  of cvtColor:
    val.color = ?cssColor(cval)
  of cvtLength:
    case ptype
    of cptWordSpacing:
      val.length = ?cssWordSpacing(cval)
    of cptLineHeight:
      val.length = ?cssLineHeight(cval)
    of cptMaxWidth, cptMaxHeight, cptMinWidth,
       cptMinHeight:
      val.length = ?cssMaxMinSize(cval)
    of cptPaddingLeft, cptPaddingRight, cptPaddingTop,
       cptPaddingBottom:
      val.length = ?cssLength(cval, has_auto = false)
    #TODO content for flex-basis
    else:
      val.length = ?cssLength(cval)
  of cvtFontStyle:
    val.fontstyle = ?cssFontStyle(cval)
  of cvtDisplay:
    val.display = ?cssDisplay(cval)
  of cvtContent:
    val.content = cssContent(d)
  of cvtWhiteSpace:
    val.whitespace = ?cssWhiteSpace(cval)
  of cvtInteger:
    if ptype == cptFontWeight:
      val.integer = ?cssFontWeight(cval)
    elif ptype == cptChaColspan:
      val.integer = ?cssInteger(cval, 1 .. 1000)
    elif ptype == cptChaRowspan:
      val.integer = ?cssInteger(cval, 0 .. 65534)
  of cvtTextDecoration:
    val.textdecoration = ?cssTextDecoration(d)
  of cvtWordBreak:
    val.wordbreak = ?cssWordBreak(cval)
  of cvtListStyleType:
    val.liststyletype = ?cssListStyleType(cval)
  of cvtVerticalAlign:
    val.verticalalign = ?cssVerticalAlign(cval)
  of cvtTextAlign:
    val.textalign = ?cssTextAlign(cval)
  of cvtListStylePosition:
    val.liststyleposition = ?cssListStylePosition(cval)
  of cvtPosition:
    val.position = ?cssPosition(cval)
  of cvtCaptionSide:
    val.captionside = ?cssCaptionSide(cval)
  of cvtBorderCollapse:
    val.bordercollapse = ?cssBorderCollapse(cval)
  of cvtLength2:
    val.length2.a = ?cssAbsoluteLength(cval)
    d.value.skipWhitespace(i)
    if i >= d.value.len:
      val.length2.b = val.length2.a
    else:
      let cval = d.value[i]
      val.length2.b = ?cssAbsoluteLength(cval)
  of cvtQuotes:
    val.quotes = ?cssQuotes(d)
  of cvtCounterReset:
    val.counterreset = ?cssCounterReset(d)
  of cvtImage:
    val.image = ?cssImage(cval)
  of cvtFloat:
    val.float = ?cssFloat(cval)
  of cvtVisibility:
    val.visibility = ?cssVisibility(cval)
  of cvtBoxSizing:
    val.boxsizing = ?cssBoxSizing(cval)
  of cvtClear:
    val.clear = ?cssClear(cval)
  of cvtTextTransform:
    val.texttransform = ?cssTextTransform(cval)
  of cvtBgcolorIsCanvas:
    return err() # internal value
  of cvtFlexDirection:
    val.flexdirection = ?cssFlexDirection(cval)
  of cvtFlexWrap:
    val.flexwrap = ?cssFlexWrap(cval)
  of cvtNumber:
    const NeedsPositive = {cptFlexGrow}
    val.number = ?cssNumber(cval, ptype in NeedsPositive)
  of cvtNone:
    discard
  return ok()

func getInitialColor(t: CSSPropertyType): CellColor =
  if t == cptBackgroundColor:
    return Colors["transparent"].cellColor()
  return defaultColor

func getInitialLength(t: CSSPropertyType): CSSLength =
  case t
  of cptWidth, cptHeight, cptWordSpacing, cptLineHeight, cptLeft, cptRight,
      cptTop, cptBottom, cptMaxWidth, cptMaxHeight, cptMinWidth, cptMinHeight,
      cptFlexBasis:
    return CSSLengthAuto
  else:
    return CSSLength(auto: false, unit: cuPx, num: 0)

func getInitialInteger(t: CSSPropertyType): int =
  case t
  of cptChaColspan, cptChaRowspan:
    return 1
  of cptFontWeight:
    return 400 # normal
  else:
    return 0

func getInitialNumber(t: CSSPropertyType): float64 =
  if t == cptFlexShrink:
    return 1
  return 0

func calcInitial(t: CSSPropertyType): CSSComputedValue =
  let v = valueType(t)
  var nv: CSSComputedValue
  case v
  of cvtColor:
    nv = CSSComputedValue(v: v, color: getInitialColor(t))
  of cvtDisplay:
    nv = CSSComputedValue(v: v, display: DisplayInline)
  of cvtWordBreak:
    nv = CSSComputedValue(v: v, wordbreak: WordBreakNormal)
  of cvtLength:
    nv = CSSComputedValue(v: v, length: getInitialLength(t))
  of cvtInteger:
    nv = CSSComputedValue(v: v, integer: getInitialInteger(t))
  of cvtQuotes:
    nv = CSSComputedValue(v: v, quotes: CSSQuotes(auto: true))
  of cvtNumber:
    nv = CSSComputedValue(v: v, number: getInitialNumber(t))
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

func getComputedValue(d: CSSDeclaration; ptype: CSSPropertyType;
    vtype: CSSValueType): Opt[CSSComputedEntry] =
  let global = cssGlobal(d)
  let val = CSSComputedValue(v: vtype)
  if global != cvtNoglobal:
    return ok((ptype, val, global))
  ?val.getValueFromDecl(d, vtype, ptype)
  return ok((ptype, val, global))

func lengthShorthand(d: CSSDeclaration; props: array[4, CSSPropertyType]):
    Opt[seq[CSSComputedEntry]] =
  var i = 0
  var cvals: seq[CSSComponentValue]
  while i < d.value.len:
    if d.value[i] != cttWhitespace:
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
  cptMarginTop, cptMarginRight, cptMarginBottom, cptMarginLeft
]

const PropertyPaddingSpec = [
  cptPaddingTop, cptPaddingRight, cptPaddingBottom, cptPaddingLeft
]

proc getComputedValues0(res: var seq[CSSComputedEntry]; d: CSSDeclaration):
    Err[void] =
  case shorthandType(d.name)
  of cstNone:
    let ptype = propertyType(d.name)
    let vtype = valueType(ptype)
    res.add(?getComputedValue(d, ptype, vtype))
  of cstAll:
    let global = cssGlobal(d)
    if global != cvtNoglobal:
      for ptype in CSSPropertyType:
        let vtype = valueType(ptype)
        let val = CSSComputedValue(v: vtype)
        res.add((ptype, val, global))
  of cstMargin:
    res.add(?lengthShorthand(d, PropertyMarginSpec))
  of cstPadding:
    res.add(?lengthShorthand(d, PropertyPaddingSpec))
  of cstBackground:
    let global = cssGlobal(d)
    var bgcolorval = getDefault(cptBackgroundColor)
    var bgimageval = getDefault(cptBackgroundImage)
    var valid = true
    if global == cvtNoglobal:
      for tok in d.value:
        if tok == cttWhitespace:
          continue
        if (let r = cssImage(tok); r.isOk):
          bgimageval = CSSComputedValue(v: cvtImage, image: r.get)
        elif (let r = cssColor(tok); r.isOk):
          bgcolorval = CSSComputedValue(v: cvtColor, color: r.get)
        else:
          #TODO when we implement the other shorthands too
          #valid = false
          discard
    if valid:
      res.add((cptBackgroundColor, bgcolorval, global))
      res.add((cptBackgroundImage, bgimageval, global))
  of cstListStyle:
    let global = cssGlobal(d)
    var positionVal = getDefault(cptListStylePosition)
    var typeVal = getDefault(cptListStyleType)
    var valid = true
    if global == cvtNoglobal:
      for tok in d.value:
        if tok == cttWhitespace:
          continue
        if (let r = cssListStylePosition(tok); r.isOk):
          positionVal = CSSComputedValue(
            v: cvtListStylePosition,
            liststyleposition: r.get
          )
        elif (let r = cssListStyleType(tok); r.isOk):
          typeVal = CSSComputedValue(
            v: cvtListStyleType,
            liststyletype: r.get
          )
        else:
          #TODO list-style-image
          #valid = false
          discard
    if valid:
      res.add((cptListStylePosition, positionVal, global))
      res.add((cptListStyleType, typeVal, global))
  of cstFlex:
    let global = cssGlobal(d)
    if global == cvtNoglobal:
      var i = 0
      d.value.skipWhitespace(i)
      if i >= d.value.len:
        return err()
      if (let r = cssNumber(d.value[i], positive = true); r.isSome):
        # flex-grow
        let val = CSSComputedValue(v: cvtNumber, number: r.get)
        res.add((cptFlexGrow, val, global))
        inc i
        d.value.skipWhitespace(i)
        if i < d.value.len:
          if not d.value[i].isToken:
            return err()
          if (let r = cssNumber(d.value[i], positive = true); r.isSome):
            # flex-shrink
            let val = CSSComputedValue(v: cvtNumber, number: r.get)
            res.add((cptFlexShrink, val, global))
            inc i
            d.value.skipWhitespace(i)
      if res.len < 1: # flex-grow omitted, default to 1
        let val = CSSComputedValue(v: cvtNumber, number: 1)
        res.add((cptFlexGrow, val, global))
      if res.len < 2: # flex-shrink omitted, default to 1
        let val = CSSComputedValue(v: cvtNumber, number: 1)
        res.add((cptFlexShrink, val, global))
      if i < d.value.len:
        # flex-basis
        let val = CSSComputedValue(v: cvtLength, length: ?cssLength(d.value[i]))
        res.add((cptFlexBasis, val, global))
      else: # omitted, default to 0px
        let val = CSSComputedValue(
          v: cvtLength,
          length: CSSLength(unit: cuPx, num: 0)
        )
        res.add((cptFlexBasis, val, global))
    else:
      res.add((cptFlexGrow, getDefault(cptFlexGrow), global))
      res.add((cptFlexShrink, getDefault(cptFlexShrink), global))
      res.add((cptFlexBasis, getDefault(cptFlexBasis), global))
  of cstFlexFlow:
    let global = cssGlobal(d)
    if global == cvtNoglobal:
      var i = 0
      d.value.skipWhitespace(i)
      if i >= d.value.len:
        return err()
      if (let dir = cssFlexDirection(d.value[i]); dir.isSome):
        # flex-direction
        let val = CSSComputedValue(v: cvtFlexDirection, flexdirection: dir.get)
        res.add((cptFlexDirection, val, global))
        inc i
        d.value.skipWhitespace(i)
      if i < d.value.len:
        let wrap = ?cssFlexWrap(d.value[i])
        let val = CSSComputedValue(v: cvtFlexWrap, flexwrap: wrap)
        res.add((cptFlexWrap, val, global))
    else:
      res.add((cptFlexDirection, getDefault(cptFlexDirection), global))
      res.add((cptFlexWrap, getDefault(cptFlexWrap), global))
  return ok()

proc getComputedValues(d: CSSDeclaration): seq[CSSComputedEntry] =
  var res: seq[CSSComputedEntry] = @[]
  if res.getComputedValues0(d).isOk:
    return res
  return @[]

proc addValues*(builder: var CSSComputedValuesBuilder;
    decls: seq[CSSDeclaration]; origin: CSSOrigin) =
  for decl in decls:
    if decl.important:
      builder.importantProperties[origin].add(getComputedValues(decl))
    else:
      builder.normalProperties[origin].add(getComputedValues(decl))

proc applyValue(vals: CSSComputedValues; prop: CSSPropertyType;
    val: CSSComputedValue; global: CSSGlobalValueType;
    parent: CSSComputedValues; previousOrigin: CSSComputedValues) =
  let parentVal = if parent != nil:
    parent[prop]
  else:
    nil
  case global
  of cvtInherit:
    if parentVal != nil:
      vals[prop] = parentVal
    else:
      vals[prop] = getDefault(prop)
  of cvtInitial:
    vals[prop] = getDefault(prop)
  of cvtUnset:
    if inherited(prop):
      # inherit
      if parentVal != nil:
        vals[prop] = parentVal
      else:
        vals[prop] = getDefault(prop)
    else:
      # initial
      vals[prop] = getDefault(prop)
  of cvtRevert:
    if previousOrigin != nil:
      vals[prop] = previousOrigin[prop]
    else:
      vals[prop] = getDefault(prop)
  of cvtNoglobal:
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
    for build in builder.normalProperties[coUserAgent]:
      result.applyValue(build.t, build.val, build.global, builder.parent, nil)
    previousOrigins[coUserAgent] = result.copyProperties()
  # Presentational hints override user agent style, but respect user/author
  # style.
  if builder.preshints != nil:
    for prop in CSSPropertyType:
      if builder.preshints[prop] != nil:
        result[prop] = builder.preshints[prop]
  block:
    for build in builder.normalProperties[coUser]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[coUserAgent])
    # save user origins so author can use them
    previousOrigins[coUser] = result.copyProperties()
  block:
    for build in builder.normalProperties[coAuthor]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[coUser])
    # no need to save user origins
  block:
    for build in builder.importantProperties[coAuthor]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[coUser])
    # important, so no need to save origins
  block:
    for build in builder.importantProperties[coUser]:
      result.applyValue(build.t, build.val, build.global, builder.parent,
        previousOrigins[coUserAgent])
    # important, so no need to save origins
  block:
    for build in builder.importantProperties[coUserAgent]:
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
  if result{"float"} != FloatNone:
    #TODO it may be better to handle this in layout
    let display = result{"display"}.blockify()
    if display != result{"display"}:
      result{"display"} = display
