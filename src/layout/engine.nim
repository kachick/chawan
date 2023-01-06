import math
import options
import strutils
import tables
import unicode

import css/stylednode
import css/values
import io/window
import layout/box
import types/color
import utils/twtstr

# Build phase
func px(l: CSSLength, viewport: Viewport, p = 0): int {.inline.} =
  return px(l, viewport.window, p)

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

func cellwidth(viewport: Viewport): int {.inline.} =
  viewport.window.ppc

func cellwidth(ictx: InlineContext): int {.inline.} =
  ictx.viewport.cellwidth

func cellheight(viewport: Viewport): int {.inline.} =
  viewport.window.ppl

func cellheight(ictx: InlineContext): int {.inline.} =
  ictx.viewport.cellheight

# Whitespace between words
func computeShift(ictx: InlineContext, computed: CSSComputedValues): int =
  if ictx.whitespacenum > 0:
    if ictx.currentLine.atoms.len > 0 or computed.whitespacepre:
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

proc horizontalAlignLine(ictx: InlineContext, line: LineBox, computed: CSSComputedValues, last = false) =
  let width = if ictx.shrink:
    min(ictx.width, ictx.contentWidth)
  else:
    max(ictx.width, ictx.contentWidth)
  # we don't support directions for now so left = start and right = end
  case computed{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT, TEXT_ALIGN_CHA_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CHA_RIGHT:
    # move everything
    let x = max(width, line.width) - line.width
    for atom in line.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_CENTER, TEXT_ALIGN_CHA_CENTER:
    let x = max((max(width - line.offset.x, line.width)) div 2 - line.width div 2, 0)
    for atom in line.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_JUSTIFY:
    if not computed.whitespacepre and not last:
      var sumwidth = 0
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
  ictx.width = max(width, ictx.width)

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
  var margin_top = 0
  var margin_bottom = 0

  for atom in line.atoms:
    if atom of InlineBlockBox:
      let atom = InlineBlockBox(atom)
      margin_top = max(atom.margin_top, margin_top)
      margin_bottom = max(atom.margin_bottom, margin_bottom)

  for atom in line.atoms:
    atom.offset.y += margin_top

  line.height += margin_top
  line.height += margin_bottom

proc addSpacing(line: LineBox, width, height: int, format: ComputedFormat, hang = false) =
  let spacing = InlineSpacing(width: width, height: height, baseline: height, format: format)
  spacing.offset.x = line.width
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    line.width += spacing.width
  line.atoms.add(spacing)

proc flushWhitespace(ictx: InlineContext, computed: CSSComputedValues, hang = false) =
  let shift = ictx.computeShift(computed)
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format, hang)

