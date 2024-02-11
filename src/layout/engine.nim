import std/algorithm
import std/math
import std/options
import std/unicode

import css/stylednode
import css/values
import display/winattrs
import layout/box
import layout/layoutunit
import utils/luwrap
import utils/strwidth
import utils/twtstr
import utils/widthconv

type
  LayoutState = ref object
    attrs: WindowAttributes
    positioned: seq[AvailableSpace]

  # min-content: box width is longest word's width
  # max-content: box width is content width without wrapping
  # stretch: box width is n px wide
  # fit-content: also known as shrink-to-fit, box width is
  #   min(max-content, stretch(availableWidth))
  #   in other words, as wide as needed, but wrap if wider than allowed
  # (note: I write width here, but it can apply for any constraint)
  SizeConstraintType = enum
    STRETCH, FIT_CONTENT, MIN_CONTENT, MAX_CONTENT

  SizeConstraint = object
    t: SizeConstraintType
    u: LayoutUnit

  AvailableSpace = object
    w: SizeConstraint
    h: SizeConstraint

  ResolvedSizes = object
    margin: RelativeRect
    padding: RelativeRect
    space: AvailableSpace
    minWidth: LayoutUnit
    maxWidth: LayoutUnit
    minHeight: LayoutUnit
    maxHeight: LayoutUnit

func maxContent(): SizeConstraint =
  return SizeConstraint(t: MAX_CONTENT)

func stretch(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: STRETCH, u: u)

func fitContent(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: FIT_CONTENT, u: u)

type
  BoxBuilder = ref object of RootObj
    children: seq[BoxBuilder]
    computed: CSSComputedValues
    node: StyledNode

  InlineBoxBuilder = ref object of BoxBuilder
    text: seq[string]
    newline: bool
    splitType: set[SplitType]

  BlockBoxBuilder = ref object of BoxBuilder
    inlinelayout: bool

  MarkerBoxBuilder = ref object of InlineBoxBuilder

  ListItemBoxBuilder = ref object of BoxBuilder
    marker: MarkerBoxBuilder
    content: BlockBoxBuilder

  TableRowGroupBoxBuilder = ref object of BlockBoxBuilder

  TableRowBoxBuilder = ref object of BlockBoxBuilder

  TableCellBoxBuilder = ref object of BlockBoxBuilder

  TableBoxBuilder = ref object of BlockBoxBuilder
    rowgroups: seq[TableRowGroupBoxBuilder]

  TableCaptionBoxBuilder = ref object of BlockBoxBuilder

#TODO ?
func stretch(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of MIN_CONTENT, MAX_CONTENT:
    return sc
  of STRETCH, FIT_CONTENT:
    return SizeConstraint(t: STRETCH, u: sc.u)

func fitContent(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of MIN_CONTENT, MAX_CONTENT:
    return SizeConstraint(t: sc.t)
  of STRETCH, FIT_CONTENT:
    return SizeConstraint(t: FIT_CONTENT, u: sc.u)

func isDefinite(sc: SizeConstraint): bool =
  return sc.t in {STRETCH, FIT_CONTENT}

# Layout (2nd pass)
func px(l: CSSLength, lctx: LayoutState, p: LayoutUnit = 0):
    LayoutUnit {.inline.} =
  return px(l, lctx.attrs, p)

func px(l: CSSLength, lctx: LayoutState, p: Option[LayoutUnit]):
    Option[LayoutUnit] {.inline.} =
  if l.unit == UNIT_PERC and p.isNone:
    return none(LayoutUnit)
  return some(px(l, lctx.attrs, p.get(0)))

func canpx(l: CSSLength, sc: SizeConstraint): bool =
  return l.unit != UNIT_PERC or sc.isDefinite()

func canpx(l: CSSLength, p: Option[LayoutUnit]): bool =
  return l.unit != UNIT_PERC or p.isSome

# Note: for margins only
# For percentages, use 0 for indefinite, and containing box's size for
# definite.
func px(l: CSSLength, lctx: LayoutState, p: SizeConstraint): LayoutUnit =
  if l.unit == UNIT_PERC:
    case p.t
    of MIN_CONTENT, MAX_CONTENT:
      return 0
    of STRETCH, FIT_CONTENT:
      return l.px(lctx, p.u)
  return px(l, lctx.attrs, 0)

func applySizeConstraint(u: LayoutUnit, availableSize: SizeConstraint):
    LayoutUnit =
  case availableSize.t
  of STRETCH:
    return availableSize.u
  of MIN_CONTENT, MAX_CONTENT:
    # must be calculated elsewhere...
    return u
  of FIT_CONTENT:
    return min(u, availableSize.u)

type
  BlockContext = object
    lctx: LayoutState
    marginTodo: Strut
    # We use a linked list to set the correct BFC offset and relative offset
    # for every block with an unresolved y offset on margin resolution.
    # marginTarget is a pointer to the last un-resolved ancestor.
    # ancestorsHead is a pointer to the last element of the ancestor list
    # (which may in fact be a pointer to the BPS of a previous sibling's
    # child).
    # parentBps is a pointer to the currently layouted parent block's BPS.
    marginTarget: BlockPositionState
    ancestorsHead: BlockPositionState
    parentBps: BlockPositionState
    exclusions: seq[Exclusion]
    unpositionedFloats: seq[UnpositionedFloat]
    maxFloatHeight: LayoutUnit
    clearOffset: LayoutUnit

  UnpositionedFloat = object
    parentBps: BlockPositionState
    space: AvailableSpace
    box: BlockBox

  BlockPositionState = ref object
    next: BlockPositionState
    box: BlockBox
    offset: Offset # offset relative to the block formatting context
    resolved: bool # has the position been resolved yet?

  Exclusion = object
    offset: Offset
    size: Size
    t: CSSFloat

  Strut = object
    pos: LayoutUnit
    neg: LayoutUnit

type
  LineBoxState = object
    atomstates: seq[InlineAtomState]
    baseline: LayoutUnit
    lineheight: LayoutUnit
    paddingTop: LayoutUnit
    paddingBottom: LayoutUnit
    line: LineBox
    availableWidth: LayoutUnit
    hasExclusion: bool
    charwidth: int
    # Set at the end of layoutText. It helps determine the beginning of the
    # next inline fragment.
    widthAfterWhitespace: LayoutUnit

  InlineAtomState = object
    vertalign: CSSVerticalAlign
    baseline: LayoutUnit
    marginTop: LayoutUnit
    marginBottom: LayoutUnit

  InlineContext = object
    root: RootInlineFragment
    bctx: ptr BlockContext
    bfcOffset: Offset
    currentLine: LineBoxState
    hasshy: bool
    lctx: LayoutState
    lines: seq[LineBox]
    minwidth: LayoutUnit
    space: AvailableSpace
    whitespacenum: int
    whitespaceIsLF: bool
    whitespaceFragment: InlineFragment
    word: InlineAtom
    wordstate: InlineAtomState
    wrappos: int # position of last wrapping opportunity, or -1
    firstTextFragment: InlineFragment
    lastTextFragment: InlineFragment
    errorY: LayoutUnit # rounding error distributed along lines

  InlineState = object
    computed: CSSComputedValues
    node: StyledNode
    fragment: InlineFragment
    firstLine: bool
    startOffsetTop: Offset
    # we do not want to collapse newlines over tag boundaries, so these are
    # in state
    lastrw: int # last rune width of the previous word
    firstrw: int # first rune width of the current word
    prevrw: int # last processed rune's width

func whitespacepre(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP}

func nowrap(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}

func cellwidth(lctx: LayoutState): LayoutUnit =
  lctx.attrs.ppc

func cellwidth(ictx: InlineContext): LayoutUnit =
  ictx.lctx.cellwidth

func cellheight(lctx: LayoutState): LayoutUnit =
  lctx.attrs.ppl

func cellheight(ictx: InlineContext): LayoutUnit =
  ictx.lctx.attrs.ppl

template atoms(state: LineBoxState): untyped =
  state.line.atoms

template size(state: LineBoxState): untyped =
  state.line.size

template offsety(state: var LineBoxState): untyped =
  state.line.offsety

func size(ictx: var InlineContext): var Size =
  ictx.root.size

# Whitespace between words
func computeShift(ictx: InlineContext, state: InlineState): LayoutUnit =
  if ictx.whitespacenum == 0:
    return 0
  if ictx.whitespaceIsLF and state.lastrw == 2 and state.firstrw == 2:
    # skip line feed between double-width characters
    return 0
  if not state.computed.whitespacepre:
    if ictx.currentLine.atoms.len == 0 or
        ictx.currentLine.atoms[^1].t == INLINE_SPACING:
      return 0
  let spacing = state.computed{"word-spacing"}
  if spacing.auto:
    return ictx.cellwidth * ictx.whitespacenum
  return spacing.px(ictx.lctx) * ictx.whitespacenum

proc applyLineHeight(ictx: InlineContext, state: var LineBoxState,
    computed: CSSComputedValues) =
  let lctx = ictx.lctx
  #TODO this should be computed during cascading.
  let lineheight = if computed{"line-height"}.auto: # ergo normal
    lctx.cellheight
  else:
    # Percentage: refers to the font size of the element itself.
    computed{"line-height"}.px(lctx, lctx.cellheight)
  let paddingTop = computed{"padding-top"}.px(lctx, ictx.space.w)
  let paddingBottom = computed{"padding-bottom"}.px(lctx, ictx.space.w)
  state.paddingTop = max(paddingTop, state.paddingTop)
  state.paddingBottom = max(paddingBottom, state.paddingBottom)
  state.lineheight = max(lineheight, state.lineheight)

proc newWord(ictx: var InlineContext, state: var InlineState) =
  ictx.word = InlineAtom(
    t: INLINE_WORD,
    size: Size(h: ictx.cellheight)
  )
  ictx.wordstate = InlineAtomState(
    vertalign: state.computed{"vertical-align"},
    baseline: ictx.cellheight
  )
  ictx.wrappos = -1
  ictx.hasshy = false

proc horizontalAlignLine(ictx: var InlineContext, state: InlineState,
    line: var LineBox, last = false) =
  let width = case ictx.space.w.t
  of MIN_CONTENT, MAX_CONTENT:
    ictx.size.w
  of FIT_CONTENT:
    min(ictx.size.w, ictx.space.w.u)
  of STRETCH:
    max(ictx.size.w, ictx.space.w.u)
  # we don't support directions for now so left = start and right = end
  case state.computed{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT, TEXT_ALIGN_CHA_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CHA_RIGHT:
    # move everything
    let x = max(width, line.size.w) - line.size.w
    for atom in line.atoms.mitems:
      atom.offset.x += x
      ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)
  of TEXT_ALIGN_CENTER, TEXT_ALIGN_CHA_CENTER:
    # NOTE if we need line x offsets, use:
    #let width = width - line.offset.x
    let x = max((max(width, line.size.w)) div 2 - line.size.w div 2, 0)
    for atom in line.atoms.mitems:
      atom.offset.x += x
      ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)
  of TEXT_ALIGN_JUSTIFY:
    if not state.computed.whitespacepre and not last:
      var sumwidth: LayoutUnit = 0
      var spaces = 0
      for atom in line.atoms.mitems:
        if atom.t == INLINE_SPACING:
          discard
        else:
          inc spaces
          sumwidth += atom.size.w
      dec spaces
      if spaces > 0:
        let spacingwidth = (width - sumwidth) div spaces
        line.size.w = 0
        for atom in line.atoms.mitems:
          atom.offset.x = line.size.w
          if atom.t == INLINE_SPACING:
            atom.size.w = spacingwidth
          line.size.w += atom.size.w
  # If necessary, update ictx's width.
  ictx.size.w = max(line.size.w, ictx.size.w)

# Align atoms (inline boxes, text, etc.) vertically (i.e. along the inline
# axis) inside the line.
proc verticalAlignLine(ictx: var InlineContext) =
  # Start with line-height as the baseline and line height.
  let lineheight = ictx.currentLine.lineheight
  ictx.currentLine.size.h = lineheight
  var baseline = lineheight

  # Calculate the line's baseline based on atoms' baseline.
  # Also, collect the maximum vertical margins of inline blocks.
  var marginTop: LayoutUnit = 0
  var bottomEdge = baseline
  for i in 0 ..< ictx.currentLine.atoms.len:
    let atom = ictx.currentLine.atoms[i]
    let iastate = ictx.currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      baseline = max(baseline, iastate.baseline + len)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      baseline = max(baseline, atom.size.h)
    of VERTICAL_ALIGN_MIDDLE:
      baseline = max(baseline, atom.size.h div 2)
    else:
      baseline = max(baseline, iastate.baseline)

  # Resize the line's height based on atoms' height and baseline.
  # The line height should be at least as high as the highest baseline used by
  # an atom plus that atom's height.
  for i in 0 ..< ictx.currentLine.atoms.len:
    let atom = ictx.currentLine.atoms[i]
    let iastate = ictx.currentLine.atomstates[i]
    # In all cases, the line's height must at least equal the atom's height.
    # (Where the atom is actually placed is irrelevant here.)
    ictx.currentLine.size.h = max(ictx.currentLine.size.h, atom.size.h)
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Line height must be at least as high as
      # (line baseline) - (atom baseline) + (atom height) + (extra height).
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      ictx.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h + len, ictx.currentLine.size.h)
    of VERTICAL_ALIGN_MIDDLE:
      # Line height must be at least
      # (line baseline) + (atom height / 2).
      ictx.currentLine.size.h = max(baseline + atom.size.h div 2,
        ictx.currentLine.size.h)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      # Line height must be at least atom height (already ensured above.)
      discard
    else:
      # See baseline (with len = 0).
      ictx.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h, ictx.currentLine.size.h)

  # Now we can calculate the actual position of atoms inside the line.
  for i in 0 ..< ictx.currentLine.atoms.len:
    let iastate = ictx.currentLine.atomstates[i]
    let atom = addr ictx.currentLine.atoms[i]
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Atom is placed at (line baseline) - (atom baseline) - len
      let len = iastate.vertalign.length.px(ictx.lctx, lineheight)
      atom.offset.y = baseline - iastate.baseline - len
    of VERTICAL_ALIGN_MIDDLE:
      # Atom is placed at (line baseline) - ((atom height) / 2)
      atom.offset.y = baseline - atom.size.h div 2
    of VERTICAL_ALIGN_TOP:
      # Atom is placed at the top of the line.
      atom.offset.y = 0
    of VERTICAL_ALIGN_BOTTOM:
      # Atom is placed at the bottom of the line.
      atom.offset.y = ictx.currentLine.size.h - atom.size.h
    else:
      # See baseline (with len = 0).
      atom.offset.y = baseline - iastate.baseline
    # Find the best top margin and bottom edge of all atoms.
    # In fact, we are looking for the lowest top edge and the highest bottom
    # edge of the line, so we have to do this after we know where the atoms
    # will be placed.
    marginTop = max(iastate.marginTop - atom.offset.y, marginTop)
    bottomEdge = max(atom.offset.y + atom.size.h + iastate.marginBottom,
      bottomEdge)

  # Finally, offset all atoms' y position by the largest top margin and the
  # line box's top padding.
  for atom in ictx.currentLine.atoms:
    atom.offset.y += marginTop
    atom.offset.y += ictx.currentLine.paddingTop

  # Set the line height to new top edge + old bottom edge, and set the
  # baseline.
  ictx.currentLine.size.h = max(bottomEdge + marginTop, lineheight)
  ictx.currentLine.baseline = baseline
  # Add padding.
  ictx.currentLine.size.h += ictx.currentLine.paddingTop
  ictx.currentLine.size.h += ictx.currentLine.paddingBottom
  ictx.currentLine.baseline += ictx.currentLine.paddingTop

