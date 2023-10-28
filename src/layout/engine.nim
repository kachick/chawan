import algorithm
import math
import options
import unicode

import css/stylednode
import css/values
import display/winattrs
import layout/box
import layout/layoutunit
import utils/twtstr

type LayoutState = ref object
  attrs: WindowAttributes
  positioned: seq[BlockBox]

# Build phase
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
  LineBoxState = object
    atomstates: seq[InlineAtomState]
    baseline: LayoutUnit
    lineheight: LayoutUnit
    line: LineBox

  InlineAtomState = object
    vertalign: CSSVerticalAlign
    baseline: LayoutUnit
    margin_top: LayoutUnit
    margin_bottom: LayoutUnit

  InlineState = object
    ictx: InlineContext
    skip: bool
    node: StyledNode
    wordstate: InlineAtomState
    word: InlineAtom
    wrappos: int # position of last wrapping opportunity, or -1
    hasshy: bool
    computed: CSSComputedValues
    currentLine: LineBoxState
    charwidth: int
    whitespacenum: int
    format: ComputedFormat
    lctx: LayoutState
    availableWidth: SizeConstraint
    availableHeight: SizeConstraint

func whitespacepre(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP}

func nowrap(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}

func cellwidth(lctx: LayoutState): LayoutUnit =
  lctx.attrs.ppc

func cellwidth(state: InlineState): LayoutUnit =
  state.lctx.cellwidth

func cellheight(lctx: LayoutState): LayoutUnit =
  lctx.attrs.ppl

func cellheight(state: InlineState): LayoutUnit =
  state.lctx.cellheight

template atoms(state: LineBoxState): untyped =
  state.line.atoms

template size(state: LineBoxState): untyped =
  state.line.size

template offsety(state: var LineBoxState): untyped =
  state.line.offsety

# Check if the last atom on the current line is a spacing atom, not counting
# padding atoms.
func hasLastSpacing(currentLine: LineBoxState): bool =
  for i in countdown(currentLine.atoms.high, 0):
    case currentLine.atoms[i].t
    of INLINE_SPACING:
      return true
    of INLINE_PADDING:
      continue # skip padding
    else:
      break
  return false

# Whitespace between words
func computeShift(state: InlineState, computed: CSSComputedValues):
    LayoutUnit =
  if state.whitespacenum > 0:
    if state.currentLine.atoms.len > 0 and
          not state.currentLine.hasLastSpacing() or
        computed.whitespacepre:
      let spacing = computed{"word-spacing"}
      if spacing.auto:
        return state.cellwidth * state.whitespacenum
      return spacing.px(state.lctx) * state.whitespacenum
  return 0

proc applyLineHeight(state: var LineBoxState, lctx: LayoutState,
    computed: CSSComputedValues) =
  #TODO this should be computed during cascading.
  let lineheight = if computed{"line-height"}.auto: # ergo normal
    lctx.cellheight
  else:
    # Percentage: refers to the font size of the element itself.
    computed{"line-height"}.px(lctx, lctx.cellheight)
  state.lineheight = max(lineheight, state.lineheight)

func getComputedFormat(computed: CSSComputedValues, node: StyledNode):
    ComputedFormat =
  return ComputedFormat(
    color: computed{"color"},
    fontstyle: computed{"font-style"},
    fontweight: computed{"font-weight"},
    textdecoration: computed{"text-decoration"},
    bgcolor: computed{"background-color"},
    node: node
  )

proc newWord(state: var InlineState) =
  let wformat = getComputedFormat(state.computed, state.node)
  state.format = wformat
  state.word = InlineAtom(
    t: INLINE_WORD,
    wformat: wformat,
    size: Size(h: state.cellheight)
  )
  state.wordstate = InlineAtomState(
    vertalign: state.computed{"vertical-align"},
    baseline: state.cellheight
  )
  state.wrappos = -1
  state.hasshy = false

proc horizontalAlignLine(state: var InlineState, line: var LineBox,
    computed: CSSComputedValues, last = false) =
  let width = case state.availableWidth.t
  of MIN_CONTENT, MAX_CONTENT:
    state.ictx.width
  of FIT_CONTENT:
    min(state.ictx.width, state.availableWidth.u)
  of STRETCH:
    max(state.ictx.width, state.availableWidth.u)
  # we don't support directions for now so left = start and right = end
  case computed{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT, TEXT_ALIGN_CHA_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CHA_RIGHT:
    # move everything
    let x = max(width, line.size.w) - line.size.w
    for atom in line.atoms.mitems:
      atom.offset.x += x
      state.ictx.width = max(atom.offset.x + atom.size.w, state.ictx.width)
  of TEXT_ALIGN_CENTER, TEXT_ALIGN_CHA_CENTER:
    # NOTE if we need line x offsets, use:
    #let width = width - line.offset.x
    let x = max((max(width, line.size.w)) div 2 - line.size.w div 2, 0)
    for atom in line.atoms.mitems:
      atom.offset.x += x
      state.ictx.width = max(atom.offset.x + atom.size.w, state.ictx.width)
  of TEXT_ALIGN_JUSTIFY:
    if not computed.whitespacepre and not last:
      var sumwidth: LayoutUnit = 0
      var spaces = 0
      for atom in line.atoms.mitems:
        if atom.t in {INLINE_SPACING, INLINE_PADDING}:
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
  state.ictx.width = max(width, state.ictx.width) #TODO this seems meaningless?

# Align atoms (inline boxes, text, etc.) vertically (i.e. along the inline
# axis) inside the line.
proc verticalAlignLine(state: var InlineState) =
  # Start with line-height as the baseline and line height.
  let lineheight = state.currentLine.lineheight
  state.currentLine.size.h = lineheight
  var baseline = lineheight

  # Calculate the line's baseline based on atoms' baseline.
  # Also, collect the maximum vertical margins of inline blocks.
  var margin_top: LayoutUnit = 0
  var margin_bottom: LayoutUnit = 0
  for i in 0 ..< state.currentLine.atoms.len:
    let atom = state.currentLine.atoms[i]
    let iastate = state.currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      let len = iastate.vertalign.length.px(state.lctx, lineheight)
      baseline = max(baseline, iastate.baseline + len)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      baseline = max(baseline, atom.size.h)
    of VERTICAL_ALIGN_MIDDLE:
      baseline = max(baseline, atom.size.h div 2)
    else:
      baseline = max(baseline, iastate.baseline)
    margin_top = max(iastate.margin_top, margin_top)
    margin_bottom = max(iastate.margin_bottom, margin_bottom)

  # Resize the line's height based on atoms' height and baseline.
  # The line height should be at least as high as the highest baseline used by
  # an atom plus that atom's height.
  for i in 0 ..< state.currentLine.atoms.len:
    let atom = state.currentLine.atoms[i]
    let iastate = state.currentLine.atomstates[i]
    # In all cases, the line's height must at least equal the atom's height.
    # (Where the atom is actually placed is irrelevant here.)
    state.currentLine.size.h = max(state.currentLine.size.h, atom.size.h)
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Line height must be at least as high as
      # (line baseline) - (atom baseline) + (atom height) + (extra height).
      let len = iastate.vertalign.length.px(state.lctx, lineheight)
      state.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h + len, state.currentLine.size.h)
    of VERTICAL_ALIGN_MIDDLE:
      # Line height must be at least
      # (line baseline) + (atom height / 2).
      state.currentLine.size.h = max(baseline + atom.size.h div 2,
        state.currentLine.size.h)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      # Line height must be at least atom height (already ensured above.)
      discard
    else:
      # See baseline (with len = 0).
      state.currentLine.size.h = max(baseline - iastate.baseline +
        atom.size.h, state.currentLine.size.h)

  # Now we can calculate the actual position of atoms inside the line.
  for i in 0 ..< state.currentLine.atoms.len:
    let iastate = state.currentLine.atomstates[i]
    let atom = addr state.currentLine.atoms[i]
    case iastate.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Atom is placed at (line baseline) - (atom baseline) - len
      let len = iastate.vertalign.length.px(state.lctx, lineheight)
      atom.offset.y = baseline - iastate.baseline - len
    of VERTICAL_ALIGN_MIDDLE:
      # Atom is placed at (line baseline) - ((atom height) / 2)
      atom.offset.y = baseline - atom.size.h div 2
    of VERTICAL_ALIGN_TOP:
      # Atom is placed at the top of the line.
      atom.offset.y = 0
    of VERTICAL_ALIGN_BOTTOM:
      # Atom is placed at the bottom of the line.
      atom.offset.y = state.currentLine.size.h - atom.size.h
    else:
      # See baseline (with len = 0).
      atom.offset.y = baseline - iastate.baseline
    # Offset the atom's y position by the largest margin_top value.
    atom.offset.y += margin_top

  # Grow the line by the largest margin_top and margin_bottom, and set
  # its baseline.
  state.currentLine.size.h += margin_top
  state.currentLine.size.h += margin_bottom
  state.currentLine.baseline = baseline

