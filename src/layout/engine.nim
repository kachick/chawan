import algorithm
import math
import options
import unicode

import css/stylednode
import css/values
import display/window
import layout/box
import layout/layoutunit
import utils/twtstr

# Build phase
func px(l: CSSLength, viewport: Viewport, p: LayoutUnit = 0):
    LayoutUnit {.inline.} =
  return px(l, viewport.window, p)

func px(l: CSSLength, viewport: Viewport, p: Option[LayoutUnit]):
    Option[LayoutUnit] {.inline.} =
  if l.unit == UNIT_PERC and p.isNone:
    return none(LayoutUnit)
  return some(px(l, viewport.window, p.get(0)))

func canpx(l: CSSLength, sc: SizeConstraint): bool =
  return l.unit != UNIT_PERC or sc.isDefinite()

func canpx(l: CSSLength, p: Option[LayoutUnit]): bool =
  return l.unit != UNIT_PERC or p.isSome

# Note: for margins only
# For percentages, use 0 for indefinite, and containing box's size for
# definite.
func px(l: CSSLength, viewport: Viewport, p: SizeConstraint): LayoutUnit =
  if l.unit == UNIT_PERC:
    case p.t
    of MIN_CONTENT, MAX_CONTENT:
      return 0
    of STRETCH, FIT_CONTENT:
      return l.px(viewport, p.u)
  return px(l, viewport.window, 0)

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

type InlineState = object
  ictx: InlineContext
  skip: bool
  node: StyledNode
  word: InlineWord
  wrappos: int # position of last wrapping opportunity, or -1
  hasshy: bool
  computed: CSSComputedValues

func whitespacepre(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP}

func nowrap(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}

func cellwidth(viewport: Viewport): LayoutUnit =
  viewport.window.ppc

func cellwidth(ictx: InlineContext): LayoutUnit =
  ictx.viewport.cellwidth

func cellheight(viewport: Viewport): LayoutUnit =
  viewport.window.ppl

func cellheight(ictx: InlineContext): LayoutUnit =
  ictx.viewport.cellheight

# Check if the last atom on the current line is a spacing atom, not counting
# padding atoms.
func hasLastSpacing(ictx: InlineContext): bool =
  for i in countdown(ictx.currentLine.atoms.high, 0):
    if ictx.currentLine.atoms[i] of InlineSpacing:
      if ictx.currentLine.atoms[i] of InlinePadding:
        continue # skip padding
      return true
    else:
      break
  return false

# Whitespace between words
func computeShift(ictx: InlineContext, computed: CSSComputedValues):
    LayoutUnit =
  if ictx.whitespacenum > 0:
    if ictx.currentLine.atoms.len > 0 and not ictx.hasLastSpacing() or
        computed.whitespacepre:
      let spacing = computed{"word-spacing"}
      if spacing.auto:
        return ictx.cellwidth * ictx.whitespacenum
      return spacing.px(ictx.viewport) * ictx.whitespacenum
  return 0

proc applyLineHeight(viewport: Viewport, line: LineBox, computed: CSSComputedValues) =
  #TODO this should be computed during cascading.
  let lineheight = if computed{"line-height"}.auto: # ergo normal
    viewport.cellheight
  else:
    # Percentage: refers to the font size of the element itself.
    computed{"line-height"}.px(viewport, viewport.cellheight)
  line.lineheight = max(lineheight, line.lineheight)

func getComputedFormat(computed: CSSComputedValues, node: StyledNode): ComputedFormat =
  return ComputedFormat(
    color: computed{"color"},
    fontstyle: computed{"font-style"},
    fontweight: computed{"font-weight"},
    textdecoration: computed{"text-decoration"},
    bgcolor: computed{"background-color"},
    node: node
  )

proc newWord(state: var InlineState) =
  let word = InlineWord()
  word.format = getComputedFormat(state.computed, state.node)
  word.vertalign = state.computed{"vertical-align"}
  state.ictx.format = word.format
  state.word = word
  state.wrappos = -1
  state.hasshy = false