proc addSpacing(ictx: var InlineContext, width, height: LayoutUnit,
    hang = false) =
  let spacing = InlineAtom(
    t: INLINE_SPACING,
    size: Size(
      w: width,
      h: height
    ),
    offset: Offset(x: ictx.currentLine.size.w)
  )
  let iastate = InlineAtomState(
    baseline: height
    #TODO vertalign?
  )
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    ictx.currentLine.size.w += width
  ictx.currentLine.atomstates.add(iastate)
  ictx.currentLine.atoms.add(spacing)
  ictx.whitespaceFragment.atoms.add(spacing)

proc flushWhitespace(ictx: var InlineContext, state: InlineState,
    hang = false) =
  let shift = ictx.computeShift(state)
  ictx.currentLine.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.addSpacing(shift, ictx.cellheight, hang)

# Prepare the next line's initial width and available width.
# (If space on the left is excluded by floats, set the initial width to
# the end of that space. If space on the right is excluded, set the available
# width to that space.)
proc initLine(ictx: var InlineContext) =
  ictx.currentLine.availableWidth = ictx.space.w.u
  let bctx = ictx.bctx
  #TODO what if maxContent/minContent?
  if bctx.exclusions.len != 0:
    let bfcOffset = ictx.bfcOffset
    let y = ictx.currentLine.line.offsety + bfcOffset.y
    var left = bfcOffset.x
    var right = bfcOffset.x + ictx.currentLine.availableWidth
    for ex in bctx.exclusions:
      if ex.offset.y <= y and y < ex.offset.y + ex.size.h:
        ictx.currentLine.hasExclusion = true
        if ex.t == FLOAT_LEFT:
          left = ex.offset.x + ex.size.w
        else:
          right = ex.offset.x
    ictx.currentLine.line.size.w = left - bfcOffset.x
    ictx.currentLine.availableWidth = right - bfcOffset.x

