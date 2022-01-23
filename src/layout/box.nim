import options

import css/values
import html/dom
import io/term

type
  Viewport* = ref object
    term*: TermAttributes
    nodes*: seq[Node]
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
    viewport*: Viewport

  BlockContext* = ref object of InlineAtom
    inline*: InlineContext
    nested*: seq[BlockContext]
    specified*: CSSSpecifiedValues
    viewport*: Viewport
    rely*: int
    margin_top*: int
    margin_bottom*: int

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