proc horizontalAlignLine(ictx: InlineContext, line: LineBox,
    computed: CSSComputedValues, last = false) =
  let width = case ictx.availableWidth.t
  of MIN_CONTENT, MAX_CONTENT:
    ictx.width
  of FIT_CONTENT:
    min(ictx.width, ictx.availableWidth.u)
  of STRETCH:
    max(ictx.width, ictx.availableWidth.u)
  # we don't support directions for now so left = start and right = end
  case computed{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT, TEXT_ALIGN_CHA_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CHA_RIGHT:
    # move everything
    let x = max(width, line.width) - line.width
    for atom in line.atoms:
      atom.offset.x += x
      ictx.width = max(atom.offset.x + atom.width, ictx.width)
  of TEXT_ALIGN_CENTER, TEXT_ALIGN_CHA_CENTER:
    let x = max((max(width - line.offset.x, line.width)) div 2 - line.width div 2, 0)
    for atom in line.atoms:
      atom.offset.x += x
      ictx.width = max(atom.offset.x + atom.width, ictx.width)
  of TEXT_ALIGN_JUSTIFY:
    if not computed.whitespacepre and not last:
      var sumwidth: LayoutUnit = 0
      var spaces = 0
      for atom in line.atoms:
        if atom of InlineSpacing:
          discard
        else:
          inc spaces
          sumwidth += atom.width
      dec spaces
      if spaces > 0:
        let spacingwidth = (width - sumwidth) div spaces
        line.width = 0
        for atom in line.atoms:
          atom.offset.x = line.width
          if atom of InlineSpacing:
            let atom = InlineSpacing(atom)
            atom.width = spacingwidth
          line.width += atom.width
  ictx.width = max(width, ictx.width) #TODO this seems meaningless?

# Align atoms (inline boxes, text, etc.) vertically inside the line.
proc verticalAlignLine(ictx: InlineContext) =
  let line = ictx.currentLine

  # Start with line-height as the baseline and line height.
  line.height = line.lineheight
  line.baseline = line.height

  # Calculate the line's baseline based on atoms' baseline.
  for atom in line.atoms:
    case atom.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      let len = atom.vertalign.length.px(ictx.viewport, line.lineheight)
      line.baseline = max(line.baseline, atom.baseline + len)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      line.baseline = max(line.baseline, atom.height)
    of VERTICAL_ALIGN_MIDDLE:
      line.baseline = max(line.baseline, atom.height div 2)
    else:
      line.baseline = max(line.baseline, atom.baseline)

  # Resize the line's height based on atoms' height and baseline.
  # The line height should be at least as high as the highest baseline used by
  # an atom plus that atom's height.
  for atom in line.atoms:
    # In all cases, the line's height must at least equal the atom's height.
    # (Where the atom is actually placed is irrelevant here.)
    line.height = max(line.height, atom.height)
    case atom.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Line height must be at least as high as
      # (line baseline) - (atom baseline) + (atom height) + (extra height).
      let len = atom.vertalign.length.px(ictx.viewport, line.lineheight)
      line.height = max(line.baseline - atom.baseline + atom.height + len, line.height)
    of VERTICAL_ALIGN_MIDDLE:
      # Line height must be at least
      # (line baseline) + (atom height / 2).
      line.height = max(line.baseline + atom.height div 2, line.height)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      # Line height must be at least atom height (already ensured above.)
      discard
    else:
      # See baseline (with len = 0).
      line.height = max(line.baseline - atom.baseline + atom.height, line.height)

  # Now we can calculate the actual position of atoms inside the line.
  for atom in line.atoms:
    case atom.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      # Atom is placed at (line baseline) - (atom baseline) - len
      let len = atom.vertalign.length.px(ictx.viewport, line.lineheight)
      atom.offset.y = line.baseline - atom.baseline - len
    of VERTICAL_ALIGN_MIDDLE:
      # Atom is placed at (line baseline) - ((atom height) / 2)
      atom.offset.y = line.baseline - atom.height div 2
    of VERTICAL_ALIGN_TOP:
      # Atom is placed at the top of the line.
      atom.offset.y = 0
    of VERTICAL_ALIGN_BOTTOM:
      # Atom is placed at the bottom of the line.
      atom.offset.y = line.height - atom.height
    else:
      # See baseline (with len = 0).
      atom.offset.y = line.baseline - atom.baseline

  # Finally, find the inline block with the largest block margins, then apply
  # these to the line itself.
  var margin_top: LayoutUnit = 0
  var margin_bottom: LayoutUnit = 0

  for atom in line.atoms:
    if atom of InlineBlockBox:
      let atom = InlineBlockBox(atom)
      margin_top = max(atom.margin_top, margin_top)
      margin_bottom = max(atom.margin_bottom, margin_bottom)

  for atom in line.atoms:
    atom.offset.y += margin_top

  line.height += margin_top
  line.height += margin_bottom

proc addPadding(line: LineBox, width, height: LayoutUnit,
    format: ComputedFormat) =
  let padding = InlinePadding(width: width, height: height, baseline: height, format: format)
  padding.offset.x = line.width
  line.width += width
  line.atoms.add(padding)

proc addSpacing(line: LineBox, width, height: LayoutUnit,
    format: ComputedFormat, hang = false) =
  let spacing = InlineSpacing(width: width, height: height, baseline: height, format: format)
  spacing.offset.x = line.width
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    line.width += spacing.width
  line.atoms.add(spacing)

proc flushWhitespace(ictx: InlineContext, computed: CSSComputedValues, hang = false) =
  let shift = ictx.computeShift(computed)
  ictx.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format, hang)

proc finishLine(ictx: InlineContext, computed: CSSComputedValues, force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    let whitespace = computed{"white-space"}
    if whitespace == WHITESPACE_PRE:
      ictx.flushWhitespace(computed)
    elif whitespace == WHITESPACE_PRE_WRAP:
      ictx.flushWhitespace(computed, hang = true)
    else:
      ictx.whitespacenum = 0
    ictx.verticalAlignLine()

    let line = ictx.currentLine
    ictx.lines.add(line)
    ictx.height += line.height
    ictx.width = max(ictx.width, line.width)
    ictx.currentLine = LineBox(offset: Offset(y: line.offset.y + line.height))
    ictx.charwidth = 0

proc finish(ictx: InlineContext, computed: CSSComputedValues) =
  ictx.finishLine(computed)
  for line in ictx.lines:
    ictx.horizontalAlignLine(line, computed, line == ictx.lines[^1])

func minwidth(atom: InlineAtom): LayoutUnit =
  if atom of InlineBlockBox:
    return cast[InlineBlockBox](atom).innerbox.xminwidth
  return atom.width

func shouldWrap(ictx: InlineContext, w: LayoutUnit,
    pcomputed: CSSComputedValues): bool =
  if pcomputed != nil and pcomputed.nowrap:
    return false
  if ictx.availableWidth.t == MAX_CONTENT:
    return false # no wrap with max-content
  if ictx.availableWidth.t == MIN_CONTENT:
    return true # always wrap with min-content
  return ictx.currentLine.width + w > ictx.availableWidth.u

# pcomputed: computed values of parent, for white-space: pre, line-height.
# This isn't necessarily the computed of ictx (e.g. they may differ for nested
# inline boxes.)
proc addAtom(ictx: InlineContext, atom: InlineAtom, pcomputed: CSSComputedValues) =
  var shift = ictx.computeShift(pcomputed)
  ictx.whitespacenum = 0
  # Line wrapping
  if ictx.shouldWrap(atom.width + shift, pcomputed):
    ictx.finishLine(pcomputed, false)
    # Recompute on newline
    shift = ictx.computeShift(pcomputed)

  if atom.width > 0 and atom.height > 0:
    if shift > 0:
      ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format)

    atom.offset.x += ictx.currentLine.width
    ictx.minwidth = max(ictx.minwidth, atom.minwidth)
    applyLineHeight(ictx.viewport, ictx.currentLine, pcomputed)
    ictx.currentLine.width += atom.width
    if atom of InlineWord:
      ictx.format = InlineWord(atom).format
    else:
      ictx.charwidth = 0
      ictx.format = nil
    ictx.currentLine.atoms.add(atom)

