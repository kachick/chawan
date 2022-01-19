import options

import css/values
import html/dom
import io/term

type
  CSSBox* = ref object of RootObj
    t*: CSSDisplay
    x*: int
    y*: int
    width*: int
    children*: seq[CSSBox]
    inlinelayout*: bool
    specified*: CSSSpecifiedValues
    node*: Node

  Viewport* = ref object of CSSBox
    term*: TermAttributes
    nodes*: seq[Node]

  InlineAtom* = ref object of RootObj
    relx*: int
    width*: int
    height*: int

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

    whitespace*: bool
    maxwidth*: int

  BlockContext* = ref object of InlineAtom
    margin_done*: int
    margin_todo*: int
    inline*: InlineContext
    nested*: seq[BlockContext]
    specified*: CSSSpecifiedValues
    viewport*: Viewport
    rely*: int

    compwidth*: int
    compheight*: Option[int]

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
    text*: seq[string]
    ictx*: InlineContext
    newline*: bool
  BlockBox* = ref object of CSSBox
    bctx*: BlockContext
  InlineBlockBox* = ref object of BlockBox
    ictx*: InlineContext
  ListItemBox* = ref object of CSSBox