proc addPadding(state: var InlineState, width, height: LayoutUnit,
    format: ComputedFormat) =
  state.currentLine.size.w += width
  let padding = InlineAtom(
    t: INLINE_PADDING,
    size: Size(
      w: width,
      h: height
    ),
    sformat: format,
    offset: Offset(x: state.currentLine.size.w)
  )
  let iastate = InlineAtomState(
    baseline: height
    #TODO vertalign?
  )
  state.currentLine.atomstates.add(iastate)
  state.currentLine.atoms.add(padding)

proc addSpacing(state: var InlineState, width, height: LayoutUnit,
    hang = false) =
  let spacing = InlineAtom(
    t: INLINE_SPACING,
    size: Size(
      w: width,
      h: height
    ),
    sformat: state.format,
    offset: Offset(x: state.currentLine.size.w)
  )
  let iastate = InlineAtomState(
    baseline: height
    #TODO vertalign?
  )
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    state.currentLine.size.w += width
  state.currentLine.atomstates.add(iastate)
  state.currentLine.atoms.add(spacing)

proc flushWhitespace(state: var InlineState, computed: CSSComputedValues,
    hang = false) =
  let shift = state.computeShift(computed)
  state.charwidth += state.whitespacenum
  state.whitespacenum = 0
  if shift > 0:
    state.addSpacing(shift, state.cellheight, hang)

proc finishLine(state: var InlineState, computed: CSSComputedValues,
    force = false) =
  if state.currentLine.atoms.len != 0 or force:
    let whitespace = computed{"white-space"}
    if whitespace == WHITESPACE_PRE:
      state.flushWhitespace(computed)
    elif whitespace == WHITESPACE_PRE_WRAP:
      state.flushWhitespace(computed, hang = true)
    else:
      state.whitespacenum = 0
    state.verticalAlignLine()
    # add line to ictx
    let y = state.currentLine.offsety
    # * set first baseline if this is the first line box
    # * always set last baseline (so the baseline of the last line box remains)
    if state.ictx.lines.len == 0:
      state.ictx.firstBaseline = y + state.currentLine.baseline
    state.ictx.baseline = y + state.currentLine.baseline
    state.ictx.height += state.currentLine.size.h
    state.ictx.width = max(state.ictx.width, state.currentLine.size.w)
    state.ictx.lines.add(state.currentLine.line)
    state.currentLine = LineBoxState(
      line: LineBox(offsety: y + state.currentLine.size.h)
    )
    state.charwidth = 0 #TODO put this in LineBoxState?

proc finish(state: var InlineState, computed: CSSComputedValues) =
  state.finishLine(computed)
  if state.ictx.lines.len > 0:
    for i in 0 ..< state.ictx.lines.len - 1:
      state.horizontalAlignLine(state.ictx.lines[i], computed, last = false)
    state.horizontalAlignLine(state.ictx.lines[^1], computed, last = true)

func minwidth(atom: InlineAtom): LayoutUnit =
  if atom.t == INLINE_BLOCK:
    return atom.innerbox.xminwidth
  return atom.size.w

func shouldWrap(state: InlineState, w: LayoutUnit,
    pcomputed: CSSComputedValues): bool =
  if pcomputed != nil and pcomputed.nowrap:
    return false
  if state.availableWidth.t == MAX_CONTENT:
    return false # no wrap with max-content
  if state.availableWidth.t == MIN_CONTENT:
    return true # always wrap with min-content
  return state.currentLine.size.w + w > state.availableWidth.u

# pcomputed: computed values of parent, for white-space: pre, line-height.
# This isn't necessarily the computed of ictx (e.g. they may differ for nested
# inline boxes.)
# Returns true on newline.
proc addAtom(state: var InlineState, iastate: InlineAtomState,
    atom: InlineAtom, pcomputed: CSSComputedValues): bool =
  result = false
  var shift = state.computeShift(pcomputed)
  state.whitespacenum = 0
  # Line wrapping
  if state.shouldWrap(atom.size.w + shift, pcomputed):
    state.finishLine(pcomputed, false)
    result = true
    # Recompute on newline
    shift = state.computeShift(pcomputed)
  if atom.size.w > 0 and atom.size.h > 0:
    if shift > 0:
      state.addSpacing(shift, state.cellheight)
    state.ictx.minwidth = max(state.ictx.minwidth, atom.minwidth)
    state.currentLine.applyLineHeight(state.lctx, pcomputed)
    if atom.t == INLINE_WORD:
      state.format = atom.wformat
    else:
      state.charwidth = 0
      state.format = nil
    state.currentLine.atoms.add(atom)
    state.currentLine.atomstates.add(iastate)
    state.currentLine.atoms[^1].offset.x += state.currentLine.size.w
    state.currentLine.size.w += atom.size.w

proc addWord(state: var InlineState): bool =
  result = false
  if state.word.str != "":
    state.word.str.mnormalize() #TODO this may break on EOL.
    result = state.addAtom(state.wordstate, state.word, state.computed)
    state.newWord()

