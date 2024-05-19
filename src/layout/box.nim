import css/cssvalues
import css/stylednode
import img/bitmap
import layout/layoutunit

type
  DimensionType* = enum
    dtHorizontal, dtVertical

  Offset* = array[DimensionType, LayoutUnit]

  Size* = array[DimensionType, LayoutUnit]

  InlineAtomType* = enum
    iatSpacing, iatWord, iatInlineBlock, iatImage

  InlineAtom* = ref object
    offset*: Offset
    size*: Size
    case t*: InlineAtomType
    of iatSpacing:
      discard
    of iatWord:
      str*: string
    of iatInlineBlock:
      innerbox*: BlockBox
    of iatImage:
      bmp*: Bitmap

  RootInlineFragment* = ref object
    # offset relative to parent
    offset*: Offset
    # root fragment
    fragment*: InlineFragment
    # baseline of the first line box
    firstBaseline*: LayoutUnit
    # baseline of the last line box
    baseline*: LayoutUnit
    # minimum content width
    xminwidth*: LayoutUnit
    size*: Size

  SplitType* = enum
    stSplitStart, stSplitEnd

  Area* = object
    offset*: Offset
    size*: Size

  InlineFragment* = ref object
    startOffset*: Offset # offset of the first word, for position: absolute
    areas*: seq[Area] # background that should be painted by fragment
    children*: seq[InlineFragment]
    atoms*: seq[InlineAtom]
    computed*: CSSComputedValues
    node*: StyledNode
    splitType*: set[SplitType]

  RelativeRect* = object
    top*: LayoutUnit
    bottom*: LayoutUnit
    left*: LayoutUnit
    right*: LayoutUnit

  BlockBox* = ref object of RootObj
    inline*: RootInlineFragment
    node*: StyledNode
    nested*: seq[BlockBox]
    computed*: CSSComputedValues
    offset*: Offset
    size*: Size # padding size
    margin*: RelativeRect #TODO get rid of this?
    positioned*: RelativeRect #TODO ditto
    # very bad name. basically the minimum content width after the contents
    # have been positioned (usually the width of the shortest word.) used
    # in table cells.
    xminwidth*: LayoutUnit
    # baseline of the first line box of all descendants
    firstBaseline*: LayoutUnit
    # baseline of the last line box of all descendants
    baseline*: LayoutUnit

func offset*(x, y: LayoutUnit): Offset =
  return [dtHorizontal: x, dtVertical: y]

func x*(offset: Offset): LayoutUnit {.inline.} =
  return offset[dtHorizontal]

func x*(offset: var Offset): var LayoutUnit {.inline.} =
  return offset[dtHorizontal]

func `x=`*(offset: var Offset; x: LayoutUnit) {.inline.} =
  offset[dtHorizontal] = x

func y*(offset: Offset): LayoutUnit {.inline.} =
  return offset[dtVertical]

func y*(offset: var Offset): var LayoutUnit {.inline.} =
  return offset[dtVertical]

func `y=`*(offset: var Offset; y: LayoutUnit) {.inline.} =
  offset[dtVertical] = y

func size*(w, h: LayoutUnit): Offset =
  return [dtHorizontal: w, dtVertical: h]

func w*(size: Size): LayoutUnit {.inline.} =
  return size[dtHorizontal]

func w*(size: var Size): var LayoutUnit {.inline.} =
  return size[dtHorizontal]

func `w=`*(size: var Size; w: LayoutUnit) {.inline.} =
  size[dtHorizontal] = w

func h*(size: Size): LayoutUnit {.inline.} =
  return size[dtVertical]

func h*(size: var Size): var LayoutUnit {.inline.} =
  return size[dtVertical]

func `h=`*(size: var Size; h: LayoutUnit) {.inline.} =
  size[dtVertical] = h

func `+`*(a, b: Offset): Offset =
  return offset(x = a.x + b.x, y = a.y + b.y)

func `-`*(a, b: Offset): Offset =
  return offset(x = a.x - b.x, y = a.y - b.y)

proc `+=`*(a: var Offset; b: Offset) =
  a.x += b.x
  a.y += b.y
