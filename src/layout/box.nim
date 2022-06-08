import options

import css/values
import html/dom
import io/term

type
  Offset* = object
    x*: int
    y*: int

  Viewport* = ref object
    term*: TermAttributes
    root*: BlockBoxBuilder

  BoxBuilder* = ref object of RootObj
    children*: seq[BoxBuilder]
    inlinelayout*: bool
    specified*: CSSComputedValues
    node*: Node
    element*: Element

  InlineBoxBuilder* = ref object of BoxBuilder
    text*: seq[string]
    ictx*: InlineContext
    newline*: bool

  BlockBoxBuilder* = ref object of BoxBuilder
    bctx*: BlockContext

  InlineBlockBoxBuilder* = ref object of BlockBoxBuilder
    iblock*: InlineBlock # iblock.bctx is equivalent to box.bctx
    ictx*: InlineContext

  InlineAtom* = ref object of RootObj
    relx*: int
    rely*: int
    width*: int
    height*: int
    vertalign*: CSSVerticalAlign

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

  InlineBlock* = ref object of InlineAtom
    bctx*: BlockContext

  InlineRow* = ref object
    atoms*: seq[InlineAtom]
    relx*: int
    rely*: int
    width*: int
    height*: int
    lineheight*: int #line-height property

  InlineContext* = ref object
    offset*: Offset
    height*: int
    rows*: seq[InlineRow]
    thisrow*: InlineRow

    whitespacenum*: int
    maxwidth*: int
    viewport*: Viewport
    node*: Node
    shrink*: bool
    format*: ComputedFormat

  BlockContext* = ref object
    inline*: InlineContext
    nested*: seq[BlockContext]
    specified*: CSSComputedValues
    viewport*: Viewport
    offset*: Offset
    width*: int
    height*: int
    margin_top*: int
    margin_bottom*: int
    margin_left*: int
    margin_right*: int
    padding_top*: int
    padding_bottom*: int
    padding_left*: int
    padding_right*: int

    compwidth*: int
    maxwidth*: int
    nocenter*: bool
    compheight*: Option[int]
    shrink*: bool

  #MarkerBox* = ref object of InlineBoxBuilder
  #  outside*: bool

  #ListItemBox* = ref object of BlockBox