proc addWordEOL(state: var InlineState): bool =
  result = false
  if state.word.str != "":
    if state.wrappos != -1:
      let leftstr = state.word.str.substr(state.wrappos)
      state.word.str.setLen(state.wrappos)
      if state.hasshy:
        const shy = $Rune(0xAD) # soft hyphen
        state.word.str &= shy
        state.hasshy = false
      result = state.addWord()
      state.word.str = leftstr
      state.word.size.w = leftstr.width() * state.cellwidth
    else:
      result = state.addWord()

# Start a new line, even if the previous one is empty
proc flushLine(state: var InlineState, computed: CSSComputedValues) =
  state.currentLine.applyLineHeight(state.lctx, computed)
  state.finishLine(computed, true)

proc checkWrap(state: var InlineState, r: Rune) =
  if state.computed.nowrap:
    return
  let shift = state.computeShift(state.computed)
  let rw = r.width()
  case state.computed{"word-break"}
  of WORD_BREAK_NORMAL:
    if rw == 2 or state.wrappos != -1: # break on cjk and wrap opportunities
      let plusWidth = state.word.size.w + shift + rw * state.cellwidth
      if state.shouldWrap(plusWidth, nil):
        if not state.addWordEOL(): # no line wrapping occured in addAtom
          state.finishLine(state.computed)
          state.whitespacenum = 0
  of WORD_BREAK_BREAK_ALL:
    let plusWidth = state.word.size.w + shift + rw * state.cellwidth
    if state.shouldWrap(plusWidth, nil):
      if not state.addWordEOL(): # no line wrapping occured in addAtom
        state.finishLine(state.computed)
        state.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    let plusWidth = state.word.size.w + shift + rw * state.cellwidth
    if state.shouldWrap(plusWidth, nil):
      state.finishLine(state.computed)
      state.whitespacenum = 0