proc addWord(state: var InlineState) =
  if state.word.str != "":
    var word = state.word
    word.str.mnormalize() #TODO this may break on EOL.
    word.height = state.ictx.cellheight
    word.baseline = word.height
    state.ictx.addAtom(word, state.computed)
    state.newWord()

proc addWordEOL(state: var InlineState) =
  if state.word.str != "":
    if state.wrappos != -1:
      let leftstr = state.word.str.substr(state.wrappos)
      state.word.str = state.word.str.substr(0, state.wrappos - 1)
      if state.hasshy:
        state.word.str &= $Rune(0xAD) # soft hyphen
        state.hasshy = false
      state.addWord()
      state.word.str = leftstr
      state.word.width = leftstr.width() * state.ictx.cellwidth
    else:
      state.addWord()

# Start a new line, even if the previous one is empty
proc flushLine(ictx: InlineContext, computed: CSSComputedValues) =
  applyLineHeight(ictx.viewport, ictx.currentLine, computed)
  ictx.finishLine(computed, true)

proc checkWrap(state: var InlineState, r: Rune) =
  if state.computed.nowrap:
    return
  let shift = state.ictx.computeShift(state.computed)
  let rw = r.width()
  case state.computed{"word-break"}
  of WORD_BREAK_NORMAL:
    if rw == 2 or state.wrappos != -1: # break on cjk and wrap opportunities
      let plusWidth = state.word.width + shift + rw * state.ictx.cellwidth
      if state.ictx.shouldWrap(plusWidth, nil):
        let l = state.ictx.currentLine
        state.addWordEOL()
        if l == state.ictx.currentLine: # no line wrapping occured in addAtom
          state.ictx.finishLine(state.computed)
          state.ictx.whitespacenum = 0
  of WORD_BREAK_BREAK_ALL:
    let plusWidth = state.word.width + shift + rw * state.ictx.cellwidth
    if state.ictx.shouldWrap(plusWidth, nil):
      let l = state.ictx.currentLine
      state.addWordEOL()
      if l == state.ictx.currentLine: # no line wrapping occured in addAtom
        state.ictx.finishLine(state.computed)
        state.ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    let plusWidth = state.word.width + shift + rw * state.ictx.cellwidth
    if state.ictx.shouldWrap(plusWidth, nil):
      state.ictx.finishLine(state.computed)
      state.ictx.whitespacenum = 0

proc processWhitespace(state: var InlineState, c: char) =
  state.addWord()
  case state.computed{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    state.ictx.whitespacenum = max(state.ictx.whitespacenum, 1)
  of WHITESPACE_PRE_LINE:
    if c == '\n':
      state.ictx.flushLine(state.computed)
    else:
      state.ictx.whitespacenum = max(state.ictx.whitespacenum, 1)
  of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    #TODO whitespace type should be preserved here. (it isn't, because
    # it would break tabs in the current buffer model.)
    if c == '\n':
      state.ictx.flushLine(state.computed)
    elif c == '\t':
      let prev = state.ictx.charwidth
      state.ictx.charwidth = ((state.ictx.charwidth +
        state.ictx.whitespacenum) div 8 + 1) * 8 - state.ictx.whitespacenum
      state.ictx.whitespacenum += state.ictx.charwidth - prev
    else:
      inc state.ictx.whitespacenum

proc layoutText(ictx: InlineContext, str: string, computed: CSSComputedValues, node: StyledNode) =
  var state: InlineState
  state.computed = computed
  state.ictx = ictx
  state.node = node
  state.ictx.flushWhitespace(state.computed)
  state.newWord()

  var i = 0
  while i < str.len:
    if str[i].isWhitespace():
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
        state.word.width += w * state.ictx.cellwidth
        state.ictx.charwidth += w
        if r == Rune('-'): # ascii dash
          state.wrappos = state.word.str.len
          state.hasshy = false

  state.addWord()

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
    viewport: Viewport) =
  let computed = box.computed
  # Note: we use availableWidth for percentage resolution intentionally.
  box.margin_top = computed{"margin-top"}.px(viewport, availableWidth)
  box.margin_bottom = computed{"margin-bottom"}.px(viewport, availableWidth)
  box.margin_left = computed{"margin-left"}.px(viewport, availableWidth)
  box.margin_right = computed{"margin-right"}.px(viewport, availableWidth)

proc resolvePadding(box: BlockBox, availableWidth: SizeConstraint,
    viewport: Viewport) =
  let computed = box.computed
  # Note: we use availableWidth for percentage resolution intentionally.
  box.padding_top = computed{"padding-top"}.px(viewport, availableWidth)
  box.padding_bottom = computed{"padding-bottom"}.px(viewport, availableWidth)
  box.padding_left = computed{"padding-left"}.px(viewport, availableWidth)
  box.padding_right = computed{"padding-right"}.px(viewport, availableWidth)

proc calcAvailableWidth(box: BlockBox, containingWidth: SizeConstraint) =
  let viewport = box.viewport
  let computed = box.computed
  let width = computed{"width"}
  var widthpx: LayoutUnit = 0
  if not width.auto and width.canpx(containingWidth):
    widthpx = width.px(viewport, containingWidth)
    box.availableWidth = stretch(widthpx)
  box.resolveContentWidth(widthpx, containingWidth, width.auto)
  if not computed{"max-width"}.auto:
    let max_width = computed{"max-width"}.px(viewport, containingWidth)
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
    let min_width = computed{"min-width"}.px(viewport, containingWidth)
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
    percHeight: Option[LayoutUnit]) =
  let viewport = box.viewport
  let computed = box.computed
  let height = computed{"height"}
  var heightpx: LayoutUnit = 0
  if not height.auto and height.canpx(percHeight):
    heightpx = height.px(viewport, percHeight).get
    box.availableHeight = stretch(heightpx)
  if not computed{"max-height"}.auto:
    let max_height = computed{"max-height"}.px(viewport, percHeight)
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
    let min_height = computed{"min-height"}.px(viewport, percHeight)
    if min_height.isSome:
      box.min_height = min_height
      if box.availableHeight.t in {STRETCH, FIT_CONTENT} and
          min_height.get > box.availableHeight.u or
          box.availableHeight.t == MIN_CONTENT:
        # same reasoning as for width.
        box.availableHeight = stretch(min_height.get)

