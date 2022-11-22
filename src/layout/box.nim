import options

import css/stylednode
import css/values
import html/dom
import io/window

type
  #LayoutUnit* = distinct int32
  LayoutUnit* = int

  Offset* = object
    x*: LayoutUnit
    y*: LayoutUnit

  Size* = object
    width*: LayoutUnit
    height*: LayoutUnit

  Strut* = object
    pos*: int
    neg*: int

  Viewport* = ref object
    window*: WindowAttributes
    root*: BlockBox

  BoxBuilder* = ref object of RootObj
    children*: seq[BoxBuilder]
    inlinelayout*: bool
    computed*: CSSComputedValues
    node*: StyledNode

  InlineBoxBuilder* = ref object of BoxBuilder
    text*: seq[string]
    ictx*: InlineContext
    newline*: bool

  BlockBoxBuilder* = ref object of BoxBuilder
    listItemCounter: int # ordinal value of current list

  InlineBlockBoxBuilder* = ref object of BoxBuilder
    content*: BlockBoxBuilder # iblock.bctx is equivalent to box.bctx

  MarkerBoxBuilder* = ref object of InlineBoxBuilder

  ListItemBoxBuilder* = ref object of BoxBuilder
    marker*: MarkerBoxBuilder
    content*: BlockBoxBuilder

  TableRowGroupBoxBuilder* = ref object of BoxBuilder

  TableRowBoxBuilder* = ref object of BoxBuilder

  TableCellBoxBuilder* = ref object of BoxBuilder
    colspan*: int

  TableBoxBuilder* = ref object of BlockBoxBuilder
    rowgroups*: seq[TableRowGroupBoxBuilder]

  InlineAtom* = ref object of RootObj
    offset*: Offset
    width*: int
    height*: int
    vertalign*: CSSVerticalAlign
    baseline*: int
    top*: int
    bottom*: int

  ComputedFormat* = ref object
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    color*: CSSColor
    node*: StyledNode

  InlineSpacing* = ref object of InlineAtom
    format*: ComputedFormat

  InlineWord* = ref object of InlineAtom
    str*: string
    format*: ComputedFormat

  LineBox* = ref object
    atoms*: seq[InlineAtom]
    offset*: Offset
    width*: int
    height*: int
    baseline*: int
    lineheight*: int #line-height property

  InlineContext* = ref object
    offset*: Offset
    height*: int
    lines*: seq[LineBox]
    currentLine*: LineBox

    whitespacenum*: int
    maxwidth*: int
    viewport*: Viewport
    node*: Node
    shrink*: bool
    format*: ComputedFormat

  BlockBox* = ref object of RootObj
    inline*: InlineContext
    nested*: seq[BlockBox]
    computed*: CSSComputedValues
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

  ListItemBox* = ref object of BlockBox
    marker*: InlineContext

  TableCellBox* = ref object of BlockBox
    colspan*: int

  CellWrapper* = object
    box*: BlockBox
    colspan*: int

  RowContext* = object
    cells*: seq[CellWrapper]
    width*: int
    builder*: TableRowBoxBuilder

  TableContext* = object
    colwidths*: seq[int]
    rows*: seq[RowContext]

  InlineBlockBox* = ref object of InlineAtom
    bctx*: BlockBox
    margin_top*: int
    margin_bottom*: int

proc append*(a: var Strut, b: int) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum*(a: Strut): int =
  return a.pos + a.neg

#proc `div`(a, b: LayoutUnit): LayoutUnit {.borrow.}
#
#func `+`*(a, b: LayoutUnit): LayoutUnit {.borrow.}
#func `-`*(a, b: LayoutUnit): LayoutUnit {.borrow.}
#func `*`*(a, b: LayoutUnit): LayoutUnit {.borrow.}
#func `/`*(a, b: LayoutUnit): LayoutUnit = a div b
#
#proc `+=`*(a: var LayoutUnit, b: LayoutUnit) {.borrow.}
#proc `-=`*(a: var LayoutUnit, b: LayoutUnit) {.borrow.}
#proc `*=`*(a: var LayoutUnit, b: LayoutUnit) {.borrow.}
#proc `/=`*(a: var LayoutUnit, b: LayoutUnit) = a = a div b
