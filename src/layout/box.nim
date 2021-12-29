import options

import css/values
import html/dom
import io/term

type
  BoxType* = enum
    BOX_INLINE, BOX_BLOCK, BOX_INLINE_BLOCK

  CSSBox* = ref object of RootObj
    t*: BoxType
    x*: int
    y*: int
    width*: int
    children*: seq[CSSBox]
    ictx*: InlineContext
    bctx*: BlockContext
    cssvalues*: CSSSpecifiedValues
    node*: Node
    viewport*: Viewport

  InlineAtom* = ref object of RootObj
    relx*: int
    width*: int

  InlineWord* = ref object of InlineAtom
    str*: string
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    color*: CSSColor
    nodes*: seq[Node]

  InlineRow* = ref object
    atoms*: seq[InlineAtom]
    relx*: int
    rely*: int
    width*: int
    height*: int

  InlineContext* = ref object
    relx*: int
    width*: int
    height*: int
    rows*: seq[InlineRow]
    thisrow*: InlineRow
    specified*: CSSSpecifiedValues

    whitespace*: bool
    ws_initial*: bool
    maxwidth*: int

  BlockContext* = ref object of InlineAtom
    height*: int
    margin_done*: int
    margin_todo*: int
    inlines*: seq[InlineContext]
    nested*: seq[BlockContext]
    specified*: CSSSpecifiedValues

    compwidth*: int
    compheight*: Option[int]

  Viewport* = ref object
    term*: TermAttributes
    nodes*: seq[Node]

  RowBox* = object
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
    bottom*: int

  InlineBox* = ref object of CSSBox
  BlockBox* = ref object of CSSBox
  InlineBlockBox* = ref object of CSSBox
