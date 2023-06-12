import options

import css/stylednode
import css/values
import io/window
import types/color

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
    positioned*: seq[BlockBox]

  BoxBuilder* = ref object of RootObj
    children*: seq[BoxBuilder]
    inlinelayout*: bool
    computed*: CSSComputedValues
    node*: StyledNode

  InlineBoxBuilder* = ref object of BoxBuilder
    text*: seq[string]
    newline*: bool
    splitstart*: bool
    splitend*: bool

  BlockBoxBuilder* = ref object of BoxBuilder

  MarkerBoxBuilder* = ref object of InlineBoxBuilder

  ListItemBoxBuilder* = ref object of BoxBuilder
    marker*: MarkerBoxBuilder
    content*: BlockBoxBuilder

  TableRowGroupBoxBuilder* = ref object of BlockBoxBuilder

  TableRowBoxBuilder* = ref object of BlockBoxBuilder

  TableCellBoxBuilder* = ref object of BlockBoxBuilder

  TableBoxBuilder* = ref object of BlockBoxBuilder
    rowgroups*: seq[TableRowGroupBoxBuilder]

  TableCaptionBoxBuilder* = ref object of BlockBoxBuilder

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
    textdecoration*: set[CSSTextDecoration]
    color*: RGBAColor
    node*: StyledNode
    #TODO: background color should not be stored in inline words. Instead,
    # inline box fragments should be passed on to the renderer, which could
    # then properly blend them.
    bgcolor*: RGBAColor

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
    width*: int
    contentWidth*: int
    contentHeight*: Option[int]
    contentWidthInfinite*: bool

    charwidth*: int
    whitespacenum*: int
    # this is actually xminwidth.
    minwidth*: int
    viewport*: Viewport
    shrink*: bool
    format*: ComputedFormat

  BlockBox* = ref object of RootObj
    inline*: InlineContext
    node*: StyledNode
    nested*: seq[BlockBox]
    computed*: CSSComputedValues
    viewport*: Viewport
    offset*: Offset

    # This is the padding width/height.
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
    min_width*: Option[int]
    max_width*: Option[int]
    min_height*: Option[int]
    max_height*: Option[int]

    # This is the (specified) content width/height. Actual dimensions may
    # differ (i.e. overflow)
    contentWidth*: int
    contentHeight*: Option[int]
    shrink*: bool
    # Whether to stretch content to infinity.
    contentWidthInfinite*: bool

    positioned*: bool
    x_positioned*: bool
    y_positioned*: bool

    # very bad name. basically the minimum content width after the contents
    # have been positioned (usually the width of the shortest word.) used
    # in table cells.
    xminwidth*: int

  ListItemBox* = ref object of BlockBox
    marker*: InlineContext

  CellWrapper* = ref object
    builder*: TableCellBoxBuilder
    box*: BlockBox
    rowi*: int
    coli*: int
    colspan*: int
    rowspan*: int
    reflow*: bool
    grown*: int # number of remaining rows

  RowContext* = object
    cells*: seq[CellWrapper]
    reflow*: seq[bool]
    width*: int
    builder*: TableRowBoxBuilder
    ncols*: int

  ColumnContext* = object
    minwidth*: int
    maxwidth*: int
    width*: int
    wspecified*: bool
    weight*: float64

  TableContext* = object
    caption*: TableCaptionBoxBuilder
    rows*: seq[RowContext]
    cols*: seq[ColumnContext]
    growing*: seq[CellWrapper]
    maxwidth*: int
    blockspacing*: int
    inlinespacing*: int
    collapse*: bool

  InlineBlockBox* = ref object of InlineAtom
    innerbox*: BlockBox
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
