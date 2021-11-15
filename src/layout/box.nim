import unicode

import types/enums
import css/style
import html/dom

type
  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref CSSBoxObj
  CSSBoxObj = object of RootObj
    x*: int
    y*: int
    width*: int
    height*: int
    children*: seq[CSSBox]
    context*: Context
    bcontext*: BlockContext
    cssvalues*: CSSComputedValues

  Context* = ref object
    context*: FormatContextType
    fromx*: int
    fromy*: int
    marginx*: int
    marginy*: int
    conty*: bool
    whitespace*: bool
    ws_initial*: bool

  InlineContext* = object
    cssvalues*: CSSComputedValues

  BlockContext* = ref object
    context*: FormatContextType
    marginx*: int
    marginy*: int
    nodes*: seq[Node]

  CSSRowBox* = object
    x*: int
    y*: int
    width*: int
    height*: int
    color*: CSSColor
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    runes*: seq[Rune]
    nodes*: seq[Node]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
    content*: seq[CSSRowBox]

  CSSBlockBox* = ref CSSBlockBoxObj
  CSSBlockBoxObj = object of CSSBox
    tag*: string
