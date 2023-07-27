import options

import css/stylednode
import css/values
import io/window
import layout/layoutunit
import types/color

type
  Offset* = object
    x*: LayoutUnit
    y*: LayoutUnit

  Size* = object
    width*: LayoutUnit
    height*: LayoutUnit

  # min-content: box width is longest word's width
  # max-content: box width is content width without wrapping
  # stretch: box width is n px wide
  # fit-content: also known as shrink-to-fit, box width is
  #   min(max-content, max(stretch)
  #   in other words, as wide as needed, but wrap if wider than allowed
  # (note: I write width here, but it can apply for any constraint)
  SizeConstraintType* = enum
    STRETCH, FIT_CONTENT, MIN_CONTENT, MAX_CONTENT

  SizeConstraint* = object
    t*: SizeConstraintType
    u*: LayoutUnit

  Strut* = object
    pos*: LayoutUnit
    neg*: LayoutUnit

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
    width*: LayoutUnit
    height*: LayoutUnit
    vertalign*: CSSVerticalAlign
    baseline*: LayoutUnit
    top*: LayoutUnit
    bottom*: LayoutUnit

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

  # Treated exactly the same as InlineSpacing, except it signifies padding.
  InlinePadding* = ref object of InlineSpacing

  InlineWord* = ref object of InlineAtom
    str*: string
    format*: ComputedFormat

  LineBox* = ref object
    atoms*: seq[InlineAtom]
    offset*: Offset
    width*: LayoutUnit
    height*: LayoutUnit
    baseline*: LayoutUnit
    lineheight*: LayoutUnit #line-height property

  InlineContext* = ref object
    offset*: Offset
    height*: LayoutUnit
    lines*: seq[LineBox]
    currentLine*: LineBox
    width*: LayoutUnit
    availableWidth*: SizeConstraint
    availableHeight*: SizeConstraint

    charwidth*: int
    whitespacenum*: int
    # this is actually xminwidth.
    minwidth*: LayoutUnit
    viewport*: Viewport
    format*: ComputedFormat

  BlockBox* = ref object of RootObj
    inline*: InlineContext
    node*: StyledNode
    nested*: seq[BlockBox]
    computed*: CSSComputedValues
    viewport*: Viewport
    offset*: Offset

    # This is the padding width/height.
    width*: LayoutUnit
    height*: LayoutUnit
    margin_top*: LayoutUnit
    margin_bottom*: LayoutUnit
    margin_left*: LayoutUnit
    margin_right*: LayoutUnit
    padding_top*: LayoutUnit
    padding_bottom*: LayoutUnit
    padding_left*: LayoutUnit
    padding_right*: LayoutUnit
    min_width*: Option[LayoutUnit]
    max_width*: Option[LayoutUnit]
    min_height*: Option[LayoutUnit]
    max_height*: Option[LayoutUnit]

    # width and height constraints
    availableWidth*: SizeConstraint
    availableHeight*: SizeConstraint

    positioned*: bool
    x_positioned*: bool
    y_positioned*: bool

    # very bad name. basically the minimum content width after the contents
    # have been positioned (usually the width of the shortest word.) used
    # in table cells.
    xminwidth*: LayoutUnit

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
    width*: LayoutUnit
    builder*: TableRowBoxBuilder
    ncols*: int

  ColumnContext* = object
    minwidth*: LayoutUnit
    maxwidth*: LayoutUnit
    width*: LayoutUnit
    wspecified*: bool
    weight*: float64

  TableContext* = object
    caption*: TableCaptionBoxBuilder
    rows*: seq[RowContext]
    cols*: seq[ColumnContext]
    growing*: seq[CellWrapper]
    maxwidth*: LayoutUnit
    blockspacing*: LayoutUnit
    inlinespacing*: LayoutUnit
    collapse*: bool
    reflow*: seq[bool]

  InlineBlockBox* = ref object of InlineAtom
    innerbox*: BlockBox
    margin_top*: LayoutUnit
    margin_bottom*: LayoutUnit

proc append*(a: var Strut, b: LayoutUnit) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum*(a: Strut): LayoutUnit =
  return a.pos + a.neg

func minContent*(): SizeConstraint =
  return SizeConstraint(t: MIN_CONTENT)

func maxContent*(): SizeConstraint =
  return SizeConstraint(t: MAX_CONTENT)

func stretch*(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: STRETCH, u: u)

func fitContent*(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: FIT_CONTENT, u: u)

#TODO ?
func stretch*(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of MIN_CONTENT, MAX_CONTENT:
    return SizeConstraint(t: sc.t, u: sc.u)
  of STRETCH, FIT_CONTENT:
    return SizeConstraint(t: STRETCH, u: sc.u)

func fitContent*(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of MIN_CONTENT, MAX_CONTENT:
    return SizeConstraint(t: sc.t)
  of STRETCH, FIT_CONTENT:
    return SizeConstraint(t: FIT_CONTENT, u: sc.u)

func isDefinite*(sc: SizeConstraint): bool =
  return sc.t in {STRETCH, FIT_CONTENT}