proc calcAbsoluteAvailableWidth(box: BlockBox,
    containingWidth: SizeConstraint) =
  let viewport = box.viewport
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let width = box.computed{"width"}
  if width.auto:
    if not left.auto and not right.auto:
      # width is auto and left & right are not auto.
      # Solve for width.
      if containingWidth.isDefinite:
        let leftpx = left.px(viewport, containingWidth)
        let rightpx = right.px(viewport, containingWidth)
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
    let widthpx = width.px(viewport, containingWidth)
    # We could solve for left/right here, as available width is known.
    # Nevertheless, it is only needed for positioning, so we do not solve
    # them yet.
    box.availableWidth = stretch(widthpx)

proc calcAbsoluteAvailableHeight(box: BlockBox,
    containingHeight: SizeConstraint) =
  let viewport = box.viewport
  #TODO this might be incorrect because of percHeight?
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let height = box.computed{"height"}
  if height.auto:
    if not top.auto and not bottom.auto:
      # height is auto and top & bottom are not auto.
      # Solve for height.
      if containingHeight.isDefinite:
        let toppx = top.px(viewport, containingHeight)
        let bottompx = bottom.px(viewport, containingHeight)
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
    let heightpx = height.px(viewport, containingHeight)
    box.availableHeight = stretch(heightpx)

# Calculate and resolve available width & height for absolutely positioned
# boxes.
proc calcAbsoluteAvailableSizes(box: BlockBox) =
  let viewport = box.viewport
  let containingWidth = viewport.positioned[^1].availableWidth
  let containingHeight = viewport.positioned[^1].availableHeight
  box.resolveMargins(containingWidth, viewport)
  box.resolvePadding(containingWidth, viewport)
  box.calcAbsoluteAvailableWidth(containingWidth)
  box.calcAbsoluteAvailableHeight(containingHeight)

# Calculate and resolve available width & height for box children.
# availableWidth: width of the containing box
# availableHeight: ditto, but with height.
# Note that this is not the final content size, just the amount of space
# available for content.
# The percentage width/height is generally
# availableSize.isDefinite() ? availableSize.u : 0, but for some reason it
# differs for the root height (TODO: and all heights in quirks mode) in that
# it uses the viewport height. Therefore we pass percHeight as a separate
# parameter. (TODO surely there is a better solution to this?)
proc calcAvailableSizes(box: BlockBox, containingWidth, containingHeight:
    SizeConstraint, percHeight: Option[LayoutUnit]) =
  let viewport = box.viewport
  if box.computed{"position"} == POSITION_ABSOLUTE:
    box.calcAbsoluteAvailableSizes()
  else:
    box.resolveMargins(containingWidth, viewport)
    box.resolvePadding(containingWidth, viewport)
    # Take defined sizes if our width/height resolves to auto.
    # (For block boxes, this is width: stretch(parentWidth), height: max-content)
    box.availableWidth = containingWidth
    box.availableHeight = containingHeight
    # Finally, calculate available width and height.
    box.calcAvailableWidth(containingWidth)
    box.calcAvailableHeight(containingHeight, percHeight)

proc calcTableCellAvailableSizes(box: BlockBox, availableWidth, availableHeight:
    SizeConstraint) =
  let viewport = box.viewport
  let computed = box.computed
  box.resolvePadding(availableWidth, viewport)
  box.availableWidth = availableWidth
  box.availableHeight = availableHeight

  let width = computed{"width"}
  if not width.auto and width.unit != UNIT_PERC:
    box.availableWidth = stretch(width.px(viewport))
  box.availableWidth.u -= box.padding_left
  box.availableWidth.u -= box.padding_right

  let height = computed{"height"}
  if not height.auto and height.unit != UNIT_PERC:
    box.availableHeight = stretch(height.px(viewport))

proc newTableCellBox(viewport: Viewport, builder: BoxBuilder,
    availableWidth, availableHeight: SizeConstraint): BlockBox =
  let box = BlockBox(
    viewport: viewport,
    computed: builder.computed,
    node: builder.node
  )
  box.calcTableCellAvailableSizes(availableWidth, availableHeight)
  return box

proc newFlowRootBox(viewport: Viewport, builder: BoxBuilder,
    availableWidth, availableHeight: SizeConstraint,
    percHeight: Option[LayoutUnit]): BlockBox =
  let box = BlockBox(
    viewport: viewport,
    computed: builder.computed,
    node: builder.node,
    positioned: builder.computed{"position"} != POSITION_STATIC,
  )
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight)
  return box

func toPercSize(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)
 
func getParentWidth(box, parent: BlockBox): SizeConstraint =
  return parent.availableWidth

func getParentHeight(box, parent: BlockBox): SizeConstraint =
  return parent.availableHeight

proc newBlockBox(parent: BlockBox, builder: BoxBuilder): BlockBox =
  let box = BlockBox(
    viewport: parent.viewport,
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentHeight = box.getParentHeight(parent)
  let availableWidth = box.getParentWidth(parent)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight)
  return box

