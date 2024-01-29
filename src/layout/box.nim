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
    INLINE_SPACING, INLINE_WORD, INLINE_BLOCK

  InlineAtom* = ref object
    offset*: Offset
    size*: Size
    case t*: InlineAtomType
    of INLINE_SPACING:
      discard
    of INLINE_WORD:
      str*: string
    of INLINE_BLOCK:
      innerbox*: BlockBox

  LineBox* = ref object
    atoms*: seq[InlineAtom]
    offsety*: LayoutUnit
    size*: Size

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

  InlineFragment* = ref object
    # Say we have the following inline box:
    #   abcd
    # efghij
    # klm
    # Then startOffset is x: 2ch, y: 1em, endOffset is x: 3ch, y: 2em,
    # and size is w: 6ch, h: 3em.
    # So the algorithm for painting a fragment is:
    # if startOffset.y == endOffset.y:
    #   paint(startOffset, endOffset)
    # else:
    #   paint(startOffset.x, 0, size.w, startOffset.y)
    #   paint(0, startOffset.y, size.w, endOffset.y)
    #   paint(0, endOffset.y, endOffset.x, size.h)
    startOffset*: Offset
    endOffset*: Offset
    size*: Size
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

  ListItemBox* = ref object of BlockBox
    marker*: RootInlineFragment