proc processWhitespace(state: var InlineState, c: char) =
  discard state.addWord()
  case state.computed{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    state.whitespacenum = max(state.whitespacenum, 1)
  of WHITESPACE_PRE_LINE:
    if c == '\n':
      state.flushLine(state.computed)
    else:
      state.whitespacenum = max(state.whitespacenum, 1)
  of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    #TODO whitespace type should be preserved here. (it isn't, because
    # it would break tabs in the current buffer model.)
    if c == '\n':
      state.flushLine(state.computed)
    elif c == '\t':
      let prev = state.charwidth
      state.charwidth = ((state.charwidth +
        state.whitespacenum) div 8 + 1) * 8 - state.whitespacenum
      state.whitespacenum += state.charwidth - prev
    else:
      inc state.whitespacenum

func newInlineState(lctx: LayoutState,
    availableWidth, availableHeight: SizeConstraint): InlineState =
  return InlineState(
    currentLine: LineBoxState(
      line: LineBox()
    ),
    ictx: InlineContext(),
    lctx: lctx,
    availableWidth: availableWidth,
    availableHeight: availableHeight
  )

proc layoutText(state: var InlineState, str: string,
    computed: CSSComputedValues, node: StyledNode) =
  #TODO the lifetime of these is somewhat confusing, maybe move into some
  # other object?
  state.computed = computed
  state.node = node

  state.flushWhitespace(state.computed)
  state.newWord()

  var i = 0
  while i < str.len:
    if str[i] in AsciiWhitespace:
      state.processWhitespace(str[i])
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      state.checkWrap(r)
      if r == Rune(0xAD): # soft hyphen
        state.wrappos = state.word.str.len
        state.hasshy = true
      else:
        state.word.str &= r
        let w = r.width()
        state.word.size.w += w * state.cellwidth
        state.charwidth += w
        if r == Rune('-'): # ascii dash
          state.wrappos = state.word.str.len
          state.hasshy = false
  discard state.addWord()

func isOuterBlock(computed: CSSComputedValues): bool =
  return computed{"display"} in {DISPLAY_BLOCK, DISPLAY_TABLE}

proc resolveContentWidth(box: BlockBox, widthpx: LayoutUnit,
    containingWidth: SizeConstraint, isauto = false) =
  if not box.computed.isOuterBlock:
    #TODO this is probably needed to avoid double-margin, but it's ugly and
    # probably also broken.
    return
  if box.availableWidth.t notin {STRETCH, FIT_CONTENT}:
    # width is indefinite, so no conflicts can be resolved here.
    return
  let computed = box.computed
  let total = widthpx + box.margin_left + box.margin_right +
    box.padding_left + box.padding_right
  let underflow = containingWidth.u - total
  if isauto or box.availableWidth.t == FIT_CONTENT:
    if underflow >= 0:
      box.availableWidth = SizeConstraint(t: box.availableWidth.t, u: underflow)
    else:
      box.margin_right += underflow
  elif underflow > 0:
    if not computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      box.margin_right += underflow
    elif not computed{"margin-left"}.auto and computed{"margin-right"}.auto:
      box.margin_right = underflow
    elif computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      box.margin_left = underflow
    else:
      box.margin_left = underflow div 2
      box.margin_right = underflow div 2

proc resolveMargins(box: BlockBox, availableWidth: SizeConstraint,
    lctx: LayoutState) =
  let computed = box.computed
  # Note: we use availableWidth for percentage resolution intentionally.
  box.margin_top = computed{"margin-top"}.px(lctx, availableWidth)
  box.margin_bottom = computed{"margin-bottom"}.px(lctx, availableWidth)
  box.margin_left = computed{"margin-left"}.px(lctx, availableWidth)
  box.margin_right = computed{"margin-right"}.px(lctx, availableWidth)

proc resolvePadding(box: BlockBox, availableWidth: SizeConstraint,
    lctx: LayoutState) =
  let computed = box.computed
  # Note: we use availableWidth for percentage resolution intentionally.
  box.padding_top = computed{"padding-top"}.px(lctx, availableWidth)
  box.padding_bottom = computed{"padding-bottom"}.px(lctx, availableWidth)
  box.padding_left = computed{"padding-left"}.px(lctx, availableWidth)
  box.padding_right = computed{"padding-right"}.px(lctx, availableWidth)

proc calcAvailableWidth(box: BlockBox, containingWidth: SizeConstraint,
    lctx: LayoutState) =
  let computed = box.computed
  let width = computed{"width"}
  var widthpx: LayoutUnit = 0
  if not width.auto and width.canpx(containingWidth):
    widthpx = width.px(lctx, containingWidth)
    box.availableWidth = stretch(widthpx)
  box.resolveContentWidth(widthpx, containingWidth, width.auto)
  if not computed{"max-width"}.auto:
    let max_width = computed{"max-width"}.px(lctx, containingWidth)
    box.max_width = some(max_width)
    if box.availableWidth.t in {STRETCH, FIT_CONTENT} and
        max_width < box.availableWidth.u or
        box.availableWidth.t == MAX_CONTENT:
      box.availableWidth = stretch(max_width) #TODO is stretch ok here?
      if box.availableWidth.t == STRETCH:
        # available width would stretch over max-width
        box.availableWidth = stretch(max_width)
      else: # FIT_CONTENT
        # available width could be higher than max-width (but not necessarily)
        box.availableWidth = fitContent(max_width)
      box.resolveContentWidth(max_width, containingWidth)
  if not computed{"min-width"}.auto:
    let min_width = computed{"min-width"}.px(lctx, containingWidth)
    box.min_width = some(min_width)
    if box.availableWidth.t in {STRETCH, FIT_CONTENT} and
        min_width > box.availableWidth.u or
        box.availableWidth.t == MIN_CONTENT:
      # two cases:
      # * available width is stretched under min-width. in this case,
      #   stretch to min-width instead.
      # * available width is fit under min-width. in this case, stretch to
      #   min-width as well (as we must satisfy min-width >= width).
      box.availableWidth = stretch(min_width)
      box.resolveContentWidth(min_width, containingWidth)

proc calcAvailableHeight(box: BlockBox, containingHeight: SizeConstraint,
    percHeight: Option[LayoutUnit], lctx: LayoutState) =
  let computed = box.computed
  let height = computed{"height"}
  var heightpx: LayoutUnit = 0
  if not height.auto and height.canpx(percHeight):
    heightpx = height.px(lctx, percHeight).get
    box.availableHeight = stretch(heightpx)
  if not computed{"max-height"}.auto:
    let max_height = computed{"max-height"}.px(lctx, percHeight)
    box.max_height = max_height
    if max_height.isSome:
      if box.availableHeight.t in {STRETCH, FIT_CONTENT} and
          max_height.get < box.availableHeight.u or
          box.availableHeight.t == MAX_CONTENT:
        # same reasoning as for width.
        if box.availableWidth.t == STRETCH:
          box.availableWidth = stretch(max_height.get)
        else: # FIT_CONTENT
          box.availableWidth = fitContent(max_height.get)
  if not computed{"min-height"}.auto:
    let min_height = computed{"min-height"}.px(lctx, percHeight)
    if min_height.isSome:
      box.min_height = min_height
      if box.availableHeight.t in {STRETCH, FIT_CONTENT} and
          min_height.get > box.availableHeight.u or
          box.availableHeight.t == MIN_CONTENT:
        # same reasoning as for width.
        box.availableHeight = stretch(min_height.get)

proc calcAbsoluteAvailableWidth(box: BlockBox,
    containingWidth: SizeConstraint, lctx: LayoutState) =
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let width = box.computed{"width"}
  if width.auto:
    if not left.auto and not right.auto:
      # width is auto and left & right are not auto.
      # Solve for width.
      if containingWidth.isDefinite:
        let leftpx = left.px(lctx, containingWidth)
        let rightpx = right.px(lctx, containingWidth)
        let u = containingWidth.u - leftpx - rightpx -
          box.margin_left - box.margin_right - box.padding_left -
          box.padding_right
        box.availableWidth = stretch(max(u, 0))
      else:
        box.availableWidth = containingWidth
    else:
      # Return shrink to fit and solve for left/right.
      # Note that we do not know content width yet, so it is impossible to
      # solve left/right yet.
      box.availableWidth = fitContent(containingWidth)
  else:
    let widthpx = width.px(lctx, containingWidth)
    # We could solve for left/right here, as available width is known.
    # Nevertheless, it is only needed for positioning, so we do not solve
    # them yet.
    box.availableWidth = stretch(widthpx)

proc calcAbsoluteAvailableHeight(box: BlockBox,
    containingHeight: SizeConstraint, lctx: LayoutState) =
  #TODO this might be incorrect because of percHeight?
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let height = box.computed{"height"}
  if height.auto:
    if not top.auto and not bottom.auto:
      # height is auto and top & bottom are not auto.
      # Solve for height.
      if containingHeight.isDefinite:
        let toppx = top.px(lctx, containingHeight)
        let bottompx = bottom.px(lctx, containingHeight)
        #TODO I assume border collapsing does not matter here?
        let u = containingHeight.u - toppx - bottompx -
          box.margin_top - box.margin_bottom - box.padding_top -
          box.padding_bottom
        box.availableHeight = stretch(max(u, 0))
      else:
        box.availableHeight = containingHeight
    else:
      box.availableHeight = fitContent(containingHeight)
  else:
    let heightpx = height.px(lctx, containingHeight)
    box.availableHeight = stretch(heightpx)

# Calculate and resolve available width & height for absolutely positioned
# boxes.
proc calcAbsoluteAvailableSizes(box: BlockBox, lctx: LayoutState) =
  let containingWidth = lctx.positioned[^1].availableWidth
  let containingHeight = lctx.positioned[^1].availableHeight
  box.resolveMargins(containingWidth, lctx)
  box.resolvePadding(containingWidth, lctx)
  box.calcAbsoluteAvailableWidth(containingWidth, lctx)
  box.calcAbsoluteAvailableHeight(containingHeight, lctx)

# Calculate and resolve available width & height for box children.
# availableWidth: width of the containing box
# availableHeight: ditto, but with height.
# Note that this is not the final content size, just the amount of space
# available for content.
# The percentage width/height is generally
# availableSize.isDefinite() ? availableSize.u : 0, but for some reason it
# differs for the root height (TODO: and all heights in quirks mode) in that
# it uses the lctx height. Therefore we pass percHeight as a separate
# parameter. (TODO surely there is a better solution to this?)
proc calcAvailableSizes(box: BlockBox, containingWidth, containingHeight:
    SizeConstraint, percHeight: Option[LayoutUnit], lctx: LayoutState) =
  if box.computed{"position"} == POSITION_ABSOLUTE:
    box.calcAbsoluteAvailableSizes(lctx)
  else:
    box.resolveMargins(containingWidth, lctx)
    box.resolvePadding(containingWidth, lctx)
    # Take defined sizes if our width/height resolves to auto.
    # (For block boxes, this is width: stretch(parentWidth), height: max-content)
    box.availableWidth = containingWidth
    box.availableHeight = containingHeight
    # Finally, calculate available width and height.
    box.calcAvailableWidth(containingWidth, lctx)
    box.calcAvailableHeight(containingHeight, percHeight, lctx)

proc calcTableCellAvailableSizes(box: BlockBox, availableWidth, availableHeight:
    SizeConstraint, override: bool, lctx: LayoutState) =
  let computed = box.computed
  box.resolvePadding(availableWidth, lctx)
  box.availableWidth = availableWidth
  box.availableHeight = availableHeight

  if not override:
    let width = computed{"width"}
    if not width.auto and width.unit != UNIT_PERC:
      box.availableWidth = stretch(width.px(lctx))
  box.availableWidth.u -= box.padding_left
  box.availableWidth.u -= box.padding_right

  if not override:
    let height = computed{"height"}
    if not height.auto and height.unit != UNIT_PERC:
      box.availableHeight = stretch(height.px(lctx))

proc newTableCellBox(lctx: LayoutState, builder: BoxBuilder,
    availableWidth, availableHeight: SizeConstraint, override: bool):
    BlockBox =
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node
  )
  box.calcTableCellAvailableSizes(availableWidth, availableHeight, override,
    lctx)
  return box

proc newFlowRootBox(lctx: LayoutState, builder: BoxBuilder,
    availableWidth, availableHeight: SizeConstraint,
    percHeight: Option[LayoutUnit]): BlockBox =
  let box = BlockBox(
    computed: builder.computed,
    node: builder.node,
    positioned: builder.computed{"position"} != POSITION_STATIC,
  )
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight, lctx)
  return box