proc newBlockBoxStretch(parent: BlockBox, builder: BoxBuilder): BlockBox =
  let box = BlockBox(
    viewport: parent.viewport,
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = box.getParentWidth(parent)
  let parentHeight = box.getParentHeight(parent)
  let availableWidth = stretch(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight)
  return box

proc newBlockBoxFit(parent: BlockBox, builder: BoxBuilder): BlockBox =
  let box = BlockBox(
    viewport: parent.viewport,
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = box.getParentWidth(parent)
  let parentHeight = box.getParentHeight(parent)
  let availableWidth = fitContent(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight)
  return box

proc newListItem(parent: BlockBox, builder: ListItemBoxBuilder): ListItemBox =
  let box = ListItemBox(
    viewport: parent.viewport,
    computed: builder.computed,
    positioned: builder.computed{"position"} != POSITION_STATIC,
    node: builder.node
  )
  let parentWidth = box.getParentWidth(parent)
  let parentHeight = box.getParentHeight(parent)
  let availableWidth = stretch(parentWidth)
  let availableHeight = maxContent() #TODO fit-content when clip
  let percHeight = parentHeight.toPercSize()
  box.calcAvailableSizes(availableWidth, availableHeight, percHeight)
  return box

proc newInlineBlock(viewport: Viewport, builder: BoxBuilder,
    parentWidth, parentHeight: SizeConstraint,
    percHeight: Option[LayoutUnit]): InlineBlockBox =
  let box = InlineBlockBox(
    innerbox: newFlowRootBox(viewport, builder, parentWidth,
      maxContent(), percHeight),
    vertalign: builder.computed{"vertical-align"}
  )
  return box

proc newInlineContext(parent: BlockBox): InlineContext =
  return InlineContext(
    currentLine: LineBox(),
    viewport: parent.viewport,
    availableWidth: parent.availableWidth,
    availableHeight: parent.availableHeight
  )

proc buildBlock(builder: BlockBoxBuilder, parent: BlockBox): BlockBox
proc buildInlines(parent: BlockBox, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(parent: BlockBox, blocks: seq[BoxBuilder], node: StyledNode)
proc buildTable(builder: TableBoxBuilder, parent: BlockBox): BlockBox
proc buildTableLayout(table: BlockBox, builder: TableBoxBuilder)

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

# Builder only contains inline boxes.
proc buildInlineLayout(parent: BlockBox, children: seq[BoxBuilder]) =
  parent.inline = parent.buildInlines(children)
  parent.applyInlineDimensions()

# Builder only contains block boxes.
proc buildBlockLayout(box: BlockBox, children: seq[BoxBuilder], node: StyledNode) =
  let positioned = box.computed{"position"} != POSITION_STATIC
  if positioned:
    box.viewport.positioned.add(box)
  box.buildBlocks(children, node)
  if positioned:
    discard box.viewport.positioned.pop()

#TODO this is horribly inefficient, and should be inherited like xminwidth
func firstBaseline(box: BlockBox): LayoutUnit =
  if box.inline != nil:
    if box.inline.lines.len > 0:
      return box.offset.y + box.inline.lines[0].baseline
    return box.offset.y
  if box.nested.len > 0:
    return box.offset.y + box.nested[^1].firstBaseline
  box.offset.y

#TODO ditto
func baseline(box: BlockBox): LayoutUnit =
  if box.inline != nil:
    var y: LayoutUnit = 0
    for line in box.inline.lines:
      if line == box.inline.lines[^1]:
        return box.offset.y + y + line.baseline
      y += line.height
    return box.offset.y + box.height
  if box.nested.len > 0:
    return box.offset.y + box.nested[^1].baseline
  box.offset.y

proc buildLayout(box: BlockBox, builder: BlockBoxBuilder) =
  if builder.inlinelayout:
    box.buildInlineLayout(builder.children)
  else:
    box.buildBlockLayout(builder.children, builder.node)

func toperc100(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

# parentWidth, parentHeight: width/height of the containing block.
proc buildInlineBlock(builder: BlockBoxBuilder, parent: InlineContext,
    parentWidth, parentHeight: SizeConstraint): InlineBlockBox =
  result = newInlineBlock(parent.viewport, builder, fitContent(parentWidth),
    maxContent(), parentHeight.toperc100())

  case builder.computed{"display"}
  of DISPLAY_INLINE_BLOCK:
    result.innerbox.buildLayout(builder)
  of DISPLAY_INLINE_TABLE:
    result.innerbox.buildTableLayout(TableBoxBuilder(builder))
  else:
    assert false, $builder.computed{"display"}

  # Apply the block box's properties to the atom itself.
  result.width = result.innerbox.width
  result.height = result.innerbox.height

  result.margin_top = result.innerbox.margin_top
  result.margin_bottom = result.innerbox.margin_bottom

  result.baseline = result.innerbox.baseline

  # I don't like this, but it works...
  result.offset.x = result.innerbox.margin_left
  result.width += result.innerbox.margin_left
  result.width += result.innerbox.margin_right

proc buildInline(ictx: InlineContext, box: InlineBoxBuilder) =
  if box.newline:
    ictx.flushLine(box.computed)

  let paddingformat = getComputedFormat(box.computed, box.node)
  if box.splitstart:
    let margin_left = box.computed{"margin-left"}.px(ictx.viewport,
      ictx.availableWidth)
    ictx.currentLine.width += margin_left

    let padding_left = box.computed{"padding-left"}.px(ictx.viewport,
      ictx.availableWidth)
    if padding_left > 0:
      # We must add spacing to the line to make sure that it is formatted
      # appropriately.
      # We need this so long as we have no proper inline boxes.
      ictx.currentLine.addPadding(padding_left, ictx.cellheight, paddingformat)

  assert not (box.children.len > 0 and box.text.len > 0)
  for text in box.text:
    ictx.layoutText(text, box.computed, box.node)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      ictx.buildInline(child)
    of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
      let child = BlockBoxBuilder(child)
      let w = fitContent(ictx.availableWidth)
      let h = ictx.availableHeight
      let iblock = child.buildInlineBlock(ictx, w, h)
      ictx.addAtom(iblock, box.computed)
      ictx.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  if box.splitend:
    let padding_right = box.computed{"padding-right"}.px(ictx.viewport,
      ictx.availableWidth)
    ictx.currentLine.width += padding_right
    if padding_right > 0:
      ictx.currentLine.addPadding(padding_right,
        max(ictx.currentLine.height, 1), paddingformat)
    let margin_right = box.computed{"margin-right"}.px(ictx.viewport,
      ictx.availableWidth)
    ictx.currentLine.width += margin_right

proc buildInlines(parent: BlockBox, inlines: seq[BoxBuilder]): InlineContext =
  let ictx = parent.newInlineContext()
  if inlines.len > 0:
    for child in inlines:
      case child.computed{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        ictx.buildInline(child)
      of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
        #TODO wtf
        let child = BlockBoxBuilder(child)
        let w = fitContent(ictx.availableWidth)
        let h = ictx.availableHeight
        let iblock = child.buildInlineBlock(ictx, w, h)
        ictx.addAtom(iblock, parent.computed)
        ictx.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    ictx.finish(parent.computed)
  return ictx

proc buildMarker(builder: MarkerBoxBuilder, parent: BlockBox): InlineContext =
  let ictx = parent.newInlineContext()
  ictx.availableWidth = fitContent(ictx.availableWidth)
  ictx.buildInline(builder)
  ictx.finish(builder.computed)
  return ictx

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockBox): ListItemBox =
  result = parent.newListItem(builder)
  if builder.marker != nil:
    result.marker = buildMarker(builder.marker, result)
  result.buildLayout(builder.content)

proc positionAbsolute(box: BlockBox) =
  let viewport = box.viewport
  let last = viewport.positioned[^1]
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  let parentWidth = applySizeConstraint(viewport.window.width_px,
    last.availableWidth)
  let parentHeight = applySizeConstraint(viewport.window.height_px,
    last.availableHeight)
  box.x_positioned = not (left.auto and right.auto)
  box.y_positioned = not (top.auto and bottom.auto)
  if not left.auto:
    box.offset.x += left.px(viewport, parentWidth)
    box.offset.x += box.margin_left
  elif not right.auto:
    box.offset.x += parentWidth - right.px(viewport, parentWidth) - box.width
    box.offset.x -= box.margin_right
  if not top.auto:
    box.offset.y += top.px(viewport, parentHeight)
    box.offset.y += box.margin_top
  elif not bottom.auto:
    box.offset.y += parentHeight - bottom.px(viewport, parentHeight) - box.height
    box.offset.y -= box.margin_bottom

proc positionRelative(parent, box: BlockBox) =
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  if not left.auto:
    box.offset.x += right.px(parent.viewport)
  elif not right.auto:
    box.offset.x += parent.width - right.px(parent.viewport) - box.width
  if not top.auto:
    box.offset.y += top.px(parent.viewport)
  elif not top.auto:
    box.offset.y -= parent.height - bottom.px(parent.viewport) - box.height

proc applyChildPosition(parent, child: BlockBox, x, y: var LayoutUnit,
    margin_todo: var Strut, maxChildWidth, childHeight: var LayoutUnit) =
  if child.computed{"position"} == POSITION_ABSOLUTE: #TODO sticky, fixed
    if child.computed{"left"}.auto and child.computed{"right"}.auto:
      child.offset.x = x
    if child.computed{"top"}.auto and child.computed{"bottom"}.auto:
      child.offset.y = y + margin_todo.sum()
    child.offset.y += child.margin_top
  else:
    child.offset.y = y
    child.offset.x = x
    y += child.height
    childHeight += child.height
    maxChildWidth = max(maxChildWidth, child.width)
    parent.xminwidth = max(parent.xminwidth, child.xminwidth)
    margin_todo = Strut()
    margin_todo.append(child.margin_bottom)

proc postAlignChild(box, child: BlockBox, width: LayoutUnit) =
  case box.computed{"text-align"}
  of TEXT_ALIGN_CHA_CENTER:
    child.offset.x += max(width div 2 - child.width div 2, 0)
  of TEXT_ALIGN_CHA_LEFT: discard
  of TEXT_ALIGN_CHA_RIGHT:
    child.offset.x += max(width - child.width, 0)
  else:
    child.offset.x += child.margin_left

proc positionBlocks(box: BlockBox) =
  var y: LayoutUnit = 0
  var x: LayoutUnit = 0
  var maxChildWidth: LayoutUnit
  var childHeight: LayoutUnit
  var margin_todo: Strut

  y += box.padding_top
  childHeight += box.padding_top
  x += box.padding_left

  var i = 0
  while i < box.nested.len:
    let child = box.nested[i]
    if child.computed{"position"} != POSITION_ABSOLUTE:
      break
    applyChildPosition(box, child, x, y, margin_todo, maxChildWidth,
      childHeight)
    inc i

  if i < box.nested.len:
    let child = box.nested[i]
    margin_todo.append(box.margin_top)
    margin_todo.append(child.margin_top)
    box.margin_top = margin_todo.sum()
    applyChildPosition(box, child, x, y, margin_todo, maxChildWidth,
      childHeight)
    inc i

  while i < box.nested.len:
    let child = box.nested[i]
    if child.computed{"position"} != POSITION_ABSOLUTE:
      margin_todo.append(child.margin_top)
      y += margin_todo.sum()
      childHeight += margin_todo.sum()
    applyChildPosition(box, child, x, y, margin_todo, maxChildWidth,
      childHeight)
    inc i

  margin_todo.append(box.margin_bottom)
  box.margin_bottom = margin_todo.sum()

  box.applyWidth(maxChildWidth)

  # Re-position the children.
  # The x offset for values in shrink mode depends on the parent box's
  # width, so we cannot do this in the first pass.
  let width = box.width
  for child in box.nested:
    if child.computed{"position"} != POSITION_ABSOLUTE:
      box.postAlignChild(child, width)
    case child.computed{"position"}
    of POSITION_RELATIVE:
      box.positionRelative(child)
    of POSITION_ABSOLUTE:
      positionAbsolute(child)
    else: discard #TODO

  # Finally, add padding. (We cannot do this further up without influencing
  # positioning.)
  box.width += box.padding_left
  box.width += box.padding_right

  childHeight += box.padding_bottom

  box.height = applySizeConstraint(childHeight, box.availableHeight)
  if box.max_height.isSome and box.height > box.max_height.get:
    box.height = box.max_height.get
  if box.min_height.isSome and box.height < box.min_height.get:
    box.height = box.min_height.get

proc buildTableCaption(viewport: Viewport, builder: TableCaptionBoxBuilder,
    availableWidth, availableHeight: SizeConstraint): BlockBox =
  let w = availableWidth
  let h = maxContent()
  let ph = availableHeight.toperc100()
  let box = viewport.newFlowRootBox(builder, w, h, ph)
  box.buildLayout(builder)
  return box

proc buildTableCell(viewport: Viewport, builder: TableCellBoxBuilder,
    availableWidth, availableHeight: SizeConstraint): BlockBox =
  let tableCell = viewport.newTableCellBox(builder, availableWidth,
    availableHeight)
  tableCell.buildLayout(builder)
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
      stretch(computedWidth.px(parent.viewport, 0))
    else:
      maxContent()
    #TODO specified table height should be distributed among rows.
    let box = parent.viewport.buildTableCell(cellbuilder, cw, maxContent())
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
      pctx.cols[i].maxwidth = w
      if pctx.cols[i].width < w:
        pctx.cols[i].width = w
        if ctx.reflow.len <= i: ctx.reflow.setLen(i + 1)
        ctx.reflow[i] = true
      if not computedWidth.auto and computedWidth.unit != UNIT_PERC:
        let ww = computedWidth.px(parent.viewport)
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
  let row = newBlockBoxStretch(parent, builder)
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
      cellw.box = parent.viewport.buildTableCell(cellw.builder, stretch(w),
        maxContent())
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
  case ctx.caption.computed{"caption-side"}
  of CAPTION_SIDE_TOP, CAPTION_SIDE_BLOCK_START:
    let caption = table.viewport.buildTableCaption(ctx.caption,
      stretch(table.width), maxContent())
    for r in table.nested:
      r.offset.y += caption.height
    table.nested.insert(caption, 0)
    table.height += caption.height
    table.width = max(table.width, caption.width)
  of CAPTION_SIDE_BOTTOM, CAPTION_SIDE_BLOCK_END:
    let caption = table.viewport.buildTableCaption(ctx.caption,
      stretch(table.width), maxContent())
    caption.offset.y += table.width
    table.nested.add(caption)
    table.height += caption.height
    table.width = max(table.width, caption.width)
  of CAPTION_SIDE_LEFT, CAPTION_SIDE_INLINE_START:
    let caption = table.viewport.buildTableCaption(ctx.caption,
      fitContent(table.availableWidth), fitContent(table.height))
    for r in table.nested:
      r.offset.x += caption.width
    table.nested.insert(caption, 0)
    table.width += caption.width
    table.height = max(table.height, caption.height)
  of CAPTION_SIDE_RIGHT, CAPTION_SIDE_INLINE_END:
    let caption = table.viewport.buildTableCaption(ctx.caption,
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
proc buildTableLayout(table: BlockBox, builder: TableBoxBuilder) =
  let collapse = table.computed{"border-collapse"} == BORDER_COLLAPSE_COLLAPSE
  var ctx = TableContext(collapse: collapse)
  if not ctx.collapse:
    ctx.inlinespacing = table.computed{"border-spacing"}.a.px(table.viewport)
    ctx.blockspacing = table.computed{"border-spacing"}.b.px(table.viewport)
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

proc buildTable(builder: TableBoxBuilder, parent: BlockBox): BlockBox =
  let table = parent.newBlockBoxFit(builder)
  table.buildTableLayout(builder)
  return table

proc buildBlocks(parent: BlockBox, blocks: seq[BoxBuilder], node: StyledNode) =
  for child in blocks:
    var cblock: BlockBox
    case child.computed{"display"}
    of DISPLAY_BLOCK: cblock = buildBlock(BlockBoxBuilder(child), parent)
    of DISPLAY_LIST_ITEM: cblock = buildListItem(ListItemBoxBuilder(child), parent)
    of DISPLAY_TABLE: cblock = buildTable(TableBoxBuilder(child), parent)
    else: assert false, "child.t is " & $child.computed{"display"}
    parent.nested.add(cblock)
  parent.positionBlocks()

# Build a block box inside another block box, based on a builder.
proc buildBlock(builder: BlockBoxBuilder, parent: BlockBox): BlockBox =
  let box = parent.newBlockBox(builder)
  box.buildLayout(builder)
  return box

# Establish a new flow-root context and build a block box.
proc buildRootBlock(viewport: Viewport, builder: BlockBoxBuilder): BlockBox =
  let w = stretch(viewport.window.width_px)
  let h = maxContent()
  let vh: LayoutUnit = viewport.window.height_px
  let box = viewport.newFlowRootBox(builder, w, h, some(vh))
  viewport.positioned.add(box)
  box.buildLayout(builder)
  # Normally margin-top would be used by positionBlock, but the root block
  # doesn't get positioned by the parent, so we have to do it manually here.
  #TODO this is kind of ugly.
  box.offset.y += box.margin_top
  return box

# Generation phase

# Returns a block box, disregarding the computed value of display
proc getBlockBox(computed: CSSComputedValues): BlockBoxBuilder =
  new(result)
  result.computed = computed

proc getTextBox(computed: CSSComputedValues): InlineBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = computed

proc getMarkerBox(computed: CSSComputedValues, listItemCounter: int): MarkerBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = computed.inheritProperties()
  result.computed{"display"} = DISPLAY_INLINE
  # Use pre, so the space at the end of the default markers isn't ignored.
  result.computed{"white-space"} = WHITESPACE_PRE
  result.text.add(computed{"list-style-type"}.listMarker(listItemCounter))

proc getListItemBox(computed: CSSComputedValues, listItemCounter: int): ListItemBoxBuilder =
  new(result)
  result.computed = computed
  result.marker = getMarkerBox(computed, listItemCounter)

proc getTableBox(computed: CSSComputedValues): TableBoxBuilder =
  new(result)
  result.computed = computed

# Also known as <tbody>.
proc getTableRowGroupBox(computed: CSSComputedValues): TableRowGroupBoxBuilder =
  new(result)
  result.computed = computed

proc getTableRowBox(computed: CSSComputedValues): TableRowBoxBuilder =
  new(result)
  result.computed = computed

# For <th> and <td>.
proc getTableCellBox(computed: CSSComputedValues): TableCellBoxBuilder =
  new(result)
  result.computed = computed

proc getTableCaptionBox(computed: CSSComputedValues): TableCaptionBoxBuilder =
  new(result)
  result.computed = computed

type BlockGroup = object
  parent: BoxBuilder
  boxes: seq[BoxBuilder]

type InnerBlockContext = object
  styledNode: StyledNode
  blockgroup: BlockGroup
  viewport: Viewport
  ibox: InlineBoxBuilder
  anonRow: TableRowBoxBuilder
  anonTable: TableBoxBuilder
  quoteLevel: int
  listItemCounter: int
  listItemReset: bool
  parent: ptr InnerBlockContext

proc add(blockgroup: var BlockGroup, box: BoxBuilder) {.inline.} =
  assert box.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_TABLE, DISPLAY_INLINE_BLOCK}, $box.computed{"display"}
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
func canGenerateAnonymousInline(blockgroup: BlockGroup, computed: CSSComputedValues, str: string): bool =
  return blockgroup.boxes.len > 0 and blockgroup.boxes[^1].computed{"display"} == DISPLAY_INLINE or
    computed.whitespacepre or not str.onlyWhitespace()

proc iflush(blockgroup: var BlockGroup, ibox: var InlineBoxBuilder) =
  if ibox != nil:
    assert ibox.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE}
    blockgroup.add(ibox)
    ibox = nil

proc newBlockGroup(parent: BoxBuilder): BlockGroup =
  assert parent.computed{"display"} != DISPLAY_INLINE
  result.parent = parent

proc generateTableBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableBoxBuilder
proc generateTableRowGroupBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableRowGroupBoxBuilder
proc generateTableRowBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableRowBoxBuilder
proc generateTableCellBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableCellBoxBuilder
proc generateTableCaptionBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableCaptionBoxBuilder
proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil): BlockBoxBuilder
proc generateInlineBoxes(ctx: var InnerBlockContext, styledNode: StyledNode)

proc generateBlockBox(pctx: var InnerBlockContext, styledNode: StyledNode, marker = none(MarkerBoxBuilder)): BlockBoxBuilder =
  return generateBlockBox(styledNode, pctx.viewport, marker, addr pctx)

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
  ctx.blockgroup.iflush(ctx.ibox)

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
    let childbox = styledNode.generateTableBox(ctx.viewport, ctx)
    box.children.add(childbox)
  of DISPLAY_TABLE_ROW:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowBox(ctx.viewport, ctx)
    if box.computed{"display"} in ProperTableRowParent:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = getTableBox(wrappervals)
      ctx.anonTable.children.add(childbox)
  of DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP, DISPLAY_TABLE_FOOTER_GROUP:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableRowGroupBox(ctx.viewport, ctx)
    if box.computed{"display"} in {DISPLAY_TABLE, DISPLAY_INLINE_TABLE}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = getTableBox(wrappervals)
  of DISPLAY_TABLE_CELL:
    ctx.bflush()
    let childbox = styledNode.generateTableCellBox(ctx.viewport, ctx)
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
    let childbox = styledNode.generateTableBox(ctx.viewport, ctx)
    ctx.blockgroup.add(childbox)
  of DISPLAY_TABLE_CAPTION:
    ctx.bflush()
    ctx.flushTableRow()
    let childbox = styledNode.generateTableCaptionBox(ctx.viewport, ctx)
    if box.computed{"display"} in {DISPLAY_TABLE, DISPLAY_INLINE_TABLE}:
      box.children.add(childbox)
    else:
      if ctx.anonTable == nil:
        var wrappervals = box.computed.inheritProperties()
        #TODO make this an inline-table if we're in an inline context
        wrappervals{"display"} = DISPLAY_TABLE
        ctx.anonTable = getTableBox(wrappervals)
  of DISPLAY_TABLE_COLUMN:
    discard #TODO
  of DISPLAY_TABLE_COLUMN_GROUP:
    discard #TODO
  of DISPLAY_NONE: discard

proc generateAnonymousInlineText(ctx: var InnerBlockContext, text: string, styledNode: StyledNode) =
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

proc newInnerBlockContext(styledNode: StyledNode, box: BoxBuilder, viewport: Viewport, parent: ptr InnerBlockContext): InnerBlockContext =
  result = InnerBlockContext(
    styledNode: styledNode,
    blockgroup: newBlockGroup(box),
    viewport: viewport,
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

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil): BlockBoxBuilder =
  let box = getBlockBox(styledNode.computed)
  box.node = styledNode
  var ctx = newInnerBlockContext(styledNode, box, viewport, parent)

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

proc generateTableCellBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableCellBoxBuilder =
  let box = getTableCellBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, addr parent)
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

proc generateTableRowBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableRowBoxBuilder =
  let box = getTableRowBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, addr parent)
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

proc generateTableRowGroupBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableRowGroupBoxBuilder =
  let box = getTableRowGroupBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableRowGroupChildWrappers()
  return box

proc generateTableCaptionBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableCaptionBoxBuilder =
  let box = getTableCaptionBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, addr parent)
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

proc generateTableBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableBoxBuilder =
  let box = getTableBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, addr parent)
  ctx.generateInnerBlockBox()
  ctx.flush()
  box.generateTableChildWrappers()
  return box

proc renderLayout*(viewport: var Viewport, root: StyledNode): BlockBox =
  viewport.positioned.setLen(0)
  let builder = root.generateBlockBox(viewport)
  return viewport.buildRootBlock(builder)
