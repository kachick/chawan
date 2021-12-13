import types/enums
import css/values
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
    icontext*: InlineContext
    bcontext*: BlockContext
    cssvalues*: CSSComputedValues
    node*: Node

  #TODO move fromy
  InlineContext* = ref object
    fromx*: int
    fromy*: int
    conty*: bool
    whitespace*: bool
    ws_initial*: bool

  BlockContext* = ref object
    fromy*: int
    margin_done*: int
    margin_todo*: int
    has_blocks*: bool
    anon_block*: CSSBlockBox

  LayoutState* = object
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
    str*: string
    nodes*: seq[Node]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
    content*: seq[CSSRowBox]

  CSSBlockBox* = ref CSSBlockBoxObj
  CSSBlockBoxObj = object of CSSBox
