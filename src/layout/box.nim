import options

import css/values
import html/dom
import io/term

type
  Viewport* = ref object
    term*: TermAttributes
    root*: BlockBox
    map*: seq[CSSBox]

  CSSBox* = ref object of RootObj
    t*: CSSDisplay
    children*: seq[CSSBox]
    inlinelayout*: bool
    specified*: CSSSpecifiedValues
    node*: Node
    element*: Element

  InlineAtom* = ref object of RootObj
    relx*: int
    width*: int
    height*: int

  ComputedFormat* = ref object
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    color*: CSSColor
    node*: Node

  InlineSpacing* = ref object of InlineAtom
    format*: ComputedFormat

  InlineWord* = ref object of InlineAtom
    str*: string
    format*: ComputedFormat

  InlineRow* = ref object
    atoms*: seq[InlineAtom]
    relx*: int
    rely*: int
    width*: int
    height*: int

  InlineContext* = ref object
    relx*: int
    rely*: int
    width*: int
    height*: int
    rows*: seq[InlineRow]
    thisrow*: InlineRow

    whitespace*: bool
    maxwidth*: int
    viewport*: Viewport
    node*: Node

  BlockContext* = ref object of InlineAtom
    inline*: InlineContext
    nested*: seq[BlockContext]
    specified*: CSSSpecifiedValues
    viewport*: Viewport
    rely*: int
    margin_top*: int
    margin_bottom*: int
    margin_left*: int
    margin_right*: int
    padding_top*: int
    padding_bottom*: int
    padding_left*: int
    padding_right*: int

    compwidth*: int
    compheight*: Option[int]
    done*: bool

  InlineBox* = ref object of CSSBox
    text*: seq[string]
    ictx*: InlineContext
    newline*: bool

  BlockBox* = ref object of CSSBox
    bctx*: BlockContext

  InlineBlockBox* = ref object of BlockBox
    ictx*: InlineContext

  ListItemBox* = ref object of BlockBox