proc finishLine(ictx: var InlineContext, state: var InlineState, wrap: bool,
    force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    let whitespace = state.computed{"white-space"}
    if whitespace == WHITESPACE_PRE:
      ictx.flushWhitespace(state)
    elif whitespace == WHITESPACE_PRE_WRAP:
      ictx.flushWhitespace(state, hang = true)
    else:
      ictx.whitespacenum = 0
    ictx.verticalAlignLine()
    # add line to ictx
    let y = ictx.currentLine.offsety
    # * set first baseline if this is the first line box
    # * always set last baseline (so the baseline of the last line box remains)
    if ictx.lines.len == 0:
      ictx.root.firstBaseline = y + ictx.currentLine.baseline
    ictx.root.baseline = y + ictx.currentLine.baseline
    ictx.size.h += ictx.currentLine.size.h
    let lineWidth = if wrap:
      ictx.currentLine.availableWidth
    else:
      ictx.currentLine.size.w
    if state.firstLine:
      #TODO padding top
      state.fragment.startOffset = Offset(
        x: state.startOffsetTop.x,
        y: y + ictx.currentLine.size.h
      )
      state.fragment.size.w = lineWidth - state.startOffsetTop.x
      state.firstLine = false
    else:
      state.fragment.size.w = max(lineWidth, state.fragment.size.w)
    ictx.size.w = max(ictx.size.w, lineWidth)
    # count error
    if ictx.lines.len > 0:
      let dy = ictx.currentLine.line.offsety - ictx.lines[^1].offsety
      ictx.errorY += dy - toInt(dy div ictx.cellheight) * ictx.cellheight
    ictx.lines.add(ictx.currentLine.line)
    ictx.currentLine = LineBoxState(
      line: LineBox(offsety: y + ictx.currentLine.size.h)
    )
    ictx.initLine()

proc finish(ictx: var InlineContext, state: var InlineState) =
  ictx.finishLine(state, wrap = false)
  if ictx.lines.len > 0:
    for i in 0 ..< ictx.lines.len - 1:
      ictx.horizontalAlignLine(state, ictx.lines[i], last = false)
    ictx.horizontalAlignLine(state, ictx.lines[^1], last = true)

func minwidth(atom: InlineAtom): LayoutUnit =
  if atom.t == INLINE_BLOCK:
    return atom.innerbox.xminwidth
  return atom.size.w

func shouldWrap(ictx: InlineContext, w: LayoutUnit,
    pcomputed: CSSComputedValues): bool =
  if pcomputed != nil and pcomputed.nowrap:
    return false
  if ictx.space.w.t == MAX_CONTENT:
    return false # no wrap with max-content
  if ictx.space.w.t == MIN_CONTENT:
    return true # always wrap with min-content
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

func shouldWrap2(ictx: InlineContext, w: LayoutUnit): bool =
  if not ictx.currentLine.hasExclusion:
    return false
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

# Start a new line, even if the previous one is empty
proc flushLine(ictx: var InlineContext, state: var InlineState) =
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  ictx.finishLine(state, wrap = false, force = true)

# Add an inline atom atom, with state iastate.
# Returns true on newline.
proc addAtom(ictx: var InlineContext, state: var InlineState,
    iastate: InlineAtomState, atom: InlineAtom): bool =
  result = false
  var shift = ictx.computeShift(state)
  ictx.whitespacenum = 0
  # Line wrapping
  if ictx.shouldWrap(atom.size.w + shift, state.computed):
    ictx.finishLine(state, wrap = true, force = false)
    result = true
    # Recompute on newline
    shift = ictx.computeShift(state)
    # For floats: flush lines until we can place the atom.
    #TODO this is inefficient
    while ictx.shouldWrap2(atom.size.w + shift):
      ictx.flushLine(state)
      # Recompute on newline
      shift = ictx.computeShift(state)
  if atom.size.w > 0 and atom.size.h > 0:
    if shift > 0:
      ictx.addSpacing(shift, ictx.cellheight)
    ictx.minwidth = max(ictx.minwidth, atom.minwidth)
    ictx.applyLineHeight(ictx.currentLine, state.computed)
    if atom.t == INLINE_WORD:
      ictx.currentLine.charwidth = 0
    ictx.currentLine.atoms.add(atom)
    state.fragment.atoms.add(atom)
    ictx.currentLine.atomstates.add(iastate)
    ictx.currentLine.atoms[^1].offset.x += ictx.currentLine.size.w
    ictx.currentLine.size.w += atom.size.w

proc addWord(ictx: var InlineContext, state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    ictx.word.str.mnormalize() #TODO this may break on EOL.
    result = ictx.addAtom(state, ictx.wordstate, ictx.word)
    ictx.newWord(state)

proc addWordEOL(ictx: var InlineContext, state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    if ictx.wrappos != -1:
      let leftstr = ictx.word.str.substr(ictx.wrappos)
      ictx.word.str.setLen(ictx.wrappos)
      if ictx.hasshy:
        const shy = $Rune(0xAD) # soft hyphen
        ictx.word.str &= shy
        ictx.hasshy = false
      result = ictx.addWord(state)
      ictx.word.str = leftstr
      ictx.word.size.w = leftstr.width() * ictx.cellwidth
    else:
      result = ictx.addWord(state)

proc checkWrap(ictx: var InlineContext, state: var InlineState, r: Rune) =
  if state.computed.nowrap:
    return
  let shift = ictx.computeShift(state)
  let rw = r.width()
  state.prevrw = rw
  if ictx.word.str.len == 0:
    state.firstrw = rw
  case state.computed{"word-break"}
  of WORD_BREAK_NORMAL:
    if rw == 2 or ictx.wrappos != -1: # break on cjk and wrap opportunities
      let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
      if ictx.shouldWrap(plusWidth, nil):
        if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
          ictx.finishLine(state, wrap = true)
          ictx.whitespacenum = 0
  of WORD_BREAK_BREAK_ALL:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
    if ictx.shouldWrap(plusWidth, nil):
      if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
        ictx.finishLine(state, wrap = true)
        ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellwidth
    if ictx.shouldWrap(plusWidth, nil):
      ictx.finishLine(state, wrap = true)
      ictx.whitespacenum = 0

proc processWhitespace(ictx: var InlineContext, state: var InlineState,
    c: char) =
  discard ictx.addWord(state)
  case state.computed{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    if ictx.whitespacenum < 1:
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
      ictx.whitespaceIsLF = c == '\n'
    if c != '\n':
      ictx.whitespaceIsLF = false
  of WHITESPACE_PRE_LINE:
    if c == '\n':
      ictx.flushLine(state)
    elif ictx.whitespacenum < 1:
      ictx.whitespaceIsLF = false
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
  of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    #TODO whitespace type should be preserved here. (it isn't, because
    # it would break tabs in the current buffer model.)
    ictx.whitespaceIsLF = false
    if c == '\n':
      ictx.flushLine(state)
    elif c == '\t':
      let prev = ictx.currentLine.charwidth
      ictx.currentLine.charwidth = ((ictx.currentLine.charwidth +
        ictx.whitespacenum) div 8 + 1) * 8 - ictx.whitespacenum
      ictx.whitespacenum += ictx.currentLine.charwidth - prev
      ictx.whitespaceFragment = state.fragment
    else:
      inc ictx.whitespacenum
      ictx.whitespaceFragment = state.fragment
  # set the "last word's last rune width" to the previous rune width
  state.lastrw = state.prevrw

func initInlineContext(bctx: var BlockContext, space: AvailableSpace,
    bfcOffset: Offset, root: RootInlineFragment): InlineContext =
  var ictx = InlineContext(
    currentLine: LineBoxState(
      line: LineBox()
    ),
    bctx: addr bctx,
    lctx: bctx.lctx,
    bfcOffset: bfcOffset,
    space: space,
    root: root
  )
  ictx.initLine()
  return ictx

proc layoutTextLoop(ictx: var InlineContext, state: var InlineState, str: string) =
  var i = 0
  while i < str.len:
    let c = str[i]
    if c in Ascii:
      if c in AsciiWhitespace:
        ictx.processWhitespace(state, c)
      else:
        let r = Rune(c)
        ictx.checkWrap(state, r)
        ictx.word.str &= c
        let w = r.width()
        ictx.word.size.w += w * ictx.cellwidth
        ictx.currentLine.charwidth += w
        if c == '-': # ascii dash
          ictx.wrappos = ictx.word.str.len
          ictx.hasshy = false
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      ictx.checkWrap(state, r)
      if r == Rune(0xAD): # soft hyphen
        ictx.wrappos = ictx.word.str.len
        ictx.hasshy = true
      else:
        ictx.word.str &= r
        let w = r.width()
        ictx.word.size.w += w * ictx.cellwidth
        ictx.currentLine.charwidth += w
  discard ictx.addWord(state)
  let shift = ictx.computeShift(state)
  ictx.currentLine.widthAfterWhitespace = ictx.currentLine.size.w + shift

proc layoutText(ictx: var InlineContext, state: var InlineState, str: string) =
  ictx.flushWhitespace(state)
  ictx.newWord(state)
  case state.computed{"text-transform"}
  of TEXT_TRANSFORM_NONE:
    ictx.layoutTextLoop(state, str)
    {.linearScanEnd.}
  of TEXT_TRANSFORM_CAPITALIZE:
    ictx.layoutTextLoop(state, str.capitalize())
  of TEXT_TRANSFORM_UPPERCASE:
    ictx.layoutTextLoop(state, str.toUpper())
  of TEXT_TRANSFORM_LOWERCASE:
    ictx.layoutTextLoop(state, str.toLower())
  of TEXT_TRANSFORM_FULL_WIDTH:
    ictx.layoutTextLoop(state, str.fullwidth())
  of TEXT_TRANSFORM_FULL_SIZE_KANA:
    ictx.layoutTextLoop(state, str.fullsize())
  of TEXT_TRANSFORM_CHA_HALF_WIDTH:
    ictx.layoutTextLoop(state, str.halfwidth())

func spx(l: CSSLength, lctx: LayoutState, p: SizeConstraint,
    computed: CSSComputedValues, padding: LayoutUnit): LayoutUnit =
  let u = l.px(lctx, p)
  if computed{"box-sizing"} == BOX_SIZING_BORDER_BOX:
    return max(u - padding, 0)
  return max(u, 0)

func spx(l: CSSLength, lctx: LayoutState, p: Option[LayoutUnit],
    computed: CSSComputedValues, padding: LayoutUnit): Option[LayoutUnit] =
  let u = l.px(lctx, p)
  if u.isSome:
    let u = u.get
    if computed{"box-sizing"} == BOX_SIZING_BORDER_BOX:
      return some(max(u - padding, 0))
    return some(max(u, 0))
  return u

proc resolveContentWidth(sizes: var ResolvedSizes, widthpx: LayoutUnit,
    containingWidth: SizeConstraint, computed: CSSComputedValues,
    isauto = false) =
  if not sizes.space.w.isDefinite():
    # width is indefinite, so no conflicts can be resolved here.
    return
  let total = widthpx + sizes.margin.left + sizes.margin.right +
    sizes.padding.left + sizes.padding.right
  let underflow = containingWidth.u - total
  if isauto or sizes.space.w.t == FIT_CONTENT:
    if underflow >= 0:
      sizes.space.w = SizeConstraint(t: sizes.space.w.t, u: underflow)
    else:
      sizes.margin.right += underflow
  elif underflow > 0:
    if not computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin.right += underflow
    elif not computed{"margin-left"}.auto and computed{"margin-right"}.auto:
      sizes.margin.right = underflow
    elif computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin.left = underflow
    else:
      sizes.margin.left = underflow div 2
      sizes.margin.right = underflow div 2

proc resolveMargins(availableWidth: SizeConstraint, lctx: LayoutState,
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return RelativeRect(
    top: computed{"margin-top"}.px(lctx, availableWidth),
    bottom: computed{"margin-bottom"}.px(lctx, availableWidth),
    left: computed{"margin-left"}.px(lctx, availableWidth),
    right: computed{"margin-right"}.px(lctx, availableWidth)
  )

proc resolvePadding(availableWidth: SizeConstraint, lctx: LayoutState,
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return RelativeRect(
    top: computed{"padding-top"}.px(lctx, availableWidth),
    bottom: computed{"padding-bottom"}.px(lctx, availableWidth),
    left: computed{"padding-left"}.px(lctx, availableWidth),
    right: computed{"padding-right"}.px(lctx, availableWidth)
  )

proc resolveBlockWidth(sizes: var ResolvedSizes,
    containingWidth: SizeConstraint, computed: CSSComputedValues,
    lctx: LayoutState) =
  let width = computed{"width"}
  let padding = sizes.padding.left + sizes.padding.right
  var widthpx: LayoutUnit = 0
  if not width.auto and width.canpx(containingWidth):
    widthpx = width.spx(lctx, containingWidth, computed, padding)
    sizes.space.w = stretch(widthpx)
  sizes.resolveContentWidth(widthpx, containingWidth, computed, width.auto)
  if not computed{"max-width"}.auto:
    let maxWidth = computed{"max-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.maxWidth = maxWidth
    if sizes.space.w.t in {STRETCH, FIT_CONTENT} and
        maxWidth < sizes.space.w.u or sizes.space.w.t == MAX_CONTENT:
      sizes.space.w = stretch(maxWidth) #TODO is stretch ok here?
      if sizes.space.w.t == STRETCH:
        # available width would stretch over max-width
        sizes.space.w = stretch(maxWidth)
      else: # FIT_CONTENT
        # available width could be higher than max-width (but not necessarily)
        sizes.space.w = fitContent(maxWidth)
      sizes.resolveContentWidth(maxWidth, containingWidth, computed)
  if not computed{"min-width"}.auto:
    let minWidth = computed{"min-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.minWidth = minWidth
    if sizes.space.w.t in {STRETCH, FIT_CONTENT} and
        minWidth > sizes.space.w.u or sizes.space.w.t == MIN_CONTENT:
      # two cases:
      # * available width is stretched under min-width. in this case,
      #   stretch to min-width instead.
      # * available width is fit under min-width. in this case, stretch to
      #   min-width as well (as we must satisfy min-width >= width).
      sizes.space.w = stretch(minWidth)
      sizes.resolveContentWidth(minWidth, containingWidth, computed)

proc resolveBlockHeight(sizes: var ResolvedSizes,
    containingHeight: SizeConstraint, percHeight: Option[LayoutUnit],
    computed: CSSComputedValues, lctx: LayoutState) =
  let height = computed{"height"}
  let padding = sizes.padding.top + sizes.padding.bottom
  var heightpx: LayoutUnit = 0
  if not height.auto and height.canpx(percHeight):
    heightpx = height.spx(lctx, percHeight, computed, padding).get
    sizes.space.h = stretch(heightpx)
  if not computed{"max-height"}.auto:
    let maxHeight = computed{"max-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.maxHeight = maxHeight.get(high(LayoutUnit))
    if maxHeight.isSome:
      let maxHeight = maxHeight.get
      if sizes.space.h.t in {STRETCH, FIT_CONTENT} and
          maxHeight < sizes.space.h.u or sizes.space.h.t == MAX_CONTENT:
        # same reasoning as for width.
        if sizes.space.h.t == STRETCH:
          sizes.space.h = stretch(maxHeight)
        else: # FIT_CONTENT
          sizes.space.h = fitContent(maxHeight)
  if not computed{"min-height"}.auto:
    let minHeight = computed{"min-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.minHeight = minHeight.get(0)
    if minHeight.isSome:
      let minHeight = minHeight.get
      if sizes.space.h.t in {STRETCH, FIT_CONTENT} and
          minHeight > sizes.space.h.u or sizes.space.h.t == MIN_CONTENT:
        # same reasoning as for width.
        sizes.space.h = stretch(minHeight)

proc resolveAbsoluteWidth(sizes: var ResolvedSizes,
    containingWidth: SizeConstraint, computed: CSSComputedValues,
    lctx: LayoutState) =
  let left = computed{"left"}
  let right = computed{"right"}
  let width = computed{"width"}
  if width.auto:
    if not left.auto and not right.auto:
      # width is auto and left & right are not auto.
      # Solve for width.
      if containingWidth.isDefinite:
        let leftpx = left.px(lctx, containingWidth)
        let rightpx = right.px(lctx, containingWidth)
        let u = containingWidth.u - leftpx - rightpx -
          sizes.margin.left - sizes.margin.right -
          sizes.padding.left - sizes.padding.right
        sizes.space.w = stretch(max(u, 0))
      else:
        sizes.space.w = containingWidth
    else:
      # Return shrink to fit and solve for left/right.
      # Note that we do not know content width yet, so it is impossible to
      # solve left/right yet.
      sizes.space.w = fitContent(containingWidth)
  else:
    let padding = sizes.padding.left + sizes.padding.right
    let widthpx = width.spx(lctx, containingWidth, computed, padding)
    # We could solve for left/right here, as available width is known.
    # Nevertheless, it is only needed for positioning, so we do not solve
    # them yet.
    sizes.space.w = stretch(widthpx)

proc resolveAbsoluteHeight(sizes: var ResolvedSizes,
    containingHeight: SizeConstraint, computed: CSSComputedValues,
    lctx: LayoutState) =
  #TODO this might be incorrect because of percHeight?
  let top = computed{"top"}
  let bottom = computed{"bottom"}
  let height = computed{"height"}
  if height.auto:
    if not top.auto and not bottom.auto:
      # height is auto and top & bottom are not auto.
      # Solve for height.
      if containingHeight.isDefinite:
        let toppx = top.px(lctx, containingHeight)
        let bottompx = bottom.px(lctx, containingHeight)
        #TODO I assume border collapsing does not matter here?
        let u = containingHeight.u - toppx - bottompx -
          sizes.margin.top - sizes.margin.bottom -
          sizes.padding.top - sizes.padding.bottom
        sizes.space.h = stretch(max(u, 0))
      else:
        sizes.space.h = containingHeight
    else:
      sizes.space.h = fitContent(containingHeight)
  else:
    let padding = sizes.padding.top + sizes.padding.bottom
    let heightpx = height.spx(lctx, containingHeight, computed, padding)
    sizes.space.h = stretch(heightpx)

proc resolveBlockSizes(lctx: LayoutState, containingWidth,
    containingHeight: SizeConstraint, percHeight: Option[LayoutUnit],
    computed: CSSComputedValues): ResolvedSizes =
  var sizes = ResolvedSizes(
    margin: resolveMargins(containingWidth, lctx, computed),
    padding: resolvePadding(containingWidth, lctx, computed),
    # Take defined sizes if our width/height resolves to auto.
    # For block boxes, this is:
    # (width: stretch(parentWidth), height: max-content)
    space: AvailableSpace(w: containingWidth, h: containingHeight),
    minWidth: 0,
    maxWidth: high(LayoutUnit),
    minHeight: 0,
    maxHeight: high(LayoutUnit)
  )
  # Finally, calculate available width and height.
  sizes.resolveBlockWidth(containingWidth, computed, lctx)
  sizes.resolveBlockHeight(containingHeight, percHeight, computed, lctx)
  return sizes

# Calculate and resolve available width & height for absolutely positioned
# boxes.
proc resolveAbsoluteSizes(lctx: LayoutState, computed: CSSComputedValues):
    ResolvedSizes =
  let containingWidth = lctx.positioned[^1].w
  let containingHeight = lctx.positioned[^1].h
  var sizes = ResolvedSizes(
    margin: resolveMargins(containingWidth, lctx, computed),
    padding: resolvePadding(containingWidth, lctx, computed),
    minWidth: 0,
    maxWidth: high(LayoutUnit)
  )
  sizes.resolveAbsoluteWidth(containingWidth, computed, lctx)
  sizes.resolveAbsoluteHeight(containingHeight, computed, lctx)
  return sizes

# Calculate and resolve available width & height for floating boxes.
proc resolveFloatSizes(lctx: LayoutState, containingWidth,
    containingHeight: SizeConstraint, percHeight: Option[LayoutUnit],
    computed: CSSComputedValues): ResolvedSizes =
  var space = AvailableSpace(
    w: fitContent(containingWidth),
    h: containingHeight
  )
  let padding = resolvePadding(containingWidth, lctx, computed)
  let inlinePadding = padding.left + padding.right
  let blockPadding = padding.top + padding.bottom
  let minWidth: LayoutUnit = if not computed{"min-width"}.auto:
    computed{"min-width"}.spx(lctx, containingWidth, computed, inlinePadding)
  else:
    0
  let maxWidth = if not computed{"max-width"}.auto:
    computed{"max-width"}.spx(lctx, containingWidth, computed, inlinePadding)
  else:
    high(LayoutUnit)
  let width = computed{"width"}
  if not width.auto and width.canpx(containingWidth):
    let widthpx = width.spx(lctx, containingWidth, computed, inlinePadding)
    space.w = stretch(clamp(widthpx, minWidth, maxWidth))
  elif containingWidth.isDefinite():
    space.w = fitContent(clamp(containingWidth.u, minWidth, maxWidth))
  let minHeight: LayoutUnit = if not computed{"min-height"}.auto:
    computed{"min-height"}.spx(lctx, percHeight, computed, blockPadding).get(0)
  else:
    0
  let maxHeight = if not computed{"max-height"}.auto:
    computed{"max-height"}.spx(lctx, percHeight, computed, blockPadding)
      .get(high(LayoutUnit))
  else:
    high(LayoutUnit)
  let height = computed{"height"}
  if not height.auto and height.canpx(containingHeight):
    let heightpx = height.px(lctx, containingHeight)
    space.h = stretch(clamp(heightpx, minHeight, maxHeight))
  elif containingHeight.isDefinite():
    space.h = fitContent(clamp(containingHeight.u, minHeight, maxHeight))
  return ResolvedSizes(
    margin: resolveMargins(containingWidth, lctx, computed),
    padding: padding,
    space: space,
    minWidth: minWidth,
    maxWidth: maxWidth,
    minHeight: minHeight,
    maxHeight: maxHeight
  )

# Calculate and resolve available width & height for box children.
# containingWidth: width of the containing box
# containingHeight: ditto, but with height.
# Note that this is not the final content size, just the amount of space
# available for content.
# The percentage width/height is generally
# availableSize.isDefinite() ? availableSize.u : 0, but for some reason it
# differs for the root height (TODO: and all heights in quirks mode) in that
# it uses the lctx height. Therefore we pass percHeight as a separate
# parameter. (TODO surely there is a better solution to this?)
proc resolveSizes(lctx: LayoutState, containingWidth,
    containingHeight: SizeConstraint, percHeight: Option[LayoutUnit],
    computed: CSSComputedValues): ResolvedSizes =
  if computed{"position"} == POSITION_ABSOLUTE:
    return lctx.resolveAbsoluteSizes(computed)
  elif computed{"float"} != FLOAT_NONE:
    return lctx.resolveFloatSizes(containingWidth, containingHeight,
      percHeight, computed)
  else:
    return lctx.resolveBlockSizes(containingWidth, containingHeight,
      percHeight, computed)

proc resolveTableCellSizes(lctx: LayoutState, containingWidth,
    containingHeight: SizeConstraint, override: bool,
    computed: CSSComputedValues): ResolvedSizes =
  var sizes = ResolvedSizes(
    padding: resolvePadding(containingWidth, lctx, computed),
    space: AvailableSpace(w: containingWidth, h: containingHeight),
    minWidth: 0,
    maxWidth: high(LayoutUnit),
    minHeight: 0,
    maxHeight: high(LayoutUnit)
  )
  if not override:
    let width = computed{"width"}
    if not width.auto and width.unit != UNIT_PERC:
      sizes.space.w = stretch(width.px(lctx))
  sizes.space.w.u -= sizes.padding.left
  sizes.space.w.u -= sizes.padding.right
  if not override:
    let height = computed{"height"}
    if not height.auto and height.unit != UNIT_PERC:
      sizes.space.h = stretch(height.px(lctx))
  return sizes

func toPercSize(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

proc append(a: var Strut, b: LayoutUnit) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum(a: Strut): LayoutUnit =
  return a.pos + a.neg

proc layoutRootInline(bctx: var BlockContext, inlines: seq[BoxBuilder],
  space: AvailableSpace, computed: CSSComputedValues, offset,
  bfcOffset: Offset): RootInlineFragment
proc layoutBlock(bctx: var BlockContext, box: BlockBox,
  builder: BlockBoxBuilder, sizes: ResolvedSizes)
proc layoutTable(lctx: LayoutState, table: BlockBox, builder: TableBoxBuilder,
  sizes: ResolvedSizes)

# Note: padding must still be applied after this.
proc applyWidth(box: BlockBox, sizes: ResolvedSizes,
    maxChildWidth: LayoutUnit) =
  # Make the box as small/large as the content's width or specified width.
  box.size.w = maxChildWidth.applySizeConstraint(sizes.space.w)
  # Then, clamp it to minWidth and maxWidth (if applicable).
  box.size.w = clamp(box.size.w, sizes.minWidth, sizes.maxWidth)

proc applyHeight(box: BlockBox, sizes: ResolvedSizes,
    maxChildHeight: LayoutUnit) =
  # Make the box as small/large as the content's width or specified width.
  box.size.h = maxChildHeight.applySizeConstraint(sizes.space.h)
  # Then, clamp it to minWidth and maxWidth (if applicable).
  box.size.h = clamp(box.size.h, sizes.minHeight, sizes.maxHeight)

proc applyPadding(box: BlockBox, padding: RelativeRect) =
  box.size.w += padding.left
  box.size.w += padding.right
  box.size.h += padding.top
  box.size.h += padding.bottom

func bfcOffset(bctx: BlockContext): Offset =
  if bctx.parentBps != nil:
    return bctx.parentBps.offset
  return Offset()

proc layoutInline(bctx: var BlockContext, box: BlockBox,
    children: seq[BoxBuilder], sizes: ResolvedSizes) =
  var bfcOffset = bctx.bfcOffset
  let offset = Offset(x: sizes.padding.left, y: sizes.padding.top)
  bfcOffset.x += box.offset.x + offset.x
  bfcOffset.y += box.offset.y + offset.y
  box.inline = bctx.layoutRootInline(children, sizes.space, box.computed,
    offset, bfcOffset)
  box.xminwidth = max(box.xminwidth, box.inline.xminwidth)
  box.size.w = box.inline.size.w + sizes.padding.left + sizes.padding.right
  box.applyWidth(sizes, box.inline.size.w)
  box.applyHeight(sizes, box.inline.size.h)
  box.applyPadding(sizes.padding)
  box.baseline = offset.y + box.inline.baseline
  box.firstBaseline = offset.y + box.inline.firstBaseline

const DisplayBlockLike = {DISPLAY_BLOCK, DISPLAY_LIST_ITEM,
  DISPLAY_INLINE_BLOCK}

# Return true if no more margin collapsing can occur for the current strut.
func canFlushMargins(builder: BlockBoxBuilder, sizes: ResolvedSizes): bool =
  if builder.computed{"position"} in {POSITION_ABSOLUTE, POSITION_FIXED}:
    return false
  return sizes.padding.top != 0 or sizes.padding.bottom != 0 or
    builder.inlinelayout or builder.computed{"display"} notin DisplayBlockLike

proc flushMargins(bctx: var BlockContext, box: BlockBox) =
  # Apply uncommitted margins.
  let margin = bctx.marginTodo.sum()
  if bctx.marginTarget == nil:
    box.offset.y += margin
  else:
    if bctx.marginTarget.box != nil:
      bctx.marginTarget.box.offset.y += margin
    var p = bctx.marginTarget
    while true:
      p.offset.y += margin
      p.resolved = true
      p = p.next
      if p == nil: break
    bctx.marginTarget = nil
  bctx.marginTodo = Strut()

proc clearFloats(offset: var Offset, bctx: var BlockContext, clear: CSSClear) =
  var y = bctx.bfcOffset.y + offset.y
  case clear
  of CLEAR_LEFT, CLEAR_INLINE_START:
    for ex in bctx.exclusions:
      if ex.t == FLOAT_LEFT:
        y = max(ex.offset.y + ex.size.h, y)
  of CLEAR_RIGHT, CLEAR_INLINE_END:
    for ex in bctx.exclusions:
      if ex.t == FLOAT_RIGHT:
        y = max(ex.offset.y + ex.size.h, y)
  of CLEAR_BOTH:
    for ex in bctx.exclusions:
      y = max(ex.offset.y + ex.size.h, y)
  of CLEAR_NONE: assert false
  bctx.clearOffset = y
  offset.y = y - bctx.bfcOffset.y

type
  BlockState = object
    offset: Offset
    maxChildWidth: LayoutUnit
    nested: seq[BlockBox]
    space: AvailableSpace
    xminwidth: LayoutUnit
    prevParentBps: BlockPositionState
    needsReLayout: bool
    # State kept for when a re-layout is necessary:
    oldMarginTodo: Strut
    oldExclusionsLen: int
    initialMarginTarget: BlockPositionState
    initialTargetOffset: Offset
    initialParentOffset: Offset

func findNextFloatOffset(bctx: BlockContext, offset: Offset, size: Size,
    space: AvailableSpace, float: CSSFloat, clear: CSSClear): Offset =
  # Algorithm originally from QEmacs.
  var y = offset.y
  let leftStart = offset.x
  let rightStart = max(offset.x + size.w, space.w.u)
  while true:
    var left = leftStart
    var right = rightStart
    var miny = high(LayoutUnit)
    let cy2 = y + size.h
    for ex in bctx.exclusions:
      let ey2 = ex.offset.y + ex.size.h
      if cy2 >= ex.offset.y and y < ey2:
        let ex2 = ex.offset.x + ex.size.w
        if left + size.w >= ex.offset.x and left < ex2:
          left = ex2
        if right + size.w > ex.offset.x and right <= ex2:
          right = ex.offset.x
        miny = min(ey2, miny)
    if right - left >= size.w or miny == high(LayoutUnit):
      # Enough space, or no other exclusions found at this y offset.
      if float == FLOAT_LEFT:
        return Offset(x: left, y: y)
      else: # FLOAT_RIGHT
        return Offset(x: right - size.w, y: y)
    # Move y to the bottom exclusion edge at the lowest y (where the exclusion
    # still intersects with the previous y).
    y = miny

proc positionFloat(bctx: var BlockContext, child: BlockBox,
    space: AvailableSpace, bfcOffset: Offset) =
  let clear = child.computed{"clear"}
  if clear != CLEAR_NONE:
    child.offset.clearFloats(bctx, clear)
  let size = Size(
    w: child.margin.left + child.margin.right + child.size.w,
    h: child.margin.top + child.margin.bottom + child.size.h
  )
  let childBfcOffset = Offset(
    x: bfcOffset.x + child.offset.x - child.margin.left,
    y: max(bfcOffset.y + child.offset.y - child.margin.top, bctx.clearOffset)
  )
  assert space.w.t != FIT_CONTENT
  let ft = child.computed{"float"}
  assert ft != FLOAT_NONE
  let offset = bctx.findNextFloatOffset(childBfcOffset, size, space, ft, clear)
  child.offset = Offset(
    x: offset.x - bfcOffset.x + child.margin.left,
    y: offset.y - bfcOffset.y + child.margin.top
  )
  let ex = Exclusion(
    offset: offset,
    size: size,
    t: ft
  )
  bctx.exclusions.add(ex)
  bctx.maxFloatHeight = max(bctx.maxFloatHeight, ex.offset.y + ex.size.h)

proc positionFloats(bctx: var BlockContext) =
  for f in bctx.unpositionedFloats:
    bctx.positionFloat(f.box, f.space, f.parentBps.offset)
  bctx.unpositionedFloats.setLen(0)

func establishesBFC(computed: CSSComputedValues): bool =
  return computed{"float"} != FLOAT_NONE or
    computed{"position"} in {POSITION_ABSOLUTE, POSITION_FIXED} or
    computed{"display"} in {DISPLAY_INLINE_BLOCK, DISPLAY_FLOW_ROOT} +
      InternalTableBox
    #TODO overflow, contain, flex, grid, multicol, column-span

proc layoutFlow(bctx: var BlockContext, box: BlockBox, builder: BlockBoxBuilder,
    sizes: ResolvedSizes) =
  let isBfc = builder.computed.establishesBFC()
  if not isBfc:
    bctx.marginTodo.append(sizes.margin.top)
  if builder.canFlushMargins(sizes):
    bctx.flushMargins(box)
    bctx.positionFloats()
  if builder.computed{"clear"} != CLEAR_NONE:
    box.offset.clearFloats(bctx, builder.computed{"clear"})
  if builder.inlinelayout:
    # Builder only contains inline boxes.
    bctx.layoutInline(box, builder.children, sizes)
  else:
    # Builder only contains block boxes.
    bctx.layoutBlock(box, builder, sizes)
  if not isBfc:
    bctx.marginTodo.append(sizes.margin.bottom)

func toperc100(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

# parentWidth, parentHeight: width/height of the containing block.
proc addInlineBlock(ictx: var InlineContext, state: var InlineState,
    builder: BlockBoxBuilder, parentWidth, parentHeight: SizeConstraint) =
  let lctx = ictx.lctx
  let percHeight = parentHeight.toperc100()
  let sizes = lctx.resolveFloatSizes(parentWidth, maxContent(), percHeight,
    builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin
  )
  var bctx = BlockContext(lctx: lctx)
  bctx.marginTodo.append(sizes.margin.top)
  case builder.computed{"display"}
  of DISPLAY_INLINE_BLOCK:
    bctx.layoutFlow(box, builder, sizes)
  of DISPLAY_INLINE_TABLE:
    lctx.layoutTable(box, TableBoxBuilder(builder), sizes)
  else:
    assert false, $builder.computed{"display"}
  bctx.positionFloats()
  bctx.marginTodo.append(sizes.margin.bottom)
  let marginTop = box.offset.y
  let marginBottom = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.offset.y + box.size.h + marginBottom:
    box.size.h = bctx.maxFloatHeight - box.offset.y - marginBottom
  box.offset.y = 0
  # Apply the block box's properties to the atom itself.
  let iblock = InlineAtom(
    t: INLINE_BLOCK,
    innerbox: box,
    offset: Offset(x: sizes.margin.left),
    size: Size(
      w: box.size.w + sizes.margin.left + sizes.margin.right,
      h: box.size.h
    )
  )
  let iastate = InlineAtomState(
    baseline: box.baseline,
    vertalign: builder.computed{"vertical-align"},
    marginTop: marginTop,
    marginBottom: bctx.marginTodo.sum()
  )
  discard ictx.addAtom(state, iastate, iblock)
  ictx.whitespacenum = 0

proc layoutInline(ictx: var InlineContext, box: InlineBoxBuilder):
    InlineFragment =
  let lctx = ictx.lctx
  let fragment = InlineFragment(
    computed: box.computed,
    node: box.node,
    splitType: box.splitType
  )
  if stSplitStart in box.splitType:
    let marginLeft = box.computed{"margin-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginLeft
  var state = InlineState(
    computed: box.computed,
    node: box.node,
    fragment: fragment,
    firstLine: true,
    startOffsetTop: Offset(
      x: ictx.currentLine.widthAfterWhitespace,
      y: ictx.currentLine.line.offsety
    )
  )
  if box.newline:
    ictx.flushLine(state)
  if stSplitStart in box.splitType:
    let paddingLeft = box.computed{"padding-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingLeft

  assert box.children.len == 0 or box.text.len == 0
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  if ictx.firstTextFragment == nil:
    ictx.firstTextFragment = fragment
  ictx.lastTextFragment = fragment
  for text in box.text:
    ictx.layoutText(state, text)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = ictx.layoutInline(InlineBoxBuilder(child))
      state.fragment.children.add(child)
    of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
      let child = BlockBoxBuilder(child)
      let w = fitContent(ictx.space.w)
      let h = ictx.space.h
      ictx.addInlineBlock(state, child, w, h)
    else:
      assert false, "child.t is " & $child.computed{"display"}

  if stSplitEnd in box.splitType:
    let paddingRight = box.computed{"padding-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingRight
    let marginRight = box.computed{"margin-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginRight
  #TODO we verticalAlignLine here to know line height, but this is incredibly
  # ugly. Maybe figure out some incremental line alignment scheme instead?
  ictx.verticalAlignLine()
  if state.firstLine:
    fragment.startOffset = Offset(
      x: state.startOffsetTop.x,
      y: ictx.currentLine.offsety + ictx.currentLine.size.h
    )
  fragment.endOffset = Offset(
    x: ictx.currentLine.size.w,
    y: ictx.currentLine.offsety
  )
  fragment.size.h = ictx.currentLine.offsety + ictx.currentLine.size.h -
    state.startOffsetTop.y
  return fragment

proc positionAtoms(ictx: var InlineContext) =
  if ictx.lines.len == 0:
    return
  let H = ictx.lines.len - 1
  let erry = if H != 0:
    ictx.errorY / H
  else:
    0
  var i = 1
  for line in ictx.lines:
    let erry0 = erry * i
    for atom in line.atoms:
      atom.offset.y += line.offsety - erry0
    inc i

proc layoutRootInline(bctx: var BlockContext, inlines: seq[BoxBuilder],
    space: AvailableSpace, computed: CSSComputedValues, offset,
    bfcOffset: Offset): RootInlineFragment =
  let root = RootInlineFragment(
    offset: offset,
    fragment: InlineFragment(computed: computed)
  )
  var ictx = bctx.initInlineContext(space, bfcOffset, root)
  for child in inlines:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let childFragment = ictx.layoutInline(InlineBoxBuilder(child))
      root.fragment.children.add(childFragment)
    of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
      #TODO ???
      var state = InlineState(
        computed: computed,
        fragment: InlineFragment(computed: root.fragment.computed),
        firstLine: true
      )
      let w = fitContent(ictx.space.w)
      let h = ictx.space.h
      ictx.addInlineBlock(state, BlockBoxBuilder(child), w, h)
      root.fragment.children.add(state.fragment)
    else:
      assert false, "child.t is " & $child.computed{"display"}
  if ictx.firstTextFragment != nil:
    root.fragment.startOffset = ictx.firstTextFragment.startOffset
  if ictx.lastTextFragment != nil:
    root.fragment.endOffset = ictx.lastTextFragment.endOffset
  root.fragment.size = ictx.size
  let lastFragment = if ictx.lastTextFragment != nil:
    ictx.lastTextFragment
  else:
    InlineFragment(computed: computed)
  var state = InlineState(computed: computed, fragment: lastFragment)
  ictx.finish(state)
  root.xminwidth = ictx.minwidth
  ictx.positionAtoms()
  return root

proc buildMarker(builder: MarkerBoxBuilder, space: AvailableSpace,
    lctx: LayoutState): RootInlineFragment =
  let space = AvailableSpace(
    w: fitContent(space.w),
    h: space.h
  )
  #TODO we should put markers right before the first atom of the parent
  # list item or something...
  var bctx = BlockContext(lctx: lctx)
  let children = @[BoxBuilder(builder)]
  return bctx.layoutRootInline(children, space, builder.computed, Offset(),
    Offset())

# Build a block box without establishing a new block formatting context.
proc buildBlock(bctx: var BlockContext, builder: BlockBoxBuilder,
    space: AvailableSpace, offset: Offset): BlockBox =
  let lctx = bctx.lctx
  let availableWidth = space.w
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = space.h.toPercSize()
  let sizes = lctx.resolveSizes(availableWidth, availableHeight, percHeight,
    builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    offset: Offset(x: offset.x + sizes.margin.left, y: offset.y),
    margin: sizes.margin
  )
  bctx.layoutFlow(box, builder, sizes)
  return box

proc buildListItem(bctx: var BlockContext, builder: ListItemBoxBuilder,
    space: AvailableSpace, offset: Offset): ListItemBox =
  let availableWidth = stretch(space.w)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = space.h.toPercSize()
  let lctx = bctx.lctx
  let sizes = lctx.resolveSizes(availableWidth, availableHeight, percHeight,
    builder.computed)
  let box = ListItemBox(
    computed: builder.computed,
    node: builder.node,
    offset: Offset(x: offset.x + sizes.margin.left, y: offset.y),
    margin: sizes.margin
  )
  if builder.marker != nil:
    box.marker = buildMarker(builder.marker, sizes.space, lctx)
  bctx.layoutFlow(box, builder.content, sizes)
  return box

proc buildTable(bctx: var BlockContext, builder: TableBoxBuilder,
    space: AvailableSpace, offset: Offset): BlockBox =
  let availableWidth = fitContent(space.w)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = space.h.toPercSize()
  let lctx = bctx.lctx
  let sizes = lctx.resolveSizes(availableWidth, availableHeight, percHeight,
    builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    offset: Offset(x: offset.x + sizes.margin.left, y: offset.y),
    margin: sizes.margin
  )
  let isBfc = builder.computed.establishesBFC()
  if not isBfc:
    bctx.marginTodo.append(sizes.margin.top)
  bctx.flushMargins(box)
  lctx.layoutTable(box, builder, sizes)
  if not isBfc:
    bctx.marginTodo.append(sizes.margin.bottom)
  return box

proc positionAbsolute(lctx: LayoutState, box: BlockBox, margin: RelativeRect) =
  let last = lctx.positioned[^1]
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let parentWidth = applySizeConstraint(lctx.attrs.width_px, last.w)
  let parentHeight = applySizeConstraint(lctx.attrs.height_px, last.h)
  if not left.auto:
    box.offset.x = left.px(lctx, parentWidth)
    box.offset.x += margin.left
  elif not right.auto:
    box.offset.x = parentWidth - right.px(lctx, parentWidth) - box.size.w
    box.offset.x -= margin.right
  if not top.auto:
    box.offset.y = top.px(lctx, parentHeight)
    box.offset.y += margin.top
  elif not bottom.auto:
    box.offset.y = parentHeight - bottom.px(lctx, parentHeight) - box.size.h
    box.offset.y -= margin.bottom

proc positionRelative(parent, box: BlockBox, lctx: LayoutState) =
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  if not left.auto:
    box.offset.x += right.px(lctx)
  elif not right.auto:
    box.offset.x += parent.size.w - right.px(lctx) - box.size.w
  if not top.auto:
    box.offset.y += top.px(lctx)
  elif not top.auto:
    box.offset.y -= parent.size.h - bottom.px(lctx) - box.size.h

type
  CellWrapper = ref object
    builder: TableCellBoxBuilder
    box: BlockBox
    coli: int
    colspan: int
    rowspan: int
    reflow: bool
    grown: int # number of remaining rows
    real: CellWrapper # for filler wrappers
    last: bool # is this the last filler?
    height: LayoutUnit
    baseline: LayoutUnit

  RowContext = object
    cells: seq[CellWrapper]
    reflow: seq[bool]
    width: LayoutUnit
    height: LayoutUnit
    builder: TableRowBoxBuilder
    ncols: int

  ColumnContext = object
    minwidth: LayoutUnit
    width: LayoutUnit
    wspecified: bool
    weight: float64

  TableContext = object
    lctx: LayoutState
    caption: TableCaptionBoxBuilder
    rows: seq[RowContext]
    cols: seq[ColumnContext]
    growing: seq[CellWrapper]
    maxwidth: LayoutUnit
    blockspacing: LayoutUnit
    inlinespacing: LayoutUnit
    collapse: bool
    reflow: seq[bool]

proc buildTableCaption(lctx: LayoutState, builder: TableCaptionBoxBuilder,
    availableWidth, availableHeight: SizeConstraint): BlockBox =
  let percHeight = availableHeight.toperc100()
  let sizes = lctx.resolveSizes(availableWidth, availableHeight, percHeight,
    builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin
  )
  var bctx = BlockContext(lctx: lctx)
  bctx.layoutFlow(box, builder, sizes)
  # Include marginTodo in our own height.
  #TODO this is not quite correct, as height should be the padding height.
  box.size.h += box.offset.y
  box.size.h += bctx.marginTodo.sum()
  return box

proc buildTableCell(lctx: LayoutState, builder: TableCellBoxBuilder,
    availableWidth, availableHeight: SizeConstraint, override: bool):
    BlockBox =
  let sizes = lctx.resolveTableCellSizes(availableWidth, availableHeight,
    override, builder.computed)
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    margin: sizes.margin
  )
  var ctx = BlockContext(lctx: lctx)
  ctx.layoutFlow(box, builder, sizes)
  # Table cells ignore margins.
  box.offset.y = 0
  return box

# Sort growing cells, and filter out cells that have grown to their intended
# rowspan.
proc sortGrowing(pctx: var TableContext) =
  var i = 0
  for j in 0 ..< pctx.growing.len:
    if pctx.growing[i].grown == 0:
      continue
    if j != i:
      pctx.growing[i] = pctx.growing[j]
    inc i
  pctx.growing.setLen(i)
  pctx.growing.sort(proc(a, b: CellWrapper): int =
    cmp(a.coli, b.coli))

# Grow cells with a rowspan > 1 (to occupy their place in a new row).
proc growRowspan(pctx: var TableContext, ctx: var RowContext,
    growi, i, n: var int, growlen: int) =
  while growi < growlen:
    let cellw = pctx.growing[growi]
    if cellw.coli > n:
      break
    dec cellw.grown
    let rowspanFiller = CellWrapper(
      colspan: cellw.colspan,
      rowspan: cellw.rowspan,
      coli: n,
      real: cellw,
      last: cellw.grown == 0
    )
    ctx.cells.add(nil)
    ctx.cells[i] = rowspanFiller
    for i in n ..< n + cellw.colspan:
      ctx.width += pctx.cols[i].width
      ctx.width += pctx.inlinespacing * 2
    n += cellw.colspan
    inc i
    inc growi

proc preBuildTableRow(pctx: var TableContext, box: TableRowBoxBuilder,
    parent: BlockBox, rowi, numrows: int): RowContext =
  var ctx = RowContext(builder: box, cells: newSeq[CellWrapper](box.children.len))
  var n = 0
  var i = 0
  var growi = 0
  # this increases in the loop, but we only want to check growing cells that
  # were added by previous rows.
  let growlen = pctx.growing.len
  for child in box.children:
    pctx.growRowspan(ctx, growi, i, n, growlen)
    assert child.computed{"display"} == DISPLAY_TABLE_CELL
    let cellbuilder = TableCellBoxBuilder(child)
    let colspan = cellbuilder.computed{"-cha-colspan"}
    let rowspan = min(cellbuilder.computed{"-cha-rowspan"}, numrows - rowi)
    let computedWidth = cellbuilder.computed{"width"}
    let cw = if (not computedWidth.auto) and computedWidth.unit != UNIT_PERC:
      stretch(computedWidth.px(pctx.lctx, 0))
    else:
      maxContent()
    #TODO specified table height should be distributed among rows.
    # Allow the table cell to use its specified width.
    let box = pctx.lctx.buildTableCell(cellbuilder, cw, maxContent(),
      override = false)
    let wrapper = CellWrapper(
      box: box,
      builder: cellbuilder,
      colspan: colspan,
      rowspan: rowspan,
      coli: n
    )
    ctx.cells[i] = wrapper
    if rowspan > 1:
      pctx.growing.add(wrapper)
      wrapper.grown = rowspan - 1
    if pctx.cols.len < n + colspan:
      pctx.cols.setLen(n + colspan)
    if ctx.reflow.len < n + colspan:
      ctx.reflow.setLen(n + colspan)
    let minw = box.xminwidth div colspan
    let w = box.size.w div colspan
    for i in n ..< n + colspan:
      # Add spacing.
      ctx.width += pctx.inlinespacing
      # Figure out this cell's effect on the column's width.
      # Four cases exits:
      # 1. colwidth already fixed, cell width is fixed: take maximum
      # 2. colwidth already fixed, cell width is auto: take colwidth
      # 3. colwidth is not fixed, cell width is fixed: take cell width
      # 4. neither of colwidth or cell width are fixed: take maximum
      if ctx.reflow.len <= i: ctx.reflow.setLen(i + 1)
      if pctx.cols[i].wspecified:
        if not computedWidth.auto and computedWidth.unit != UNIT_PERC:
          let ww = computedWidth.px(pctx.lctx)
          # A specified column already exists; we take the larger width.
          if ww > pctx.cols[i].width:
            pctx.cols[i].width = ww
            ctx.reflow[i] = true
        else:
          if pctx.cols[i].width < w:
            wrapper.reflow = true
      else:
        if not computedWidth.auto and computedWidth.unit != UNIT_PERC:
          let ww = computedWidth.px(pctx.lctx)
          # This is the first specified column. Replace colwidth with whatever
          # we have.
          ctx.reflow[i] = true
          pctx.cols[i].wspecified = true
          pctx.cols[i].width = ww
        else:
          if pctx.cols[i].width < w:
            pctx.cols[i].width = w
            ctx.reflow[i] = true
      if not computedWidth.auto and computedWidth.unit != UNIT_PERC:
        let ww = computedWidth.px(pctx.lctx)
        if pctx.cols[i].wspecified:
          # A specified column already exists; we take the larger width.
          if ww > pctx.cols[i].width:
            pctx.cols[i].width = ww
            ctx.reflow[i] = true
        else:
          # This is the first specified column. Replace colwidth with whatever
          # we have.
          pctx.cols[i].wspecified = true
          pctx.cols[i].width = ww
      if pctx.cols[i].minwidth < minw:
        pctx.cols[i].minwidth = minw
        if pctx.cols[i].width < minw:
          pctx.cols[i].width = minw
          ctx.reflow[i] = true
      ctx.width += pctx.cols[i].width
      # Add spacing to the right side.
      ctx.width += pctx.inlinespacing
    n += colspan
    inc i
  pctx.growRowspan(ctx, growi, i, n, growlen)
  pctx.sortGrowing()
  for i in 0 ..< ctx.cells.len:
    doAssert ctx.cells[i] != nil, $i
  ctx.ncols = n
  return ctx

proc alignTableCell(cell: BlockBox, availableHeight, baseline: LayoutUnit) =
  case cell.computed{"vertical-align"}.keyword
  of VERTICAL_ALIGN_TOP:
    cell.offset.y = 0
  of VERTICAL_ALIGN_MIDDLE:
    cell.offset.y = availableHeight div 2 - cell.size.h div 2
  of VERTICAL_ALIGN_BOTTOM:
    cell.offset.y = availableHeight - cell.size.h
  else:
    cell.offset.y = baseline - cell.firstBaseline

proc buildTableRow(pctx: TableContext, ctx: RowContext, parent: BlockBox,
    builder: TableRowBoxBuilder, sizes: ResolvedSizes): BlockBox =
  var x: LayoutUnit = 0
  var n = 0
  let row = BlockBox(
    computed: builder.computed,
    node: builder.node
  )
  var baseline: LayoutUnit = 0
  # real cellwrappers of fillers
  var to_align: seq[CellWrapper]
  # cells with rowspan > 1 that must store baseline
  var to_baseline: seq[CellWrapper]
  # cells that we must update row height of
  var to_height: seq[CellWrapper]
  for cellw in ctx.cells:
    var w: LayoutUnit = 0
    for i in n ..< n + cellw.colspan:
      w += pctx.cols[i].width
    # Add inline spacing for merged columns.
    w += pctx.inlinespacing * (cellw.colspan - 1) * 2
    if cellw.reflow and cellw.builder != nil:
      # Do not allow the table cell to make use of its specified width.
      # e.g. in the following table
      # <TABLE>
      # <TR>
      # <TD style="width: 5ch" bgcolor=blue>5ch</TD>
      # </TR>
      # <TR>
      # <TD style="width: 9ch" bgcolor=red>9ch</TD>
      # </TR>
      # </TABLE>
      # the TD with a width of 5ch should be 9ch wide as well.
      cellw.box = pctx.lctx.buildTableCell(cellw.builder, stretch(w),
        maxContent(), override = true)
      w = max(w, cellw.box.size.w)
    let cell = cellw.box
    x += pctx.inlinespacing
    if cell != nil:
      cell.offset.x += x
    x += pctx.inlinespacing
    x += w
    n += cellw.colspan
    const HasNoBaseline = {
      VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_MIDDLE, VERTICAL_ALIGN_BOTTOM
    }
    if cell != nil:
      if cell.computed{"vertical-align"}.keyword notin HasNoBaseline: # baseline
        baseline = max(cell.firstBaseline, baseline)
        if cellw.rowspan > 1:
          to_baseline.add(cellw)
      row.nested.add(cell)
      if cellw.rowspan > 1:
        to_height.add(cellw)
      row.size.h = max(row.size.h, cell.size.h div cellw.rowspan)
    else:
      let real = cellw.real
      row.size.h = max(row.size.h, real.box.size.h div cellw.rowspan)
      to_height.add(real)
      if cellw.last:
        to_align.add(real)
  for cellw in to_height:
    cellw.height += row.size.h
  for cellw in to_baseline:
    cellw.baseline = baseline
  for cellw in to_align:
    alignTableCell(cellw.box, cellw.height, cellw.baseline)
  for cell in row.nested:
    alignTableCell(cell, row.size.h, baseline)
  row.size.w = x
  return row

proc preBuildTableRows(ctx: var TableContext, rows: seq[TableRowBoxBuilder],
    table: BlockBox) =
  for i in 0 ..< rows.len:
    let row = rows[i]
    let rctx = ctx.preBuildTableRow(row, table, i, rows.len)
    ctx.rows.add(rctx)
    ctx.maxwidth = max(rctx.width, ctx.maxwidth)

proc preBuildTableRows(ctx: var TableContext, builder: TableBoxBuilder,
    table: BlockBox) =
  # Use separate seqs for different row groups, so that e.g. this HTML:
  # echo '<TABLE><TBODY><TR><TD>world<THEAD><TR><TD>hello'|cha -T text/html
  # is rendered as:
  # hello
  # world
  var thead: seq[TableRowBoxBuilder]
  var tbody: seq[TableRowBoxBuilder]
  var tfoot: seq[TableRowBoxBuilder]
  var caption: TableCaptionBoxBuilder
  for child in builder.children:
    assert child.computed{"display"} in ProperTableChild
    case child.computed{"display"}
    of DISPLAY_TABLE_ROW:
      tbody.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_HEADER_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        thead.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_ROW_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        tbody.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_FOOTER_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        tfoot.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_CAPTION:
      if caption == nil:
        caption = TableCaptionBoxBuilder(child)
    else: discard
  if caption != nil:
    ctx.caption = caption
  ctx.preBuildTableRows(thead, table)
  ctx.preBuildTableRows(tbody, table)
  ctx.preBuildTableRows(tfoot, table)

proc calcUnspecifiedColIndices(ctx: var TableContext, W: var LayoutUnit,
    weight: var float64): seq[int] =
  # Spacing for each column:
  var avail = newSeqUninitialized[int](ctx.cols.len)
  var i = 0
  var j = 0
  while i < ctx.cols.len:
    if not ctx.cols[i].wspecified:
      avail[j] = i
      let colw = ctx.cols[i].width
      let w = if colw < W:
        toFloat64(colw)
      else:
        toFloat64(W) * (ln(toFloat64(colw) / toFloat64(W)) + 1)
      ctx.cols[i].weight = w
      weight += w
      inc j
    else:
      W -= ctx.cols[i].width
      avail.del(j)
    inc i
  return avail

func needsRedistribution(ctx: TableContext, computed: CSSComputedValues,
    sizes: ResolvedSizes): bool =
  case sizes.space.w.t
  of MIN_CONTENT, MAX_CONTENT:
    # bleh
    return false
  of STRETCH:
    let u = sizes.space.w.u
    return u > ctx.maxwidth or u < ctx.maxwidth
  of FIT_CONTENT:
    let u = sizes.space.w.u
    return u > ctx.maxwidth and not computed{"width"}.auto or u < ctx.maxwidth

proc redistributeWidth(ctx: var TableContext, sizes: ResolvedSizes) =
  var W = sizes.space.w.u
  # Remove inline spacing from distributable width.
  W -= ctx.cols.len * ctx.inlinespacing * 2
  var weight: float64
  var avail = ctx.calcUnspecifiedColIndices(W, weight)
  var redo = true
  while redo and avail.len > 0 and weight != 0:
    if weight == 0: break # zero weight; nothing to distribute
    if W < 0:
      W = 0
    redo = false
    # divide delta width by sum of sqrt(width) for all elem in avail
    let unit = toFloat64(W) / weight
    weight = 0
    for i in countdown(avail.high, 0):
      let j = avail[i]
      let x = unit * ctx.cols[j].weight
      let mw = ctx.cols[j].minwidth
      ctx.cols[j].width = x
      if mw > x:
        W -= mw
        ctx.cols[j].width = mw
        avail.del(i)
        redo = true
      else:
        weight += ctx.cols[j].weight
      ctx.reflow[j] = true

proc reflowTableCells(ctx: var TableContext) =
  for i in countdown(ctx.rows.high, 0):
    var row = addr ctx.rows[i]
    var n = ctx.cols.len - 1
    for j in countdown(row.cells.high, 0):
      let m = n - row.cells[j].colspan
      while n > m:
        if ctx.reflow[n]:
          row.cells[j].reflow = true
        if n < row.reflow.len and row.reflow[n]:
          ctx.reflow[n] = true
        dec n

proc buildTableRows(ctx: TableContext, table: BlockBox, sizes: ResolvedSizes) =
  var y: LayoutUnit = 0
  for roww in ctx.rows:
    if roww.builder.computed{"visibility"} == VISIBILITY_COLLAPSE:
      continue
    y += ctx.blockspacing
    let row = ctx.buildTableRow(roww, table, roww.builder, sizes)
    row.offset.y += y
    row.offset.x += sizes.padding.left
    row.size.w += sizes.padding.left
    row.size.w += sizes.padding.right
    y += ctx.blockspacing
    y += row.size.h
    table.nested.add(row)
    table.size.w = max(row.size.w, table.size.w)
  table.size.h = applySizeConstraint(y, sizes.space.h)

proc addTableCaption(ctx: TableContext, table: BlockBox,
    sizes: ResolvedSizes) =
  let lctx = ctx.lctx
  case ctx.caption.computed{"caption-side"}
  of CAPTION_SIDE_TOP, CAPTION_SIDE_BLOCK_START:
    let caption = lctx.buildTableCaption(ctx.caption, stretch(table.size.w),
      maxContent())
    for r in table.nested:
      r.offset.y += caption.size.h
    table.nested.insert(caption, 0)
    table.size.h += caption.size.h
    table.size.w = max(table.size.w, caption.size.w)
  of CAPTION_SIDE_BOTTOM, CAPTION_SIDE_BLOCK_END:
    let caption = lctx.buildTableCaption(ctx.caption, stretch(table.size.w),
      maxContent())
    caption.offset.y += table.size.w
    table.nested.add(caption)
    table.size.h += caption.size.h
    table.size.w = max(table.size.w, caption.size.w)
  of CAPTION_SIDE_LEFT, CAPTION_SIDE_INLINE_START:
    let caption = lctx.buildTableCaption(ctx.caption,
      fitContent(sizes.space.w), fitContent(table.size.h))
    for r in table.nested:
      r.offset.x += caption.size.w
    table.nested.insert(caption, 0)
    table.size.w += caption.size.w
    table.size.h = max(table.size.h, caption.size.h)
  of CAPTION_SIDE_RIGHT, CAPTION_SIDE_INLINE_END:
    let caption = lctx.buildTableCaption(ctx.caption,
      fitContent(sizes.space.w), fitContent(table.size.h))
    caption.offset.x += table.size.w
    table.nested.add(caption)
    table.size.w += caption.size.w
    table.size.h = max(table.size.h, caption.size.h)

# Table layout. We try to emulate w3m's behavior here:
# 1. Calculate minimum and preferred width of each column
# 2. If column width is not auto, set width to max(min_col_width, specified)
# 3. Calculate the maximum preferred row width. If this is
# a) less than the specified table width, or
# b) greater than the table's content width:
#      Distribute the table's content width among cells with an unspecified
#      width. If this would give any cell a width < min_width, set that
#      cell's width to min_width, then re-do the distribution.
proc layoutTable(lctx: LayoutState, table: BlockBox, builder: TableBoxBuilder,
    sizes: ResolvedSizes) =
  let collapse = table.computed{"border-collapse"} == BORDER_COLLAPSE_COLLAPSE
  var ctx = TableContext(lctx: lctx, collapse: collapse)
  if not ctx.collapse:
    ctx.inlinespacing = table.computed{"border-spacing"}.a.px(lctx)
    ctx.blockspacing = table.computed{"border-spacing"}.b.px(lctx)
  ctx.preBuildTableRows(builder, table)
  ctx.reflow = newSeq[bool](ctx.cols.len)
  if ctx.needsRedistribution(table.computed, sizes):
    ctx.redistributeWidth(sizes)
  for col in ctx.cols:
    table.size.w += col.width
  ctx.reflowTableCells()
  ctx.buildTableRows(table, sizes)
  if ctx.caption != nil:
    ctx.addTableCaption(table, sizes)

proc postAlignChild(box, child: BlockBox, width: LayoutUnit) =
  case box.computed{"text-align"}
  of TEXT_ALIGN_CHA_CENTER:
    child.offset.x += max(width div 2 - child.size.w div 2, 0)
  of TEXT_ALIGN_CHA_RIGHT:
    child.offset.x += max(width - child.size.w - child.margin.right, 0)
  of TEXT_ALIGN_CHA_LEFT:
    discard # default
  else:
    discard

# Build an outer block box inside an existing block formatting context.
proc layoutBlockChild(bctx: var BlockContext, builder: BoxBuilder,
    space: AvailableSpace, offset: Offset): BlockBox =
  let child = case builder.computed{"display"}
  of DISPLAY_BLOCK, DISPLAY_FLOW_ROOT:
    bctx.buildBlock(BlockBoxBuilder(builder), space, offset)
  of DISPLAY_LIST_ITEM:
    bctx.buildListItem(ListItemBoxBuilder(builder), space, offset)
  of DISPLAY_TABLE:
    bctx.buildTable(TableBoxBuilder(builder), space, offset)
  else:
    assert false, "builder.t is " & $builder.computed{"display"}
    BlockBox(nil)
  return child

# Establish a new block formatting context and build a block box.
proc layoutRootBlock(lctx: LayoutState, builder: BoxBuilder,
    space: AvailableSpace, offset: Offset, marginBottomOut: var LayoutUnit):
    BlockBox =
  var bctx = BlockContext(lctx: lctx)
  let box = case builder.computed{"display"}
  of DISPLAY_BLOCK, DISPLAY_FLOW_ROOT:
    bctx.buildBlock(BlockBoxBuilder(builder), space, offset)
  of DISPLAY_LIST_ITEM:
    bctx.buildListItem(ListItemBoxBuilder(builder), space, offset)
  of DISPLAY_TABLE:
    bctx.buildTable(TableBoxBuilder(builder), space, offset)
  else:
    assert false, "builder.t is " & $builder.computed{"display"}
    BlockBox(nil)
  bctx.positionFloats()
  marginBottomOut = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.offset.y + box.size.h + marginBottomOut:
    box.size.h = bctx.maxFloatHeight - box.offset.y - marginBottomOut
  return box

proc initBlockPositionStates(state: var BlockState, bctx: var BlockContext,
    box: BlockBox) =
  let prevBps = bctx.ancestorsHead
  bctx.ancestorsHead = BlockPositionState(
    box: box,
    offset: Offset(
      x: state.offset.x,
      y: state.offset.y
    ),
    resolved: bctx.parentBps == nil
  )
  if prevBps != nil:
    prevBps.next = bctx.ancestorsHead
  if bctx.parentBps != nil:
    bctx.ancestorsHead.offset.x += bctx.parentBps.offset.x
    bctx.ancestorsHead.offset.y += bctx.parentBps.offset.y
    # If parentBps is not nil, then our starting position is not in a new
    # BFC -> we must add it to our BFC offset.
    bctx.ancestorsHead.offset.x += box.offset.x
    bctx.ancestorsHead.offset.y += box.offset.y
  if bctx.marginTarget == nil:
    bctx.marginTarget = bctx.ancestorsHead
  state.initialMarginTarget = bctx.marginTarget
  state.initialTargetOffset = bctx.marginTarget.offset
  if bctx.parentBps == nil:
    # We have just established a new BFC. Resolve the margins instantly.
    bctx.marginTarget = nil
  state.prevParentBps = bctx.parentBps
  bctx.parentBps = bctx.ancestorsHead
  state.initialParentOffset = bctx.parentBps.offset

func isParentResolved(state: BlockState, bctx: BlockContext): bool =
  return bctx.marginTarget != state.initialMarginTarget or
    state.prevParentBps != nil and state.prevParentBps.resolved

# Layout and place all children in the block box.
# Box placement must occur during this pass, since child box layout in the
# same block formatting context depends on knowing where the box offset is
# (because of floats).
proc layoutBlockChildren(state: var BlockState, bctx: var BlockContext,
    children: seq[BoxBuilder]) =
  for builder in children:
    var dy: LayoutUnit = 0 # delta
    var child: BlockBox
    let isfloat = builder.computed{"float"} != FLOAT_NONE
    let isinflow = builder.computed{"position"} notin {POSITION_ABSOLUTE,
      POSITION_FIXED} and not isfloat
    if builder.computed.establishesBFC():
      var marginBottomOut: LayoutUnit
      child = bctx.lctx.layoutRootBlock(builder, state.space, state.offset,
        marginBottomOut)
      # Do not collapse margins of elements that do not participate in
      # the flow.
      if isinflow:
        bctx.marginTodo.append(child.margin.top)
        bctx.flushMargins(child)
        bctx.positionFloats()
        bctx.marginTodo.append(child.margin.bottom)
      else:
        child.offset.y += child.margin.top
        if state.isParentResolved(bctx):
          # If parent offset has been resolved, use marginTodo in this
          # float's initial offset.
          child.offset.y += bctx.marginTodo.sum()
      # delta y is difference between old and new offsets (margin-top), sum
      # of margin todo in bctx2 (margin-bottom) + height.
      dy = child.offset.y - state.offset.y + child.size.h + marginBottomOut
    else:
      child = bctx.layoutBlockChild(builder, state.space, state.offset)
      # delta y is difference between old and new offsets (margin-top),
      # plus height.
      dy = child.offset.y - state.offset.y + child.size.h
    let childWidth = child.margin.left + child.size.w + child.margin.right
    state.maxChildWidth = max(state.maxChildWidth, childWidth)
    state.xminwidth = max(state.xminwidth, child.xminwidth)
    if child.computed{"position"} notin {POSITION_ABSOLUTE, POSITION_FIXED} and
        not isfloat:
      # Not absolute, and not a float.
      state.offset.y += dy
    elif isfloat:
      if state.space.w.t == FIT_CONTENT:
        # Float position depends on the available width, but in this case
        # the parent width is not known.
        # Set the "re-layout" flag, and skip this box.
        # (If child boxes with fit-content have floats, those will be
        # re-layouted too first, so we do not have to consider those here.)
        state.needsReLayout = true
        continue
      # Two cases exist:
      # a) The float cannot be positioned, because `box' has not resolved
      #    its y offset yet. (e.g. if float comes before the first child,
      #    we do not know yet if said child will move our y offset with a
      #    margin-top value larger than ours.)
      #    In this case we put it in unpositionedFloats, and defer positioning
      #    until our y offset is resolved.
      # b) `box' has resolved its y offset, so the float can already
      #    be positioned.
      # We check whether our y offset has been positioned as follows:
      # * save marginTarget in BlockState at layoutBlock's start
      # * if our saved marginTarget and bctx's marginTarget no longer point
      #   to the same object, that means our (or an ancestor's) offset has
      #   been resolved, i.e. we can position floats already.
      if bctx.marginTarget != state.initialMarginTarget:
        # y offset resolved
        bctx.positionFloat(child, state.space, bctx.parentBps.offset)
      else:
        bctx.unpositionedFloats.add(UnpositionedFloat(
          space: state.space,
          parentBps: bctx.parentBps,
          box: child
        ))
    state.nested.add(child)

# Unlucky path, where we have floating blocks and a fit-content width.
# Reset marginTodo & the starting offset, and stretch the box to the
# max child width.
proc initReLayout(state: var BlockState, bctx: var BlockContext,
    box: BlockBox, sizes: ResolvedSizes) =
  bctx.marginTodo = state.oldMarginTodo
  # Note: we do not reset our own BlockPositionState's offset; we assume it
  # has already been resolved in the previous pass.
  # (If not, it won't be resolved in this pass either, so the following code
  # does not really change anything.)
  bctx.parentBps.next = nil
  if state.initialMarginTarget != bctx.marginTarget:
    # Reset the initial margin target to its previous state, and then set
    # it as the marginTarget again.
    # Two solutions exist:
    # a) Store the initial margin target offset, then restore it here. Seems
    #    clean, but it would require a linked list traversal to update all
    #    child margin positions.
    # b) Re-use the previous margin target offsets; they are guaranteed
    #    to remain the same, because out-of-flow elements (like floats) do not
    #    participate in margin resolution. We do this by setting the margin
    #    target to a dummy object, which is a small price to pay compared
    #    to solution a).
    bctx.marginTarget = BlockPositionState(
      # Use initialTargetOffset to emulate the BFC positioning of the
      # previous pass.
      offset: state.initialTargetOffset
    )
    # Set ancestorsHead to a dummy object. Rationale: see below.
    # Also set ancestorsHead as the dummy object, so next elements are
    # chained to that.
    bctx.ancestorsHead = bctx.marginTarget
  state.nested.setLen(0)
  bctx.exclusions.setLen(state.oldExclusionsLen)
  state.offset = Offset(x: sizes.padding.left, y: sizes.padding.top)
  box.applyWidth(sizes, state.maxChildWidth)
  state.space.w = stretch(box.size.w)

# Re-position the children.
# The x offset with a fit-content width depends on the parent box's width,
# so we cannot do this in the first pass.
proc repositionChildren(state: BlockState, box: BlockBox, lctx: LayoutState) =
  for child in state.nested:
    if child.computed{"position"} != POSITION_ABSOLUTE:
      box.postAlignChild(child, box.size.w)
    case child.computed{"position"}
    of POSITION_RELATIVE:
      box.positionRelative(child, lctx)
    of POSITION_ABSOLUTE:
      lctx.positionAbsolute(child, child.margin)
    else: discard #TODO

proc layoutBlock(bctx: var BlockContext, box: BlockBox,
    builder: BlockBoxBuilder, sizes: ResolvedSizes) =
  let lctx = bctx.lctx
  let positioned = box.computed{"position"} != POSITION_STATIC
  if positioned:
    lctx.positioned.add(sizes.space)
  var state = BlockState(
    offset: Offset(x: sizes.padding.left, y: sizes.padding.top),
    space: sizes.space,
    oldMarginTodo: bctx.marginTodo,
    oldExclusionsLen: bctx.exclusions.len
  )
  state.initBlockPositionStates(bctx, box)
  state.layoutBlockChildren(bctx, builder.children)
  if state.needsReLayout:
    state.initReLayout(bctx, box, sizes)
    state.layoutBlockChildren(bctx, builder.children)
  if state.nested.len > 0:
    let lastNested = state.nested[^1]
    box.baseline = lastNested.offset.y + lastNested.baseline
  # Apply width then move the inline offset of children that still need
  # further relative positioning.
  box.applyWidth(sizes, state.maxChildWidth)
  state.repositionChildren(box, lctx)
  # Set the inner height to the last y offset minus the starting offset
  # (that is, top padding).
  let innerHeight = state.offset.y - sizes.padding.top
  box.applyHeight(sizes, innerHeight)
  # Add padding; we cannot do this further up without influencing positioning.
  box.applyPadding(sizes.padding)
  # Pass down relevant data from state.
  box.nested = state.nested
  box.xminwidth = state.xminwidth
  if state.isParentResolved(bctx):
    # Our offset has already been resolved, ergo any margins in marginTodo will
    # be passed onto the next box. Set marginTarget to nil, so that if we
    # (or one of our ancestors) was still set as a marginTarget, it no
    # longer is.
    bctx.positionFloats()
    bctx.marginTarget = nil
  # Reset parentBps to the previous node.
  bctx.parentBps = state.prevParentBps
  if positioned:
    lctx.positioned.setLen(lctx.positioned.len - 1)

# Tree generation (1st pass)

proc newMarkerBox(computed: CSSComputedValues, listItemCounter: int):
    MarkerBoxBuilder =
  let computed = computed.inheritProperties()
  computed{"display"} = DISPLAY_INLINE
  # Use pre, so the space at the end of the default markers isn't ignored.
  computed{"white-space"} = WHITESPACE_PRE
  return MarkerBoxBuilder(
    computed: computed,
    text: @[computed{"list-style-type"}.listMarker(listItemCounter)]
  )

type BlockGroup = object
  parent: BlockBoxBuilder
  boxes: seq[BoxBuilder]

type InnerBlockContext = object
  styledNode: StyledNode
  blockgroup: BlockGroup
  lctx: LayoutState
  ibox: InlineBoxBuilder
  iroot: InlineBoxBuilder
  anonRow: TableRowBoxBuilder
  anonTable: TableBoxBuilder
  quoteLevel: int
  listItemCounter: int
  listItemReset: bool
  parent: ptr InnerBlockContext
  inlineStack: seq[StyledNode]

proc add(blockgroup: var BlockGroup, box: BoxBuilder) {.inline.} =
  assert box.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_TABLE,
    DISPLAY_INLINE_BLOCK}, $box.computed{"display"}
  blockgroup.boxes.add(box)

proc flush(blockgroup: var BlockGroup) {.inline.} =
  if blockgroup.boxes.len > 0:
    assert blockgroup.parent.computed{"display"} != DISPLAY_INLINE
    let computed = blockgroup.parent.computed.inheritProperties()
    computed{"display"} = DISPLAY_BLOCK
    let bbox = BlockBoxBuilder(computed: computed)
    bbox.inlinelayout = true
    bbox.children = blockgroup.boxes
    blockgroup.parent.children.add(bbox)
    blockgroup.boxes.setLen(0)

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: BlockGroup,
    computed: CSSComputedValues, str: string): bool =
  return blockgroup.boxes.len > 0 and
      blockgroup.boxes[^1].computed{"display"} == DISPLAY_INLINE or
    computed.whitespacepre or not str.onlyWhitespace()

proc newBlockGroup(parent: BlockBoxBuilder): BlockGroup =
  assert parent.computed{"display"} != DISPLAY_INLINE
  result.parent = parent

proc generateTableBox(styledNode: StyledNode, lctx: LayoutState,
  parent: var InnerBlockContext): TableBoxBuilder
proc generateTableRowGroupBox(styledNode: StyledNode, lctx: LayoutState,
  parent: var InnerBlockContext): TableRowGroupBoxBuilder
proc generateTableRowBox(styledNode: StyledNode, lctx: LayoutState,
  parent: var InnerBlockContext): TableRowBoxBuilder
proc generateTableCellBox(styledNode: StyledNode, lctx: LayoutState,
  parent: var InnerBlockContext): TableCellBoxBuilder
proc generateTableCaptionBox(styledNode: StyledNode, lctx: LayoutState,
  parent: var InnerBlockContext): TableCaptionBoxBuilder
proc generateBlockBox(styledNode: StyledNode, lctx: LayoutState,
  marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil):
  BlockBoxBuilder
proc generateInlineBoxes(ctx: var InnerBlockContext, styledNode: StyledNode)

proc generateBlockBox(pctx: var InnerBlockContext, styledNode: StyledNode,
    marker = none(MarkerBoxBuilder)): BlockBoxBuilder =
  return generateBlockBox(styledNode, pctx.lctx, marker, addr pctx)

proc flushTableRow(ctx: var InnerBlockContext) =
  if ctx.anonRow != nil:
    if ctx.blockgroup.parent.computed{"display"} == DISPLAY_TABLE_ROW:
      ctx.blockgroup.parent.children.add(ctx.anonRow)
    else:
      if ctx.anonTable == nil:
        var wrappervals = ctx.styledNode.computed.inheritProperties()
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(ctx.anonRow)
    ctx.anonRow = nil

proc flushTable(ctx: var InnerBlockContext) =
  ctx.flushTableRow()
  if ctx.anonTable != nil:
    ctx.blockgroup.parent.children.add(ctx.anonTable)

proc iflush(ctx: var InnerBlockContext) =
  if ctx.iroot != nil:
    assert ctx.iroot.computed{"display"} in {DISPLAY_INLINE,
      DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE}
    ctx.blockgroup.add(ctx.iroot)
    ctx.iroot = nil
    ctx.ibox = nil

proc bflush(ctx: var InnerBlockContext) =
  ctx.iflush()
  ctx.blockgroup.flush()

proc flushInherit(ctx: var InnerBlockContext) =
  if ctx.parent != nil:
    if not ctx.listItemReset:
      ctx.parent.listItemCounter = ctx.listItemCounter
    ctx.parent.quoteLevel = ctx.quoteLevel

proc flush(ctx: var InnerBlockContext) =
  ctx.blockgroup.flush()
  ctx.flushTableRow()
  ctx.flushTable()
  ctx.flushInherit()

proc generateFromElem(ctx: var InnerBlockContext, styledNode: StyledNode) =
  let box = ctx.blockgroup.parent

  case styledNode.computed{"display"}
  of DISPLAY_BLOCK, DISPLAY_FLOW_ROOT:
    ctx.iflush()
    ctx.flush()
    let childbox = ctx.generateBlockBox(styledNode)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    ctx.flush()
    inc ctx.listItemCounter
    let childbox = ListItemBoxBuilder(
      computed: styledNode.computed,
      marker: newMarkerBox(styledNode.computed, ctx.listItemCounter)
    )
    if childbox.computed{"list-style-position"} == LIST_STYLE_POSITION_INSIDE:
      childbox.content = ctx.generateBlockBox(styledNode, some(childbox.marker))
      childbox.marker = nil
    else:
      childbox.content = ctx.generateBlockBox(styledNode)
    childbox.content.computed = childbox.content.computed.copyProperties()
    childbox.content.computed{"display"} = DISPLAY_BLOCK
    box.children.add(childbox)
  of DISPLAY_INLINE:
    ctx.generateInlineBoxes(styledNode)
  of DISPLAY_INLINE_BLOCK:
    ctx.iflush()
    let childbox = ctx.generateBlockBox(styledNode)
    ctx.blockgroup.add(childbox)
  of DISPLAY_TABLE:
    ctx.flush()
    let childbox = styledNode.generateTableBox(ctx.lctx, ctx)
    box.children.add(childbox)
  of DISPLAY_TABLE_ROW:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowBox(ctx.lctx, ctx)
    if box.computed{"display"} in ProperTableRowParent:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP,
      DISPLAY_TABLE_FOOTER_GROUP:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowGroupBox(ctx.lctx, ctx)
    if box.computed{"display"} in {DISPLAY_TABLE, DISPLAY_INLINE_TABLE}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DISPLAY_TABLE_CELL:
    ctx.bflush()
    let childbox = styledNode.generateTableCellBox(ctx.lctx, ctx)
    if box.computed{"display"} == DISPLAY_TABLE_ROW:
      box.children.add(childbox)
    else:
      if ctx.anonRow == nil:
        var wrappervals = box.computed.inheritProperties()
        wrappervals{"display"} = DISPLAY_TABLE_ROW
        ctx.anonRow = TableRowBoxBuilder(computed: wrappervals)
      ctx.anonRow.children.add(childbox)
  of DISPLAY_INLINE_TABLE:
    ctx.iflush()
    let childbox = styledNode.generateTableBox(ctx.lctx, ctx)
    ctx.blockgroup.add(childbox)
  of DISPLAY_TABLE_CAPTION:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableCaptionBox(ctx.lctx, ctx)
    if box.computed{"display"} in {DISPLAY_TABLE, DISPLAY_INLINE_TABLE}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = TableBoxBuilder(computed: wrappervals)
      ctx.anonTable.children.add(childbox)
  of DISPLAY_TABLE_COLUMN:
    discard #TODO
  of DISPLAY_TABLE_COLUMN_GROUP:
    discard #TODO
  of DISPLAY_NONE: discard

proc reconstructInlineParents(ctx: var InnerBlockContext): InlineBoxBuilder =
  let rootNode = ctx.inlineStack[0]
  var parent = InlineBoxBuilder(
    computed: rootNode.computed,
    node: rootNode
  )
  ctx.iroot = parent
  for i in 1 ..< ctx.inlineStack.len:
    let node = ctx.inlineStack[i]
    let nbox = InlineBoxBuilder(computed: node.computed, node: node)
    parent.children.add(nbox)
    parent = nbox
  return parent

proc generateAnonymousInlineText(ctx: var InnerBlockContext, text: string,
    styledNode: StyledNode) =
  if ctx.iroot == nil:
    let computed = styledNode.computed.inheritProperties()
    ctx.ibox = InlineBoxBuilder(computed: computed, node: styledNode)
    if ctx.inlineStack.len > 0:
      let iparent = ctx.reconstructInlineParents()
      iparent.children.add(ctx.ibox)
      ctx.iroot = iparent
    else:
      ctx.iroot = ctx.ibox
  ctx.ibox.text.add(text)

proc generateReplacement(ctx: var InnerBlockContext, child, parent: StyledNode) =
  case child.content.t
  of CONTENT_OPEN_QUOTE:
    let quotes = parent.computed{"quotes"}
    var text: string
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].s
    elif quotes.auto:
      text = quoteStart(ctx.quoteLevel)
    else: return
    ctx.generateAnonymousInlineText(text, parent)
    inc ctx.quoteLevel
  of CONTENT_CLOSE_QUOTE:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
    let quotes = parent.computed{"quotes"}
    var text: string
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].e
    elif quotes.auto:
      text = quoteEnd(ctx.quoteLevel)
    else: return
    ctx.generateAnonymousInlineText(text, parent)
  of CONTENT_NO_OPEN_QUOTE:
    inc ctx.quoteLevel
  of CONTENT_NO_CLOSE_QUOTE:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
  of CONTENT_STRING:
    #TODO canGenerateAnonymousInline?
    ctx.generateAnonymousInlineText(child.content.s, parent)
  of CONTENT_IMAGE:
    #TODO idk
    ctx.generateAnonymousInlineText("[img]", parent)
  of CONTENT_NEWLINE:
    ctx.iflush()
    #TODO ??
    # this used to set ibox (before we had iroot), now I'm not sure if we
    # should reconstruct here first
    ctx.iroot = InlineBoxBuilder(computed: parent.computed.inheritProperties())
    ctx.iroot.newline = true
    ctx.iflush()

proc generateInlineBoxes(ctx: var InnerBlockContext, styledNode: StyledNode) =
  ctx.iflush()
  ctx.inlineStack.add(styledNode)
  var lbox = ctx.reconstructInlineParents()
  lbox.splitType.incl(stSplitStart)
  ctx.ibox = lbox
  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      ctx.generateFromElem(child)
    of STYLED_TEXT:
      if ctx.ibox != lbox:
        ctx.iflush()
        lbox = ctx.reconstructInlineParents()
        ctx.ibox = lbox
      lbox.text.add(child.text)
    of STYLED_REPLACEMENT:
      ctx.generateReplacement(child, styledNode)
  if ctx.ibox != lbox:
    ctx.iflush()
    lbox = ctx.reconstructInlineParents()
    ctx.ibox = lbox
  lbox.splitType.incl(stSplitEnd)
  ctx.inlineStack.setLen(ctx.inlineStack.len - 1)
  ctx.iflush()

proc newInnerBlockContext(styledNode: StyledNode, box: BlockBoxBuilder,
    lctx: LayoutState, parent: ptr InnerBlockContext): InnerBlockContext =
  result = InnerBlockContext(
    styledNode: styledNode,
    blockgroup: newBlockGroup(box),
    lctx: lctx,
    parent: parent
  )
  if parent != nil:
    result.listItemCounter = parent[].listItemCounter
    result.quoteLevel = parent[].quoteLevel
  for reset in styledNode.computed{"counter-reset"}:
    if reset.name == "list-item":
      result.listItemCounter = reset.num
      result.listItemReset = true

proc generateInnerBlockBox(ctx: var InnerBlockContext) =
  let box = ctx.blockgroup.parent
  assert box.computed{"display"} != DISPLAY_INLINE
  for child in ctx.styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      ctx.iflush()
      ctx.generateFromElem(child)
    of STYLED_TEXT:
      if canGenerateAnonymousInline(ctx.blockgroup, box.computed, child.text):
        ctx.generateAnonymousInlineText(child.text, ctx.styledNode)
    of STYLED_REPLACEMENT:
      ctx.generateReplacement(child, ctx.styledNode)
  ctx.iflush()

proc generateBlockBox(styledNode: StyledNode, lctx: LayoutState,
    marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil):
    BlockBoxBuilder =
  let box = BlockBoxBuilder(computed: styledNode.computed)
  box.node = styledNode
  var ctx = newInnerBlockContext(styledNode, box, lctx, parent)

  if marker.isSome:
    ctx.ibox = marker.get
    ctx.iflush()

  ctx.generateInnerBlockBox()

  # Flush anonymous tables here, to avoid setting inline layout with tables.
  ctx.flushTableRow()
  ctx.flushTable()
  # (flush here, because why not)
  ctx.flushInherit()

  # Avoid unnecessary anonymous block boxes. This also helps set our layout to
  # inline even if no inner anonymous block was generated.
  if box.children.len == 0:
    box.children = ctx.blockgroup.boxes
    box.inlinelayout = true
    ctx.blockgroup.boxes.setLen(0)
  ctx.blockgroup.flush()
  return box

proc generateTableCellBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableCellBoxBuilder =
  let box = TableCellBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  return box

proc generateTableRowChildWrappers(box: TableRowBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DISPLAY_TABLE_CELL
  for child in box.children:
    if child.computed{"display"} == DISPLAY_TABLE_CELL:
      newchildren.add(child)
    else:
      let wrapper = TableCellBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableRowBoxBuilder =
  let box = TableRowBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowChildWrappers()
  return box

proc generateTableRowGroupChildWrappers(box: TableRowGroupBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DISPLAY_TABLE_ROW
  for child in box.children:
    if child.computed{"display"} == DISPLAY_TABLE_ROW:
      newchildren.add(child)
    else:
      let wrapper = TableRowBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowGroupBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableRowGroupBoxBuilder =
  let box = TableRowGroupBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowGroupChildWrappers()
  return box

proc generateTableCaptionBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableCaptionBoxBuilder =
  let box = TableCaptionBoxBuilder(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  return box

proc generateTableChildWrappers(box: TableBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals{"display"} = DISPLAY_TABLE_ROW
  for child in box.children:
    if child.computed{"display"} in ProperTableChild:
      newchildren.add(child)
    else:
      let wrapper = TableRowBoxBuilder(computed: wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableBoxBuilder =
  let box = TableBoxBuilder(computed: styledNode.computed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableChildWrappers()
  return box

proc renderLayout*(root: StyledNode, attrs: WindowAttributes): BlockBox =
  let space = AvailableSpace(
    w: stretch(attrs.width_px),
    h: stretch(attrs.height_px)
  )
  let lctx = LayoutState(
    attrs: attrs,
    positioned: @[space]
  )
  let builder = root.generateBlockBox(lctx)
  var marginBottomOut: LayoutUnit
  return lctx.layoutRootBlock(builder, space, Offset(), marginBottomOut)
