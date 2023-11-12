import css/stylednode
import css/values
import layout/layoutunit
import types/color

type
  Offset* = object
    x*: LayoutUnit
    y*: LayoutUnit

  Size* = object
    w*: LayoutUnit
    h*: LayoutUnit

  InlineAtomType* = enum
    INLINE_SPACING, INLINE_PADDING, INLINE_WORD, INLINE_BLOCK

  InlineAtom* = ref object
    offset*: Offset
    size*: Size
    case t*: InlineAtomType
    of INLINE_SPACING, INLINE_PADDING:
      sformat*: ComputedFormat
    of INLINE_WORD:
      wformat*: ComputedFormat
      str*: string
    of INLINE_BLOCK:
      innerbox*: BlockBox

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

  LineBox* = ref object
    atoms*: seq[InlineAtom]
    offsety*: LayoutUnit
    size*: Size

  InlineContext* = ref object
    offset*: Offset
    size*: Size
    lines*: seq[LineBox]

    # baseline of the first line box
    firstBaseline*: LayoutUnit
    # baseline of the last line box
    baseline*: LayoutUnit

    # this is actually xminwidth.
    minwidth*: LayoutUnit

  RelativeRect* = object
    top*: LayoutUnit
    bottom*: LayoutUnit
    left*: LayoutUnit
    right*: LayoutUnit

  BlockBox* = ref object of RootObj
    inline*: InlineContext
    node*: StyledNode
    nested*: seq[BlockBox]
    computed*: CSSComputedValues
    offset*: Offset
    size*: Size # padding size
    margin*: RelativeRect #TODO get rid of this?
    positioned*: bool
    x_positioned*: bool
    y_positioned*: bool
    # very bad name. basically the minimum content width after the contents
    # have been positioned (usually the width of the shortest word.) used
    # in table cells.
    xminwidth*: LayoutUnit
    # baseline of the first line box of all descendants
    firstBaseline*: LayoutUnit
    # baseline of the last line box of all descendants
    baseline*: LayoutUnit

  ListItemBox* = ref object of BlockBox
    marker*: InlineContext