proc finishLine(ictx: InlineContext, computed: CSSComputedValues, force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    ictx.charwidth = 0
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

proc finish(ictx: InlineContext, computed: CSSComputedValues) =
  ictx.finishLine(computed)
  for line in ictx.lines:
    ictx.horizontalAlignLine(line, computed, line == ictx.lines[^1])

func minwidth(atom: InlineAtom): int =
  if atom of InlineBlockBox:
    return cast[InlineBlockBox](atom).innerbox.xminwidth
  return atom.width

# pcomputed: computed values of parent, for white-space: pre, line-height.
# This isn't necessarily the computed of ictx (e.g. they may differ for nested
# inline boxes.)
proc addAtom(ictx: InlineContext, atom: InlineAtom, pcomputed: CSSComputedValues) =
  var shift = ictx.computeShift(pcomputed)
  ictx.whitespacenum = 0
  # Line wrapping
  if not pcomputed.nowrap:
    if ictx.currentLine.width + atom.width + shift > ictx.maxContentWidth:
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
  if state.computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  let shift = state.ictx.computeShift(state.computed)
  let rw = r.width()
  case state.computed{"word-break"}
  of WORD_BREAK_NORMAL:
    if rw == 2 or state.wrappos != -1: # break on cjk and wrap opportunities
      if state.ictx.currentLine.width + state.word.width + shift + rw * state.ictx.cellwidth > state.ictx.maxContentWidth:
        let l = state.ictx.currentLine
        state.addWordEOL()
        if l == state.ictx.currentLine: # no line wrapping occured in addAtom
          state.ictx.finishLine(state.computed)
          state.ictx.whitespacenum = 0
  of WORD_BREAK_BREAK_ALL:
    if state.ictx.currentLine.width + state.word.width + shift + rw * state.ictx.cellwidth > state.ictx.maxContentWidth:
      let l = state.ictx.currentLine
      state.addWordEOL()
      if l == state.ictx.currentLine: # no line wrapping occured in addAtom
        state.ictx.finishLine(state.computed)
        state.ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    if state.ictx.currentLine.width + state.word.width + shift + rw * state.ictx.cellwidth > state.ictx.maxContentWidth:
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
    if c == '\n':
      state.ictx.flushLine(state.computed)
    elif c == '\t':
      state.ictx.charwidth = ((state.ictx.charwidth div 8) + 1) * 8
      state.word.str &= c
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

# ...something like this? (I'm pretty sure this is incorrect, TODO.)
proc resolveContentWidth(box: BlockBox, availableWidth: int) =
  if box.contentWidth >= availableWidth:
    box.contentWidth -= box.margin_left
    box.contentWidth -= box.margin_right
    box.contentWidth -= box.padding_left
    box.contentWidth -= box.padding_right
    if box.contentWidth < 0:
      box.contentWidth = 0

# Resolve percentage-based dimensions.
# availableWidth: width of the containing box. availableHeight: ditto, but with height.
proc resolveDimensions(box: BlockBox, availableWidth: int, availableHeight: Option[int], maxContentWidth: Option[int]) =
  let viewport = box.viewport
  let computed = box.computed

  # Note: we use availableWidth for percentage resolution intentionally.
  box.margin_top = computed{"margin-top"}.px(viewport, availableWidth)
  box.margin_bottom = computed{"margin-top"}.px(viewport, availableWidth)
  box.margin_left = computed{"margin-left"}.px(viewport, availableWidth)
  box.margin_right = computed{"margin-right"}.px(viewport, availableWidth)

  box.padding_top = computed{"padding-top"}.px(viewport, availableWidth)
  box.padding_bottom = computed{"padding-bottom"}.px(viewport, availableWidth)
  box.padding_left = computed{"padding-left"}.px(viewport, availableWidth)
  box.padding_right = computed{"padding-right"}.px(viewport, availableWidth)

  # Width
  if computed{"width"}.auto:
    box.contentWidth = availableWidth
  else:
    box.contentWidth = computed{"width"}.px(viewport, availableWidth)
  box.resolveContentWidth(availableWidth)
  # this looks wrong too, TODO...
  if not computed{"max-width"}.auto:
    let maxWidth = computed{"max-width"}.px(viewport, availableWidth)
    if maxWidth < box.contentWidth:
      box.contentWidth = maxWidth
      box.resolveContentWidth(availableWidth)
  if not computed{"min-width"}.auto:
    let minWidth = computed{"min-width"}.px(viewport, availableWidth)
    if minWidth < box.contentWidth:
      box.contentWidth = minWidth
      box.resolveContentWidth(availableWidth)

  # Height
  let pheight = computed{"height"}
  if not pheight.auto:
    if pheight.unit != UNIT_PERC:
      box.contentHeight = some(pheight.px(viewport))
    elif availableHeight.isSome:
      box.contentHeight = some(pheight.px(viewport, availableHeight.get))
  if not computed{"max-height"}.auto:
    if computed{"max-height"}.unit != UNIT_PERC:
      let maxHeight = computed{"max-height"}.px(viewport)
      if box.contentHeight.isNone or maxHeight > box.contentHeight.get:
        box.contentHeight = some(maxHeight)
    elif availableHeight.isSome:
      let maxHeight = computed{"max-height"}.px(viewport, availableHeight.get)
      if box.contentHeight.isNone or maxHeight > box.contentHeight.get:
        box.contentHeight = some(maxHeight)
  if not computed{"min-height"}.auto:
    if computed{"min-height"}.unit != UNIT_PERC:
      let minHeight = computed{"min-height"}.px(viewport)
      if minHeight < box.contentHeight.get(0):
        box.contentHeight = some(minHeight)
    elif availableHeight.isSome:
      let minHeight = computed{"min-height"}.px(viewport, availableHeight.get)
      if minHeight < box.contentHeight.get(0):
        box.contentHeight = some(minHeight)
  # if no max content width is supplied, just use regular content width.
  box.maxContentWidth = maxContentWidth.get(box.contentWidth)

proc resolveTableCellDimensions(box: BlockBox, availableWidth: int, availableHeight: Option[int], maxContentWidth: Option[int]) =
  let viewport = box.viewport
  let computed = box.computed

  # Note: we use availableWidth for percentage resolution intentionally.
  box.padding_top = computed{"padding-top"}.px(viewport, availableWidth)
  box.padding_bottom = computed{"padding-bottom"}.px(viewport, availableWidth)
  box.padding_left = computed{"padding-left"}.px(viewport, availableWidth)
  box.padding_right = computed{"padding-right"}.px(viewport, availableWidth)

  # Width
  let width = computed{"width"}
  if width.auto or width.unit == UNIT_PERC:
    box.contentWidth = availableWidth
  else:
    box.contentWidth = computed{"width"}.px(viewport)
  box.contentWidth -= box.padding_left
  box.contentWidth -= box.padding_right

  # Height
  let pheight = computed{"height"}
  if not pheight.auto and pheight.unit != UNIT_PERC:
    box.contentHeight = some(pheight.px(viewport))
  # if no max content width is supplied, just use regular content width.
  box.maxContentWidth = maxContentWidth.get(box.contentWidth)


# Whether a width was specified on this block box.
func isWidthSpecified(box: BlockBox): bool =
  if box.computed{"display"} == DISPLAY_TABLE_CELL:
    return (not box.computed{"width"}.auto) and box.computed{"width"}.unit != UNIT_PERC
  return not (box.computed{"width"}.auto and box.computed{"max-width"}.auto and
     box.computed{"min-width"}.auto)

# The shrink variable specifies whether a block's inner layout should use all
# available space or not. When shrink is set to false, (currently) the
# following two things happen:
# * The horizontal line alignment algorithm uses the specified width instead
#   of the available width. Obviously, if this is zero, it does nothing.
# * Block boxes use up at most as much space as their contents do.
func isShrink(box: BlockBox, parent: BlockBox = nil, override = false): bool =
  if box.computed{"position"} == POSITION_ABSOLUTE:
    # Absolutely positioned elements take up as much space as their contents.
    return true
  case box.computed{"display"}
  of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
    # Inline blocks/tables always take up as much space as their contents.
    return not box.isWidthSpecified()
  of DISPLAY_TABLE_CELL:
    if box.isWidthSpecified():
      return false
    return override
  of DISPLAY_TABLE:
    return box.computed{"width"}.auto
  of DISPLAY_BLOCK, DISPLAY_TABLE_ROW,
     DISPLAY_TABLE_CAPTION, DISPLAY_LIST_ITEM:
    if parent == nil:
      # We're in a new block formatting context; we can take up all available
      # space we want.
      return override
    else:
      # Basically, check if our block formatting context has infinite width.
      # If yes, there's no need to shrink anyways; we can take up all available
      # space we want.
      # If not, and no width was specified, we have to enable shrink.
      return parent.shrink and not box.isWidthSpecified()
  else: discard

proc newTableCellBox(viewport: Viewport, builder: BoxBuilder, parentWidth: int, parentHeight = none(int), shrink = true, maxContentWidth = none(int)): BlockBox {.inline.} =
  let box = BlockBox(
    viewport: viewport,
    computed: builder.computed,
    node: builder.node
  )
  box.shrink = box.isShrink(nil, shrink)
  box.resolveTableCellDimensions(parentWidth, parentHeight, maxContentWidth)
  return box

proc newFlowRootBox(viewport: Viewport, builder: BoxBuilder, parentWidth: int, parentHeight = none(int), shrink = true, maxContentWidth = none(int)): BlockBox {.inline.} =
  new(result)
  result.viewport = viewport
  result.computed = builder.computed
  result.resolveDimensions(parentWidth, parentHeight, maxContentWidth)
  result.node = builder.node
  result.shrink = result.isShrink(nil, shrink)

proc newBlockBox(parent: BlockBox, builder: BoxBuilder): BlockBox =
  new(result)
  result.viewport = parent.viewport
  result.computed = builder.computed
  result.shrink = result.isShrink(parent)
  let maxContentWidth = if result.shrink:
    some(parent.maxContentWidth)
  else:
    none(int)
  result.resolveDimensions(parent.contentWidth, parent.contentHeight, maxContentWidth)
  result.node = builder.node

proc newListItem(parent: BlockBox, builder: ListItemBoxBuilder): ListItemBox =
  new(result)
  result.viewport = parent.viewport
  result.computed = builder.content.computed
  result.shrink = result.isShrink(parent)
  let maxContentWidth = if result.shrink:
    some(parent.maxContentWidth)
  else:
    none(int)
  result.resolveDimensions(parent.contentWidth, parent.contentHeight, maxContentWidth)
  result.node = builder.node

proc newInlineBlock(viewport: Viewport, builder: BoxBuilder, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  new(result)
  result.innerbox = newFlowRootBox(viewport, builder, parentWidth, parentHeight)
  result.vertalign = builder.computed{"vertical-align"}

proc newInlineContext(parent: BlockBox): InlineContext =
  return InlineContext(
    currentLine: LineBox(),
    viewport: parent.viewport,
    shrink: parent.shrink,
    contentHeight: parent.contentHeight,
    contentWidth: parent.contentWidth,
    maxContentWidth: parent.maxContentWidth
  )

proc buildBlock(builder: BlockBoxBuilder, parent: BlockBox): BlockBox
proc buildInlines(parent: BlockBox, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(parent: BlockBox, blocks: seq[BoxBuilder], node: StyledNode)
proc buildTable(builder: TableBoxBuilder, parent: BlockBox): BlockBox
proc buildTableLayout(table: BlockBox, builder: TableBoxBuilder)

proc applyInlineDimensions(box: BlockBox) =
  box.height += box.inline.height
  if box.contentHeight.isSome:
    box.height = box.contentHeight.get
  box.width = max(box.width, box.inline.width)
  box.xminwidth = max(box.xminwidth, box.inline.minwidth)

proc positionInlines(box: BlockBox) =
  box.width += box.padding_left
  box.inline.offset.x += box.padding_left

  box.height += box.padding_top
  box.inline.offset.y += box.padding_top

  box.height += box.padding_bottom

  box.width += box.padding_right

  if not box.isWidthSpecified():
    # We can make the box as small/large as the content's width.
    if box.shrink:
      box.width = min(box.width, box.maxContentWidth)
    else:
      box.width = max(box.width, box.contentWidth)
  else:
    box.width = box.contentWidth

# Builder only contains inline boxes.
proc buildInlineLayout(parent: BlockBox, children: seq[BoxBuilder]) =
  parent.inline = parent.buildInlines(children)
  parent.applyInlineDimensions()
  parent.positionInlines()

# Builder only contains block boxes.
proc buildBlockLayout(parent: BlockBox, children: seq[BoxBuilder], node: StyledNode) =
  if parent.computed{"position"} == POSITION_ABSOLUTE:
    parent.viewport.absolutes.add(parent)
  parent.buildBlocks(children, node)
  if parent.computed{"position"} == POSITION_ABSOLUTE:
    discard parent.viewport.absolutes.pop()

#TODO this is horribly inefficient, and should be inherited like xminwidth
func firstBaseline(box: BlockBox): int =
  if box.inline != nil:
    if box.inline.lines.len > 0:
      return box.offset.y + box.inline.lines[0].baseline
    return box.offset.y
  if box.nested.len > 0:
    return box.offset.y + box.nested[^1].firstBaseline
  box.offset.y

#TODO ditto
func baseline(box: BlockBox): int =
  if box.inline != nil:
    var y = 0
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

# parentWidth, parentHeight: width/height of the containing block.
proc buildInlineBlock(builder: BlockBoxBuilder, parent: InlineContext, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  result = newInlineBlock(parent.viewport, builder, parentWidth)

  case builder.computed{"display"}
  of DISPLAY_INLINE_BLOCK:
    result.innerbox.buildLayout(builder)
  of DISPLAY_INLINE_TABLE:
    result.innerbox.buildTableLayout(TableBoxBuilder(builder))
  else:
    assert false, $builder.computed{"display"}

  if not result.innerbox.isWidthSpecified():
    # shrink-to-fit
    result.innerbox.width = min(parentWidth, result.innerbox.width)

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
    let margin_left = box.computed{"margin-left"}.px(ictx.viewport, ictx.contentWidth)
    ictx.currentLine.width += margin_left

    let padding_left = box.computed{"padding-left"}.px(ictx.viewport, ictx.contentWidth)
    if padding_left > 0:
      ictx.currentLine.addSpacing(padding_left, ictx.cellheight, paddingformat)

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
      let iblock = child.buildInlineBlock(ictx, ictx.contentWidth, ictx.contentHeight)
      ictx.addAtom(iblock, box.computed)
      ictx.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  if box.splitend:
    let padding_right = box.computed{"padding-right"}.px(ictx.viewport, ictx.contentWidth)
    if padding_right > 0:
      ictx.currentLine.addSpacing(padding_right, max(ictx.currentLine.height, 1), paddingformat)
    let margin_right = box.computed{"margin-right"}.px(ictx.viewport, ictx.contentWidth)
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
        let child = BlockBoxBuilder(child)
        let iblock = child.buildInlineBlock(ictx, ictx.contentWidth, ictx.contentHeight)
        ictx.addAtom(iblock, parent.computed)
        ictx.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    ictx.finish(parent.computed)
  return ictx

proc buildMarker(builder: MarkerBoxBuilder, parent: BlockBox): InlineContext =
  let ictx = parent.newInlineContext()
  ictx.shrink = true
  ictx.buildInline(builder)
  ictx.finish(builder.computed)
  return ictx

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockBox): ListItemBox =
  result = parent.newListItem(builder)
  if builder.marker != nil:
    result.marker = buildMarker(builder.marker, result)
  result.buildLayout(builder.content)

proc positionFixed(box: BlockBox, last: BlockBox = box.viewport.root[0]) =
  #TODO for now this is a good approximation, but fixed actually means
  # something completely different...
  box.offset.x += last.offset.x
  box.offset.y += last.offset.y
  #TODO TODO TODO subtract these from width/height
  let left = box.computed{"left"}
  let right = box.computed{"right"}
  let top = box.computed{"top"}
  let bottom = box.computed{"bottom"}
  if not left.auto:
    box.offset.x += left.px(box.viewport, last.contentWidth)
    box.offset.x += box.margin_left
  elif not right.auto:
    box.offset.x += last.contentWidth - right.px(box.viewport, box.contentWidth) - box.width
    box.offset.x -= box.margin_right
  if not top.auto:
    box.offset.y += top.px(box.viewport, box.contentHeight.get(0))
    box.offset.y += box.margin_top
  elif not bottom.auto:
    box.offset.y += last.contentHeight.get(box.viewport.window.height_px) - bottom.px(box.viewport, box.contentHeight.get(0)) - box.height
    box.offset.y -= box.margin_bottom
  box.viewport.root.add(box)

proc positionAbsolute(box: BlockBox) =
  let last = if box.viewport.absolutes.len > 0:
    box.viewport.absolutes[^1]
  else:
    box.viewport.root[0]
  box.positionFixed(last)

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

proc positionBlocks(box: BlockBox) =
  var y = 0
  var x = 0
  var margin_todo: Strut

  # If content width has been specified, use it.
  # Otherwise, contentWidth is just the maximum width we can take up, so
  # set width to min(maxContentWidth, box.contentWidth)
  let spec = box.isWidthSpecified()
  if spec:
    box.width = box.contentWidth

  y += box.padding_top
  box.height += box.padding_top

  x += box.padding_left
  let needsMove = box.computed{"text-align"} in {TEXT_ALIGN_CHA_LEFT, TEXT_ALIGN_CHA_CENTER, TEXT_ALIGN_CHA_RIGHT}

  template apply_child(child: BlockBox) =
    child.offset.y = y
    child.offset.x = x
    if not needsMove and spec and child.contentWidth < box.contentWidth:
      let margin_left = child.computed{"margin-left"}
      let margin_right = child.computed{"margin-right"}
      if margin_left.auto and margin_right.auto:
        child.margin_left += box.contentWidth div 2
        child.margin_left -= child.contentWidth div 2
        child.margin_right += box.contentWidth div 2
        child.margin_right -= child.contentWidth div 2
      elif margin_left.auto:
        child.margin_left += box.contentWidth
        child.margin_left -= child.contentWidth
      elif margin_right.auto:
        child.margin_right += box.contentWidth
        child.margin_right -= child.contentWidth
    child.offset.x += child.margin_left
    if box.computed{"position"} == POSITION_RELATIVE:
      box.positionRelative(child)
    y += child.height
    box.height += child.height
    if not spec:
      box.width = min(box.maxContentWidth, max(child.width, box.width))
    box.xminwidth = max(box.xminwidth, child.xminwidth)
    margin_todo = Strut()
    margin_todo.append(child.margin_bottom)

  var i = 0

  template position_out_of_flow() =
    # Skip absolute, fixed, sticky
    while i < box.nested.len:
      case box.nested[i].computed{"position"}
      of POSITION_STATIC, POSITION_RELATIVE:
        break
      of POSITION_ABSOLUTE:
        positionAbsolute(box.nested[i])
      of POSITION_FIXED:
        box.positionFixed(box.nested[i])
      of POSITION_STICKY:
        #TODO implement this once relayouting every scroll isn't too expensive
        break
      box.nested.delete(i)

  position_out_of_flow

  if i < box.nested.len:
    let child = box.nested[i]

    margin_todo.append(box.margin_top)
    margin_todo.append(child.margin_top)
    box.margin_top = margin_todo.sum()

    apply_child(child)
    inc i

  while true:
    position_out_of_flow

    if i >= box.nested.len:
      break

    let child = box.nested[i]

    margin_todo.append(child.margin_top)
    y += margin_todo.sum()
    box.height += margin_todo.sum()

    apply_child(child)
    inc i

  margin_todo.append(box.margin_bottom)
  box.margin_bottom = margin_todo.sum()

  if needsMove:
    # Re-position the children.
    # The x offset for values in shrink mode depends on the parent box's
    # width, so we can not just do this in the first pass.
    let width = if box.shrink:
      min(box.width, box.contentWidth)
    else:
      max(box.width, box.contentWidth)
    case box.computed{"text-align"}
    of TEXT_ALIGN_CHA_CENTER:
      for child in box.nested:
        child.offset.x += width div 2
        child.offset.x -= child.width div 2
    of TEXT_ALIGN_CHA_LEFT: discard
    of TEXT_ALIGN_CHA_RIGHT:
      for child in box.nested:
        child.offset.x += width
        child.offset.x -= child.width
    else: discard

  box.height += box.padding_bottom

  if box.contentHeight.isSome:
    box.height = box.contentHeight.get

  box.width += box.padding_left
  box.width += box.padding_right

proc buildTableCaption(viewport: Viewport, builder: TableCaptionBoxBuilder, maxwidth: int, maxheight: Option[int], shrink = false): BlockBox =
  result = viewport.newFlowRootBox(builder, maxwidth, maxheight, shrink)
  result.buildLayout(builder)

proc buildTableCell(viewport: Viewport, builder: TableCellBoxBuilder, parentWidth: int, parentHeight: Option[int], shrink: bool, maxWidth = none(int)): BlockBox =
  result = viewport.newTableCellBox(builder, parentWidth, parentHeight, shrink, maxWidth)
  result.buildLayout(builder)

proc preBuildTableRow(pctx: var TableContext, box: TableRowBoxBuilder, parent: BlockBox, i: int): RowContext =
  var ctx = RowContext(builder: box, cells: newSeq[CellWrapper](box.children.len))
  var n = 0
  var i = 0
  for child in box.children:
    assert child.computed{"display"} == DISPLAY_TABLE_CELL
    let cellbuilder = TableCellBoxBuilder(child)
    let colspan = cellbuilder.computed{"-cha-colspan"}
    let rowspan = cellbuilder.computed{"-cha-rowspan"}
    let computedWidth = cellbuilder.computed{"width"}
    let spec = (not computedWidth.auto) and computedWidth.unit != UNIT_PERC
    let maxWidth = if spec:
      none(int)
    else:
      some(high(int))
    let box = parent.viewport.buildTableCell(cellbuilder, parent.contentWidth, parent.contentHeight, not spec, maxWidth)
    let wrapper = CellWrapper(box: box, builder: cellbuilder, colspan: colspan, rowspan: rowspan, rowi: i, coli: n)
    ctx.cells[i] = wrapper
    if rowspan != 1:
      pctx.growing.add(wrapper)
      wrapper.grown = rowspan - 1
    if pctx.cols.len < n + colspan:
      pctx.cols.setLen(n + colspan)
    if ctx.reflow.len < n + colspan:
      ctx.reflow.setLen(n + colspan)
    let minw = box.xminwidth div colspan
    let w = box.width div colspan
    for i in n ..< n + colspan:
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
      ctx.width += pctx.inlinespacing
    n += colspan
    inc i
  ctx.ncols = n
  return ctx

proc buildTableRow(pctx: TableContext, ctx: RowContext, parent: BlockBox, builder: TableRowBoxBuilder): BlockBox =
  var x = 0
  var n = 0
  let row = newBlockBox(parent, builder)
  var baseline = 0
  for cellw in ctx.cells:
    var cell = cellw.box
    var w = 0
    for i in n ..< n + cellw.colspan:
      w += pctx.cols[i].width
    if cellw.reflow:
      cell = parent.viewport.buildTableCell(cellw.builder, w, none(int), parent.shrink)
      w = max(w, cell.width)
    x += pctx.inlinespacing
    cell.offset.x += x
    x += pctx.inlinespacing
    x += w
    n += cellw.colspan
    if cell.computed{"vertical-align"}.keyword notin {VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_MIDDLE, VERTICAL_ALIGN_BOTTOM}: # baseline
      baseline = max(cell.firstBaseline, baseline)
    row.nested.add(cell)
    row.height = max(row.height, cell.height)
  for cell in row.nested:
    cell.height = min(cell.height, row.height)
  for cell in row.nested:
    case cell.computed{"vertical-align"}.keyword
    of VERTICAL_ALIGN_TOP:
      cell.offset.y = 0
    of VERTICAL_ALIGN_MIDDLE:
      cell.offset.y = row.height div 2 - cell.height div 2
    of VERTICAL_ALIGN_BOTTOM:
      cell.offset.y = row.height - cell.height
    else:
      cell.offset.y = baseline - cell.firstBaseline
  row.width = x
  return row

iterator rows(builder: TableBoxBuilder): BoxBuilder {.inline.} =
  var header: seq[TableRowBoxBuilder]
  var body: seq[TableRowBoxBuilder]
  var footer: seq[TableRowBoxBuilder]
  var caption: TableCaptionBoxBuilder
  for child in builder.children:
    assert child.computed{"display"} in ProperTableChild, $child.computed{"display"}
    case child.computed{"display"}
    of DISPLAY_TABLE_ROW:
      body.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_HEADER_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        header.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_ROW_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        body.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_FOOTER_GROUP:
      for child in child.children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        footer.add(TableRowBoxBuilder(child))
    of DISPLAY_TABLE_CAPTION:
      if caption == nil:
        caption = TableCaptionBoxBuilder(child)
    else: discard
  if caption != nil:
    yield caption
  for child in header:
    yield child
  for child in body:
    yield child
  for child in footer:
    yield child

proc calcUnspecifiedColIndices(ctx: var TableContext, W: var int, weight: var float64): seq[int] =
  var avail = newSeqUninitialized[int](ctx.cols.len)
  var i = 0
  var j = 0
  while i < ctx.cols.len:
    if not ctx.cols[i].wspecified:
      avail[j] = i
      let colw = ctx.cols[i].width
      let w = if colw < W:
        float64(colw)
      else:
        float64(W) * (ln(float64(colw) / float64(W)) + 1)
      ctx.cols[i].weight = w
      weight += w
      inc j
    else:
      W -= ctx.cols[i].width
      avail.del(j)
    inc i
  return avail

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
  var ctx = TableContext(
    collapse: table.computed{"border-collapse"} == BORDER_COLLAPSE_COLLAPSE
  )
  if not ctx.collapse:
    ctx.inlinespacing = table.computed{"border-spacing"}.a.px(table.viewport)
    ctx.blockspacing = table.computed{"border-spacing"}.b.px(table.viewport)
  var i = 0
  for row in builder.rows:
    if unlikely(row.computed{"display"} == DISPLAY_TABLE_CAPTION):
      ctx.caption = TableCaptionBoxBuilder(row)
    else:
      let row = TableRowBoxBuilder(row)
      let rctx = ctx.preBuildTableRow(row, table, i)
      ctx.rows.add(rctx)
      ctx.maxwidth = max(rctx.width, ctx.maxwidth)
      inc i
  let spec = table.computed{"width"}.auto
  var reflow = newSeq[bool](ctx.cols.len)
  if (table.contentWidth > ctx.maxwidth and (not table.shrink or not spec)) or
      table.contentWidth < ctx.maxwidth:
    var W = table.contentWidth
    var weight: float64
    var avail = ctx.calcUnspecifiedColIndices(W, weight)
    var redo = true
    while redo and avail.len > 0 and weight != 0:
      if weight == 0: break # zero weight; nothing to distribute
      if W < 0:
        W = 0
      redo = false
      # divide delta width by sum of sqrt(width) for all elem in avail
      let unit = float64(W) / weight
      weight = 0
      for i in countdown(avail.high, 0):
        let j = avail[i]
        let x = int(unit * ctx.cols[j].weight)
        let mw = ctx.cols[j].minwidth
        ctx.cols[j].width = x
        if mw > x:
          W -= mw
          ctx.cols[j].width = mw
          avail.del(i)
          redo = true
        else:
          weight += ctx.cols[j].weight
        reflow[j] = true
  for col in ctx.cols:
    table.width += col.width
  for i in countdown(ctx.rows.high, 0):
    var row = addr ctx.rows[i]
    var n = ctx.cols.len - 1
    for j in countdown(row.cells.high, 0):
      let m = n - row.cells[j].colspan
      while n > m:
        if reflow[n]:
          row.cells[j].reflow = true
        if n < row.reflow.len and row.reflow[n]:
          reflow[n] = true
        dec n
  var y = 0
  for roww in ctx.rows:
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
  table.height = table.contentHeight.get(y)
  if ctx.caption != nil:
    case ctx.caption.computed{"caption-side"}
    of CAPTION_SIDE_TOP, CAPTION_SIDE_BLOCK_START:
      let caption = table.viewport.buildTableCaption(ctx.caption, table.width, none(int), false)
      for r in table.nested:
        r.offset.y += caption.height
      table.nested.insert(caption, 0)
      table.height += caption.height
      table.width = max(table.width, caption.width)
    of CAPTION_SIDE_BOTTOM, CAPTION_SIDE_BLOCK_END:
      let caption = table.viewport.buildTableCaption(ctx.caption, table.width, none(int), false)
      caption.offset.y += table.width
      table.nested.add(caption)
      table.height += caption.height
      table.width = max(table.width, caption.width)
    of CAPTION_SIDE_LEFT, CAPTION_SIDE_INLINE_START:
      let caption = table.viewport.buildTableCaption(ctx.caption, table.contentWidth, some(table.height), true)
      for r in table.nested:
        r.offset.x += caption.width
      table.nested.insert(caption, 0)
      table.width += caption.width
      table.height = max(table.height, caption.height)
    of CAPTION_SIDE_RIGHT, CAPTION_SIDE_INLINE_END:
      let caption = table.viewport.buildTableCaption(ctx.caption, table.contentWidth, some(table.height), true)
      caption.offset.x += table.width
      table.nested.add(caption)
      table.width += caption.width
      table.height = max(table.height, caption.height)

proc buildTable(builder: TableBoxBuilder, parent: BlockBox): BlockBox =
  let table = parent.newBlockBox(builder)
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
  assert parent != nil
  result = parent.newBlockBox(builder)
  result.buildLayout(builder)

# Establish a new flow-root context and build a block box.
proc buildRootBlock(viewport: Viewport, builder: BlockBoxBuilder) =
  let box = viewport.newFlowRootBox(builder, viewport.window.width_px, shrink = false)
  viewport.root.add(box)
  box.buildLayout(builder)

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
  result.computed = computed.copyProperties()
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
    ctx.generateAnonymousInlineText(child.content.s, parent)
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

proc renderLayout*(viewport: var Viewport, root: StyledNode) =
  viewport.root.setLen(0)
  viewport.absolutes.setLen(0)
  let builder = root.generateBlockBox(viewport)
  viewport.buildRootBlock(builder)