func toPercSize(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

proc newBlockBox(lctx: LayoutState, parent: BlockBox, builder: BoxBuilder):
    BlockBox =
  let box = BlockBox(
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentHeight = parent.availableHeight
  let availableWidth = parent.availableWidth
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight, lctx)
  return box

proc newBlockBoxStretch(lctx: LayoutState, parent: BlockBox,
    builder: BoxBuilder): BlockBox =
  let box = BlockBox(
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = parent.availableWidth
  let parentHeight = parent.availableHeight
  let availableWidth = stretch(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight, lctx)
  return box

proc newBlockBoxFit(lctx: LayoutState, parent: BlockBox, builder: BoxBuilder):
    BlockBox =
  let box = BlockBox(
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = parent.availableWidth
  let parentHeight = parent.availableHeight
  let availableWidth = fitContent(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight, lctx)
  return box

proc newListItem(lctx: LayoutState, parent: BlockBox,
    builder: ListItemBoxBuilder): ListItemBox =
  let box = ListItemBox(
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = parent.availableWidth
  let parentHeight = parent.availableHeight
  let availableWidth = stretch(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight, lctx)
  return box

proc buildBlock(lctx: LayoutState, builder: BlockBoxBuilder,
  parent: BlockBox): BlockBox
proc buildInlines(lctx: LayoutState, parent: BlockBox,
  inlines: seq[BoxBuilder]): InlineContext
proc buildBlockLayout(lctx: LayoutState, box: BlockBox,
  builders: seq[BoxBuilder], node: StyledNode)
proc buildTable(lctx: LayoutState, builder: TableBoxBuilder,
  parent: BlockBox): BlockBox
proc buildTableLayout(lctx: LayoutState, table: BlockBox,
  builder: TableBoxBuilder)

# Note: padding must still be applied after this.
proc applyWidth(box: BlockBox, maxChildWidth: LayoutUnit) =
  # Make the box as small/large as the content's width or specified width.
  box.width = maxChildWidth.applySizeConstraint(box.availableWidth)
  # Then, clamp it to min_width and max_width (if applicable).
  box.width = clamp(box.width, box.min_width.get(0),
    box.max_width.get(high(LayoutUnit)))

proc applyInlineDimensions(box: BlockBox) =
  box.xminwidth = max(box.xminwidth, box.inline.minwidth)
  box.width = box.inline.width + box.padding_left + box.padding_right
  box.height = applySizeConstraint(box.inline.height, box.availableHeight)
  box.height += box.padding_top + box.padding_bottom
  box.inline.offset.x += box.padding_left
  box.inline.offset.y += box.padding_top
  box.applyWidth(box.inline.width)
  box.width += box.padding_left
  box.width += box.padding_right
  box.baseline = box.inline.offset.y + box.inline.baseline
  box.firstBaseline = box.inline.offset.y + box.inline.firstBaseline

proc buildInlineLayout(lctx: LayoutState, parent: BlockBox,
    children: seq[BoxBuilder]) =
  parent.inline = lctx.buildInlines(parent, children)
  parent.applyInlineDimensions()

proc buildFlowLayout(lctx: LayoutState, box: BlockBox,
    builder: BlockBoxBuilder) =
  if builder.inlinelayout:
    # Builder only contains inline boxes.
    lctx.buildInlineLayout(box, builder.children)
  else:
    # Builder only contains block boxes.
    lctx.buildBlockLayout(box, builder.children, builder.node)

func toperc100(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

# parentWidth, parentHeight: width/height of the containing block.
proc addInlineBlock(state: var InlineState, builder: BlockBoxBuilder,
    parentWidth, parentHeight: SizeConstraint, computed: CSSComputedValues) =
  let innerbox = newFlowRootBox(state.lctx, builder,
    fitContent(parentWidth), maxContent(), parentHeight.toperc100())
  let lctx = state.lctx
  case builder.computed{"display"}
  of DISPLAY_INLINE_BLOCK:
    lctx.buildFlowLayout(innerbox, builder)
  of DISPLAY_INLINE_TABLE:
    lctx.buildTableLayout(innerbox, TableBoxBuilder(builder))
  else:
    assert false, $builder.computed{"display"}
  # Apply the block box's properties to the atom itself.
  let iblock = InlineAtom(
    t: INLINE_BLOCK,
    innerbox: innerbox,
    offset: Offset(x: innerbox.margin_left),
    size: Size(
      w: innerbox.width + innerbox.margin_left + innerbox.margin_right,
      h: innerbox.height
    )
  )
  let iastate = InlineAtomState(
    baseline: iblock.innerbox.baseline,
    vertalign: builder.computed{"vertical-align"},
    margin_top: iblock.innerbox.margin_top,
    margin_bottom: iblock.innerbox.margin_bottom
  )
  discard state.addAtom(iastate, iblock, computed)

proc buildInline(state: var InlineState, box: InlineBoxBuilder) =
  let lctx = state.lctx
  if box.newline:
    state.flushLine(box.computed)

  let paddingformat = getComputedFormat(box.computed, box.node)
  if box.splitstart:
    let margin_left = box.computed{"margin-left"}.px(lctx,
      state.availableWidth)
    state.currentLine.size.w += margin_left

    let padding_left = box.computed{"padding-left"}.px(lctx,
      state.availableWidth)
    if padding_left > 0:
      # We must add spacing to the line to make sure that it is formatted
      # (i.e. colored) appropriately.
      # We need this so long as we have no proper inline boxes.
      state.addPadding(padding_left, state.cellheight, paddingformat)

  assert box.children.len == 0 or box.text.len == 0
  for text in box.text:
    state.layoutText(text, box.computed, box.node)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      state.buildInline(child)
    of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
      let child = BlockBoxBuilder(child)
      let w = fitContent(state.availableWidth)
      let h = state.availableHeight
      state.addInlineBlock(child, w, h, box.computed)
      state.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  if box.splitend:
    let padding_right = box.computed{"padding-right"}.px(lctx,
      state.availableWidth)
    state.currentLine.size.w += padding_right
    if padding_right > 0:
      let height = max(state.currentLine.size.h, 1)
      state.addPadding(padding_right, height, paddingformat)
    let margin_right = box.computed{"margin-right"}.px(lctx,
      state.availableWidth)
    state.currentLine.size.w += margin_right

proc buildInlines(lctx: LayoutState, parent: BlockBox,
    inlines: seq[BoxBuilder]): InlineContext =
  var state = newInlineState(lctx, parent.availableWidth,
    parent.availableHeight)
  if inlines.len > 0:
    for child in inlines:
      case child.computed{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        state.buildInline(child)
      of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
        #TODO wtf
        let child = BlockBoxBuilder(child)
        let w = fitContent(state.availableWidth)
        let h = state.availableHeight
        state.addInlineBlock(child, w, h, parent.computed)
        state.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    state.finish(parent.computed)
  return state.ictx

proc buildMarker(builder: MarkerBoxBuilder, parent: BlockBox,
    lctx: LayoutState): InlineContext =
  let availableWidth = fitContent(parent.availableWidth)
  var state = newInlineState(lctx, availableWidth, parent.availableHeight)
  state.buildInline(builder)
  state.finish(builder.computed)
  return state.ictx

proc buildListItem(lctx: LayoutState, builder: ListItemBoxBuilder,
    parent: BlockBox): ListItemBox =
  result = newListItem(lctx, parent, builder)
  if builder.marker != nil:
    result.marker = buildMarker(builder.marker, result, lctx)
  lctx.buildFlowLayout(result, builder.content)

proc positionAbsolute(lctx: LayoutState, box: BlockBox) =
  let last = lctx.positioned[^1]
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let parentWidth = applySizeConstraint(lctx.attrs.width_px,
    last.availableWidth)
  let parentHeight = applySizeConstraint(lctx.attrs.height_px,
    last.availableHeight)
  box.x_positioned = not (left.auto and right.auto)
  box.y_positioned = not (top.auto and bottom.auto)
  if not left.auto:
    box.offset.x += left.px(lctx, parentWidth)
    box.offset.x += box.margin_left
  elif not right.auto:
    box.offset.x += parentWidth - right.px(lctx, parentWidth) - box.width
    box.offset.x -= box.margin_right
  if not top.auto:
    box.offset.y += top.px(lctx, parentHeight)
    box.offset.y += box.margin_top
  elif not bottom.auto:
    box.offset.y += parentHeight - bottom.px(lctx, parentHeight) - box.height
    box.offset.y -= box.margin_bottom

proc positionRelative(parent, box: BlockBox, lctx: LayoutState) =
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  if not left.auto:
    box.offset.x += right.px(lctx)
  elif not right.auto:
    box.offset.x += parent.width - right.px(lctx) - box.width
  if not top.auto:
    box.offset.y += top.px(lctx)
  elif not top.auto:
    box.offset.y -= parent.height - bottom.px(lctx) - box.height

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
  let w = availableWidth
  let h = maxContent()
  let ph = availableHeight.toperc100()
  let box = lctx.newFlowRootBox(builder, w, h, ph)
  lctx.buildFlowLayout(box, builder)
  return box

proc buildTableCell(lctx: LayoutState, builder: TableCellBoxBuilder,
    availableWidth, availableHeight: SizeConstraint, override: bool):
    BlockBox =
  let tableCell = lctx.newTableCellBox(builder, availableWidth,
    availableHeight, override)
  lctx.buildFlowLayout(tableCell, builder)
  return tableCell

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
    let w = box.width div colspan
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
    cell.offset.y = availableHeight div 2 - cell.height div 2
  of VERTICAL_ALIGN_BOTTOM:
    cell.offset.y = availableHeight - cell.height
  else:
    cell.offset.y = baseline - cell.firstBaseline

proc buildTableRow(pctx: TableContext, ctx: RowContext, parent: BlockBox,
    builder: TableRowBoxBuilder): BlockBox =
  var x: LayoutUnit = 0
  var n = 0
  let row = newBlockBoxStretch(pctx.lctx, parent, builder)
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
      w = max(w, cellw.box.width)
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
      row.height = max(row.height, cell.height div cellw.rowspan)
    else:
      let real = cellw.real
      row.height = max(row.height, real.box.height div cellw.rowspan)
      to_height.add(real)
      if cellw.last:
        to_align.add(real)
  for cellw in to_height:
    cellw.height += row.height
  for cellw in to_baseline:
    cellw.baseline = baseline
  for cellw in to_align:
    alignTableCell(cellw.box, cellw.height, cellw.baseline)
  for cell in row.nested:
    alignTableCell(cell, row.height, baseline)
  row.width = x
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

func needsRedistribution(ctx: TableContext, table: BlockBox): bool =
  case table.availableWidth.t
  of MIN_CONTENT, MAX_CONTENT:
    # bleh
    return false
  of STRETCH:
    let u = table.availableWidth.u
    return u > ctx.maxwidth or u < ctx.maxwidth
  of FIT_CONTENT:
    let u = table.availableWidth.u
    return u > ctx.maxwidth and not table.computed{"width"}.auto or
      u < ctx.maxwidth

proc redistributeWidth(ctx: var TableContext, table: BlockBox) =
  var W = table.availableWidth.u
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

proc buildTableRows(ctx: TableContext, table: BlockBox) =
  var y: LayoutUnit = 0
  for roww in ctx.rows:
    if roww.builder.computed{"visibility"} == VISIBILITY_COLLAPSE:
      continue
    y += ctx.blockspacing
    let row = ctx.buildTableRow(roww, table, roww.builder)
    row.offset.y += y
    row.offset.x += table.padding_left
    row.width += table.padding_left
    row.width += table.padding_right
    y += ctx.blockspacing
    y += row.height
    table.nested.add(row)
    table.width = max(row.width, table.width)
  table.height = applySizeConstraint(y, table.availableHeight)

proc addTableCaption(ctx: TableContext, table: BlockBox) =
  let lctx = ctx.lctx
  case ctx.caption.computed{"caption-side"}
  of CAPTION_SIDE_TOP, CAPTION_SIDE_BLOCK_START:
    let caption = lctx.buildTableCaption(ctx.caption,
      stretch(table.width), maxContent())
    for r in table.nested:
      r.offset.y += caption.height
    table.nested.insert(caption, 0)
    table.height += caption.height
    table.width = max(table.width, caption.width)
  of CAPTION_SIDE_BOTTOM, CAPTION_SIDE_BLOCK_END:
    let caption = lctx.buildTableCaption(ctx.caption, stretch(table.width),
      maxContent())
    caption.offset.y += table.width
    table.nested.add(caption)
    table.height += caption.height
    table.width = max(table.width, caption.width)
  of CAPTION_SIDE_LEFT, CAPTION_SIDE_INLINE_START:
    let caption = lctx.buildTableCaption(ctx.caption,
      fitContent(table.availableWidth), fitContent(table.height))
    for r in table.nested:
      r.offset.x += caption.width
    table.nested.insert(caption, 0)
    table.width += caption.width
    table.height = max(table.height, caption.height)
  of CAPTION_SIDE_RIGHT, CAPTION_SIDE_INLINE_END:
    let caption = lctx.buildTableCaption(ctx.caption,
      fitContent(table.availableWidth), fitContent(table.height))
    caption.offset.x += table.width
    table.nested.add(caption)
    table.width += caption.width
    table.height = max(table.height, caption.height)

# Table layout. We try to emulate w3m's behavior here:
# 1. Calculate minimum and preferred width of each column
# 2. If column width is not auto, set width to max(min_col_width, specified)
# 3. Calculate the maximum preferred row width. If this is
# a) less than the specified table width, or
# b) greater than the table's content width:
#      Distribute the table's content width among cells with an unspecified
#      width. If this would give any cell a width < min_width, set that
#      cell's width to min_width, then re-do the distribution.
proc buildTableLayout(lctx: LayoutState, table: BlockBox,
    builder: TableBoxBuilder) =
  let collapse = table.computed{"border-collapse"} == BORDER_COLLAPSE_COLLAPSE
  var ctx = TableContext(lctx: lctx, collapse: collapse)
  if not ctx.collapse:
    ctx.inlinespacing = table.computed{"border-spacing"}.a.px(lctx)
    ctx.blockspacing = table.computed{"border-spacing"}.b.px(lctx)
  ctx.preBuildTableRows(builder, table)
  ctx.reflow = newSeq[bool](ctx.cols.len)
  if ctx.needsRedistribution(table):
    ctx.redistributeWidth(table)
  for col in ctx.cols:
    table.width += col.width
  ctx.reflowTableCells()
  ctx.buildTableRows(table)
  if ctx.caption != nil:
    ctx.addTableCaption(table)

proc buildTable(lctx: LayoutState, builder: TableBoxBuilder, parent: BlockBox):
    BlockBox =
  let box = newBlockBoxFit(lctx, parent, builder)
  lctx.buildTableLayout(box, builder)
  return box

type
  BlockState = object
    lctx: LayoutState
    x: LayoutUnit
    y: LayoutUnit
    childHeight: LayoutUnit
    maxChildWidth: LayoutUnit
    margin_todo: Strut
    nested: seq[BlockBox]

  Strut = object
    pos: LayoutUnit
    neg: LayoutUnit

proc append(a: var Strut, b: LayoutUnit) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum(a: Strut): LayoutUnit =
  return a.pos + a.neg

proc applyChildPosition(ctx: var BlockState, parent, child: BlockBox) =
  if child.computed{"position"} == POSITION_ABSOLUTE: #TODO sticky, fixed
    if child.computed{"left"}.auto and child.computed{"right"}.auto:
      child.offset.x = ctx.x
    if child.computed{"top"}.auto and child.computed{"bottom"}.auto:
      child.offset.y = ctx.y + ctx.margin_todo.sum()
    child.offset.y += child.margin_top
  else:
    child.offset.y = ctx.y
    child.offset.x = ctx.x
    ctx.y += child.height
    ctx.childHeight += child.height
    ctx.maxChildWidth = max(ctx.maxChildWidth, child.width)
    parent.xminwidth = max(parent.xminwidth, child.xminwidth)
    ctx.margin_todo = Strut()
    ctx.margin_todo.append(child.margin_bottom)

proc postAlignChild(box, child: BlockBox, width: LayoutUnit) =
  case box.computed{"text-align"}
  of TEXT_ALIGN_CHA_CENTER:
    child.offset.x += max(width div 2 - child.width div 2, 0)
  of TEXT_ALIGN_CHA_LEFT: discard
  of TEXT_ALIGN_CHA_RIGHT:
    child.offset.x += max(width - child.width, 0)
  else:
    child.offset.x += child.margin_left

proc addBlockChild(ctx: var BlockState, box: BlockBox,
    builder: BoxBuilder): BlockBox =
  let lctx = ctx.lctx
  let box = case builder.computed{"display"}
  of DISPLAY_BLOCK:
    lctx.buildBlock(BlockBoxBuilder(builder), box)
  of DISPLAY_LIST_ITEM:
    lctx.buildListItem(ListItemBoxBuilder(builder), box)
  of DISPLAY_TABLE:
    lctx.buildTable(TableBoxBuilder(builder), box)
  else:
    assert false, "builder.t is " & $builder.computed{"display"}
    BlockBox(nil)
  ctx.nested.add(box)
  return box

proc skipAbsolutes(ctx: var BlockState, box: BlockBox,
    builders: seq[BoxBuilder]): int =
  var i = 0
  while i < builders.len:
    let builder = builders[i]
    if builder.computed{"position"} != POSITION_ABSOLUTE:
      break
    let child = ctx.addBlockChild(box, builder)
    if child.computed{"position"} != POSITION_ABSOLUTE:
      break
    ctx.applyChildPosition(box, child)
    inc i
  return i

proc buildBlockLayout(lctx: LayoutState, box: BlockBox,
    builders: seq[BoxBuilder], node: StyledNode) =
  let positioned = box.computed{"position"} != POSITION_STATIC
  if positioned:
    lctx.positioned.add(box)
  var ctx = BlockState(
    x: box.padding_left,
    y: box.padding_top,
    childHeight: box.padding_top,
    lctx: lctx
  )

  # Skip absolute boxes before setting the first margin.
  var i = ctx.skipAbsolutes(box, builders)

  if i < builders.len:
    let builder = builders[i]
    let child = ctx.addBlockChild(box, builder)
    ctx.margin_todo.append(box.margin_top)
    ctx.margin_todo.append(child.margin_top)
    box.margin_top = ctx.margin_todo.sum()
    ctx.applyChildPosition(box, child)
    box.firstBaseline = child.offset.y + child.firstBaseline
    inc i

  while i < builders.len:
    let builder = builders[i]
    let child = ctx.addBlockChild(box, builder)
    if child.computed{"position"} != POSITION_ABSOLUTE:
      ctx.margin_todo.append(child.margin_top)
      ctx.y += ctx.margin_todo.sum()
      ctx.childHeight += ctx.margin_todo.sum()
    ctx.applyChildPosition(box, child)
    inc i

  if ctx.nested.len > 0:
    let lastNested = ctx.nested[^1]
    box.baseline = lastNested.offset.y + lastNested.baseline

  ctx.margin_todo.append(box.margin_bottom)
  box.margin_bottom = ctx.margin_todo.sum()

  box.applyWidth(ctx.maxChildWidth)

  # Re-position the children.
  # The x offset for values in shrink mode depends on the parent box's
  # width, so we cannot do this in the first pass.
  let width = box.width
  for child in ctx.nested:
    if child.computed{"position"} != POSITION_ABSOLUTE:
      box.postAlignChild(child, width)
    case child.computed{"position"}
    of POSITION_RELATIVE:
      box.positionRelative(child, lctx)
    of POSITION_ABSOLUTE:
      lctx.positionAbsolute(child)
    else: discard #TODO

  # Finally, add padding. (We cannot do this further up without influencing
  # positioning.)
  box.width += box.padding_left
  box.width += box.padding_right

  ctx.childHeight += box.padding_bottom

  box.height = applySizeConstraint(ctx.childHeight, box.availableHeight)
  if box.max_height.isSome and box.height > box.max_height.get:
    box.height = box.max_height.get
  if box.min_height.isSome and box.height < box.min_height.get:
    box.height = box.min_height.get
  box.nested = ctx.nested
  if positioned:
    discard lctx.positioned.pop()

# Build a block box inside another block box, based on a builder.
proc buildBlock(lctx: LayoutState, builder: BlockBoxBuilder,
    parent: BlockBox): BlockBox =
  let box = newBlockBox(lctx, parent, builder)
  lctx.buildFlowLayout(box, builder)
  return box

# Establish a new flow-root context and build a block box.
proc buildRootBlock(lctx: LayoutState, builder: BlockBoxBuilder): BlockBox =
  let w = stretch(lctx.attrs.width_px)
  let h = maxContent()
  let vh: LayoutUnit = lctx.attrs.height_px
  let box = lctx.newFlowRootBox(builder, w, h, some(vh))
  lctx.positioned.add(box)
  lctx.buildFlowLayout(box, builder)
  # Normally margin-top would be used by positionBlock, but the root block
  # doesn't get positioned by the parent, so we have to do it manually here.
  #TODO this is kind of ugly.
  box.offset.y += box.margin_top
  return box

# Generation phase

# Returns a block box, disregarding the computed value of display
proc getBlockBox(computed: CSSComputedValues): BlockBoxBuilder =
  return BlockBoxBuilder(computed: computed)

proc getTextBox(computed: CSSComputedValues): InlineBoxBuilder =
  return InlineBoxBuilder(inlinelayout: true, computed: computed)

proc getMarkerBox(computed: CSSComputedValues, listItemCounter: int):
    MarkerBoxBuilder =
  let computed = computed.inheritProperties()
  computed{"display"} = DISPLAY_INLINE
  # Use pre, so the space at the end of the default markers isn't ignored.
  computed{"white-space"} = WHITESPACE_PRE
  return MarkerBoxBuilder(
    inlinelayout: true,
    computed: computed,
    text: @[computed{"list-style-type"}.listMarker(listItemCounter)]
  )

proc getListItemBox(computed: CSSComputedValues, listItemCounter: int):
    ListItemBoxBuilder =
  return ListItemBoxBuilder(
    computed: computed,
    marker: getMarkerBox(computed, listItemCounter)
  )

proc getTableBox(computed: CSSComputedValues): TableBoxBuilder =
  return TableBoxBuilder(
    computed: computed
  )

# Also known as <tbody>.
proc getTableRowGroupBox(computed: CSSComputedValues): TableRowGroupBoxBuilder =
  return TableRowGroupBoxBuilder(
    computed: computed
  )

proc getTableRowBox(computed: CSSComputedValues): TableRowBoxBuilder =
  return TableRowBoxBuilder(
    computed: computed
  )

# For <th> and <td>.
proc getTableCellBox(computed: CSSComputedValues): TableCellBoxBuilder =
  return TableCellBoxBuilder(
    computed: computed
  )

proc getTableCaptionBox(computed: CSSComputedValues): TableCaptionBoxBuilder =
  return TableCaptionBoxBuilder(
    computed: computed
  )

type BlockGroup = object
  parent: BoxBuilder
  boxes: seq[BoxBuilder]

type InnerBlockContext = object
  styledNode: StyledNode
  blockgroup: BlockGroup
  lctx: LayoutState
  ibox: InlineBoxBuilder
  anonRow: TableRowBoxBuilder
  anonTable: TableBoxBuilder
  quoteLevel: int
  listItemCounter: int
  listItemReset: bool
  parent: ptr InnerBlockContext

proc add(blockgroup: var BlockGroup, box: BoxBuilder) {.inline.} =
  assert box.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_TABLE,
    DISPLAY_INLINE_BLOCK}, $box.computed{"display"}
  blockgroup.boxes.add(box)

proc flush(blockgroup: var BlockGroup) {.inline.} =
  if blockgroup.boxes.len > 0:
    assert blockgroup.parent.computed{"display"} != DISPLAY_INLINE
    let computed = blockgroup.parent.computed.inheritProperties()
    computed{"display"} = DISPLAY_BLOCK
    let bbox = getBlockBox(computed)
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

proc newBlockGroup(parent: BoxBuilder): BlockGroup =
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
        ctx.anonTable = getTableBox(wrappervals)
      ctx.anonTable.children.add(ctx.anonRow)
    ctx.anonRow = nil

proc flushTable(ctx: var InnerBlockContext) =
  ctx.flushTableRow()
  if ctx.anonTable != nil:
    ctx.blockgroup.parent.children.add(ctx.anonTable)

proc iflush(ctx: var InnerBlockContext) =
  if ctx.ibox != nil:
    assert ctx.ibox.computed{"display"} in {DISPLAY_INLINE,
      DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE}
    ctx.blockgroup.add(ctx.ibox)
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
  of DISPLAY_BLOCK:
    ctx.iflush()
    ctx.flush()
    let childbox = ctx.generateBlockBox(styledNode)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    ctx.flush()
    inc ctx.listItemCounter
    let childbox = getListItemBox(styledNode.computed, ctx.listItemCounter)
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
        ctx.anonTable = getTableBox(wrappervals)
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
        ctx.anonTable = getTableBox(wrappervals)
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
        ctx.anonRow = getTableRowBox(wrappervals)
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
        ctx.anonTable = getTableBox(wrappervals)
      ctx.anonTable.children.add(childbox)
  of DISPLAY_TABLE_COLUMN:
    discard #TODO
  of DISPLAY_TABLE_COLUMN_GROUP:
    discard #TODO
  of DISPLAY_NONE: discard

proc generateAnonymousInlineText(ctx: var InnerBlockContext, text: string,
    styledNode: StyledNode) =
  if ctx.ibox == nil:
    ctx.ibox = getTextBox(styledNode.computed.inheritProperties())
    ctx.ibox.node = styledNode
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
    ctx.ibox = getTextBox(parent.computed.inheritProperties())
    ctx.ibox.newline = true
    ctx.iflush()

proc generateInlineBoxes(ctx: var InnerBlockContext, styledNode: StyledNode) =
  ctx.iflush()
  var lbox = getTextBox(styledNode.computed)
  lbox.node = styledNode
  lbox.splitstart = true
  ctx.ibox = lbox
  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      ctx.generateFromElem(child)
    of STYLED_TEXT:
      if ctx.ibox != lbox:
        ctx.iflush()
        lbox = getTextBox(styledNode.computed)
        lbox.node = styledNode
        ctx.ibox = lbox
      lbox.text.add(child.text)
    of STYLED_REPLACEMENT:
      ctx.generateReplacement(child, styledNode)
  if ctx.ibox != lbox:
    ctx.iflush()
    lbox = getTextBox(styledNode.computed)
    lbox.node = styledNode
    ctx.ibox = lbox
  lbox.splitend = true
  ctx.iflush()

proc newInnerBlockContext(styledNode: StyledNode, box: BoxBuilder,
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
  let box = getBlockBox(styledNode.computed)
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
  let box = getTableCellBox(styledNode.computed)
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
      let wrapper = getTableCellBox(wrappervals)
      wrapper.children.add(child)
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableRowBoxBuilder =
  let box = getTableRowBox(styledNode.computed)
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
      let wrapper = getTableRowBox(wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowGroupBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableRowGroupBoxBuilder =
  let box = getTableRowGroupBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowGroupChildWrappers()
  return box

proc generateTableCaptionBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableCaptionBoxBuilder =
  let box = getTableCaptionBox(styledNode.computed)
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
      let wrapper = getTableRowBox(wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableBox(styledNode: StyledNode, lctx: LayoutState,
    parent: var InnerBlockContext): TableBoxBuilder =
  let box = getTableBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, lctx, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableChildWrappers()
  return box

proc renderLayout*(root: StyledNode, attrs: WindowAttributes): BlockBox =
  let lctx = LayoutState(attrs: attrs)
  let builder = root.generateBlockBox(lctx)
  return lctx.buildRootBlock(builder)
