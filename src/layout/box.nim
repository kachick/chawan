import unicode

import types/enums
import css/style

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
    context*: InlineContext
    bcontext*: BlockContext
    cssvalues*: CSSComputedValues

  InlineContext* = ref object
    context*: FormatContextType
    fromx*: int
    fromy*: int
    marginx*: int
    marginy*: int
    conty*: bool
    whitespace*: bool

  BlockContext* = ref object
    context*: FormatContextType
    marginx*: int
    marginy*: int

  CSSRowBox* = object
    x*: int
    y*: int
    width*: int
    height*: int
    color*: CSSColor
    fontstyle*: CSSFontStyle
    fontweight*: int
    runes*: seq[Rune]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
    content*: seq[CSSRowBox]

  CSSBlockBox* = ref CSSBlockBoxObj
  CSSBlockBoxObj = object of CSSBox
    tag*: string
