import css/stylednode
import css/values
import layout/layoutunit

type
  Offset* = object
    x*: LayoutUnit
    y*: LayoutUnit

  Size* = object
    w*: LayoutUnit
    h*: LayoutUnit

  InlineAtomType* = enum
    iatSpacing, iatWord, iatInlineBlock

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
    # very bad name. basically the minimum content width after the contents
    # have been positioned (usually the width of the shortest word.) used
    # in table cells.
    xminwidth*: LayoutUnit
    # baseline of the first line box of all descendants
    firstBaseline*: LayoutUnit
    # baseline of the last line box of all descendants
    baseline*: LayoutUnit

func `+`*(a, b: Offset): Offset =
  return Offset(x: a.x + b.x, y: a.y + b.y)

proc `+=`*(a: var Offset; b: Offset) =
  a.x += b.x
  a.y += b.y
