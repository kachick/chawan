import math
import options
import tables
import unicode

import css/stylednode
import css/values
import html/tags
import html/dom
import io/window
import layout/box
import utils/twtstr

# Build phase
func px(l: CSSLength, viewport: Viewport, p = 0): int {.inline.} =
  return px(l, viewport.window, p)

type InlineState = object
  ictx: InlineContext
  skip: bool
  node: StyledNode
  word: InlineWord
  maxwidth: int
  computed: CSSComputedValues

func whitespacepre(computed: CSSComputedValues): bool {.inline.} =
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_LINE}

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

proc newWord(state: var InlineState) =
  let word = InlineWord()
  let format = ComputedFormat()
  let computed = state.computed
  format.color = computed{"color"}
  format.fontstyle = computed{"font-style"}
  format.fontweight = computed{"font-weight"}
  format.textdecoration = computed{"text-decoration"}
  format.node = state.node
  word.format = format
  state.ictx.format = format
  state.word = word

proc horizontalAlignLine(ictx: InlineContext, line: LineBox, computed: CSSComputedValues, maxwidth: int, last = false) =
  let maxwidth = if ictx.shrink:
    ictx.maxwidth
  else:
    maxwidth
  # we don't support directions for now so left = start and right = end
  case computed{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT, TEXT_ALIGN_CHA_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CHA_RIGHT:
    # move everything
    let x = max(maxwidth, line.width) - line.width
    for atom in line.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_CENTER, TEXT_ALIGN_CHA_CENTER:
    let x = max((max(maxwidth - line.offset.x, line.width)) div 2 - line.width div 2, 0)
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
        let spacingwidth = (ictx.maxwidth - sumwidth) div spaces
        line.width = 0
        for atom in line.atoms:
          atom.offset.x = line.width
          if atom of InlineSpacing:
            let atom = InlineSpacing(atom)
            atom.width = spacingwidth
          line.width += atom.width

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

proc addSpacing(line: LineBox, width, height: int, format: ComputedFormat) {.inline.} =
  let spacing = InlineSpacing(width: width, height: height, baseline: height, format: format)
  spacing.offset.x = line.width
  line.width += spacing.width
  line.atoms.add(spacing)

proc flushWhitespace(ictx: InlineContext, computed: CSSComputedValues) =
  let shift = ictx.computeShift(computed)
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format)

proc finishLine(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int, force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    ictx.whitespacenum = 0
    ictx.flushWhitespace(computed)
    ictx.verticalAlignLine()

    let line = ictx.currentLine
    ictx.lines.add(line)
    ictx.height += line.height
    ictx.maxwidth = max(ictx.maxwidth, line.width)
    ictx.currentLine = LineBox(offset: Offset(y: line.offset.y + line.height))

proc finish(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int) =
  ictx.finishLine(computed, maxwidth)
  for line in ictx.lines:
    ictx.horizontalAlignLine(line, computed, maxwidth, line == ictx.lines[^1])

func minwidth(atom: InlineAtom): int =
  if atom of InlineBlockBox:
    return cast[InlineBlockBox](atom).innerbox.xminwidth
  return atom.width

# pcomputed: computed values of parent, for white-space: pre, line-height
# computed: computed values of child, for vertical-align
# (TODO: surely there's a better way to do this? like storing pcomputed in ictx
# or something...)
proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, pcomputed, computed: CSSComputedValues) =
  var shift = ictx.computeShift(pcomputed)
  ictx.whitespacenum = 0
  # Line wrapping
  if not pcomputed.whitespacepre:
    if ictx.currentLine.width + atom.width + shift > maxwidth:
      ictx.finishLine(pcomputed, maxwidth, false)
      # Recompute on newline
      shift = ictx.computeShift(pcomputed)

  if atom.width > 0 and atom.height > 0:
    atom.vertalign = computed{"vertical-align"}

    if shift > 0:
      ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format)

    atom.offset.x += ictx.currentLine.width
    ictx.minwidth = max(ictx.minwidth, atom.minwidth)
    applyLineHeight(ictx.viewport, ictx.currentLine, pcomputed)
    ictx.currentLine.width += atom.width
    if atom of InlineWord:
      ictx.format = InlineWord(atom).format
    else:
      ictx.format = nil
    ictx.currentLine.atoms.add(atom)

proc addWord(state: var InlineState) =
  if state.word.str != "":
    var word = state.word
    word.height = state.ictx.cellheight
    word.baseline = word.height
    state.ictx.addAtom(word, state.maxwidth, state.computed, state.computed)
    state.newWord()

# Start a new line, even if the previous one is empty
proc flushLine(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int) =
  applyLineHeight(ictx.viewport, ictx.currentLine, computed)
  ictx.finishLine(computed, maxwidth, true)

proc checkWrap(state: var InlineState, r: Rune) =
  if state.computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  let shift = state.ictx.computeShift(state.computed)
  case state.computed{"word-break"}
  of WORD_BREAK_BREAK_ALL:
    if state.ictx.currentLine.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.addWord()
      state.ictx.finishLine(state.computed, state.maxwidth, false)
      state.ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    if state.ictx.currentLine.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.ictx.finishLine(state.computed, state.maxwidth, false)
      state.ictx.whitespacenum = 0
  else: discard

proc processWhitespace(state: var InlineState, c: char) =
  state.addWord()
  case state.computed{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    state.ictx.whitespacenum = max(state.ictx.whitespacenum, 1)
  of WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    if c == '\n':
      state.ictx.flushLine(state.computed, state.maxwidth)
    elif c == '\t':
      state.ictx.whitespacenum = (state.ictx.whitespacenum div 8 + 1) * 8
    else:
      inc state.ictx.whitespacenum

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, computed: CSSComputedValues, node: StyledNode) =
  var state: InlineState
  state.computed = computed
  state.ictx = ictx
  state.maxwidth = maxwidth
  state.node = node
  state.ictx.flushWhitespace(state.computed)
  state.newWord()

  #if str.strip().len > 0:
    #eprint "start", str.strip()
  var i = 0
  while i < str.len:
    if str[i].isWhitespace():
      state.processWhitespace(str[i])
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      state.checkWrap(r)
      state.word.str &= r
      state.word.width += r.width() * state.ictx.cellwidth

  state.addWord()

type PreferredDimensions = object
  compwidth: int
  compheight: Option[int]
  margin_top: int
  margin_bottom: int
  margin_left: int
  margin_right: int
  padding_left: int
  padding_right: int
  padding_top: int
  padding_bottom: int
  max_width: Option[int]
  max_height: Option[int]
  min_width: Option[int]
  min_height: Option[int]

proc preferredDimensions(computed: CSSComputedValues, viewport: Viewport, width: int, height: Option[int]): PreferredDimensions =
  let pwidth = computed{"width"}
  if pwidth.auto:
    result.compwidth = width
  else:
    result.compwidth = pwidth.px(viewport, width)

  if not computed{"max-width"}.auto:
    result.max_width = some(computed{"max-width"}.px(viewport, width))
  if not computed{"max-height"}.auto:
    if computed{"max-height"}.unit != UNIT_PERC:
      result.max_height = computed{"max-height"}.px(viewport).some
    elif height.issome:
      result.max_height = computed{"max-height"}.px(viewport, height.get).some

  if not computed{"min-width"}.auto:
    result.min_width = some(computed{"min-width"}.px(viewport, width))
  if not computed{"min-height"}.auto:
    if computed{"min-height"}.unit != UNIT_PERC:
      result.compheight = computed{"min-height"}.px(viewport).some
    elif height.issome:
      result.compheight = computed{"min-height"}.px(viewport, height.get).some

  result.margin_top = computed{"margin-top"}.px(viewport, width)
  result.margin_bottom = computed{"margin-top"}.px(viewport, width)
  result.margin_left = computed{"margin-left"}.px(viewport, width)
  result.margin_right = computed{"margin-right"}.px(viewport, width)

  result.padding_top = computed{"padding-top"}.px(viewport, width)
  result.padding_bottom = computed{"padding-bottom"}.px(viewport, width)
  result.padding_left = computed{"padding-left"}.px(viewport, width)
  result.padding_right = computed{"padding-right"}.px(viewport, width)

  if result.compwidth >= width:
    result.compwidth -= result.margin_left
    result.compwidth -= result.margin_right

    result.compwidth -= result.padding_left
    result.compwidth -= result.padding_right

  let pheight = computed{"height"}
  if not pheight.auto:
    if pheight.unit != UNIT_PERC:
      result.compheight = pheight.px(viewport).some
    elif height.issome:
      result.compheight = pheight.px(viewport, height.get).some

proc setPreferredDimensions(box: BlockBox, width: int, height: Option[int]) =
  let preferred = preferredDimensions(box.computed, box.viewport, width, height)
  box.compwidth = preferred.compwidth
  box.compheight = preferred.compheight
  box.padding_top = preferred.padding_top
  box.padding_bottom = preferred.padding_bottom
  box.padding_left = preferred.padding_left
  box.padding_right = preferred.padding_right
  box.margin_top = preferred.margin_top
  box.margin_bottom = preferred.margin_bottom
  box.margin_left = preferred.margin_left
  box.margin_right = preferred.margin_right
  box.max_width = preferred.max_width
  box.max_height = preferred.max_height
  box.min_width = preferred.min_width
  box.min_height = preferred.min_height

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
  template no_specified_width: bool =
    # We check if our used width has already been specified.
    box.computed{"width"}.auto and box.max_width.isNone and box.min_width.isNone
  case box.computed{"display"}
  of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
    # Inline blocks/tables always take up as much space as their contents.
    return no_specified_width
  of DISPLAY_TABLE:
    # Always shrink tables.
    return true
  of DISPLAY_BLOCK, DISPLAY_TABLE_CELL, DISPLAY_TABLE_ROW,
     DISPLAY_TABLE_CAPTION, DISPLAY_LIST_ITEM:
    if parent == nil:
      # We're in a new block formatting context; we can take up all available
      # space we want.
      # ...except in the second pass of table cell generation, where the first
      # pass is used to determine the maximum width of cells, and the second
      # pass is what we actually end up using.
      return override
    else:
      # Basically, check if our block formatting context has infinite width.
      # If yes, there's no need to shrink anyways; we can take up all available
      # space.
      # If not, and no width was specified, we have to enable shrink.
      return parent.shrink and no_specified_width
  else: discard

proc newFlowRootBox(viewport: Viewport, box: BoxBuilder, parentWidth: int, parentHeight = none(int), shrink = true): BlockBox {.inline.} =
  new(result)
  result.viewport = viewport
  result.computed = box.computed
  result.setPreferredDimensions(parentWidth, parentHeight)
  result.shrink = result.isShrink(nil, shrink)

proc newBlockBox(parent: BlockBox, builder: BoxBuilder): BlockBox =
  new(result)
  result.viewport = parent.viewport
  result.computed = builder.computed
  result.setPreferredDimensions(parent.compwidth, parent.compheight)
  result.shrink = result.isShrink(parent)

proc newListItem(parent: BlockBox, builder: ListItemBoxBuilder): ListItemBox =
  new(result)
  result.viewport = parent.viewport
  result.computed = builder.content.computed
  result.setPreferredDimensions(parent.compwidth, parent.compheight)
  result.shrink = result.isShrink(parent)

proc newInlineBlock(viewport: Viewport, builder: BoxBuilder, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  new(result)
  result.innerbox = newFlowRootBox(viewport, builder, parentWidth, parentHeight)

proc newInlineContext(parent: BlockBox): InlineContext =
  new(result)
  result.currentLine = LineBox()
  result.viewport = parent.viewport
  result.shrink = parent.shrink

proc positionInlines(parent: BlockBox) =
  parent.width += parent.padding_left
  parent.inline.offset.x += parent.padding_left

  parent.height += parent.padding_top
  parent.inline.offset.y += parent.padding_top

  parent.height += parent.padding_bottom

  parent.width += parent.padding_right

  parent.xminwidth = max(parent.xminwidth, parent.inline.minwidth)

  if parent.computed{"width"}.auto:
    if parent.shrink:
      parent.width = min(parent.width, parent.compwidth)
    else:
      parent.width = max(parent.width, parent.compwidth)
  else:
    parent.width = parent.compwidth
  if parent.max_width.isSome and parent.max_width.get < parent.width:
    parent.width = parent.max_width.get
  if parent.min_width.isSome and parent.width < parent.min_width.get:
    parent.width = parent.min_width.get
  if parent.max_height.isSome and parent.max_height.get < parent.height:
    parent.height = parent.max_height.get
  if parent.min_height.isSome and parent.height < parent.min_height.get:
    parent.height = parent.min_height.get

proc buildBlock(box: BlockBoxBuilder, parent: BlockBox): BlockBox
proc buildInlines(parent: BlockBox, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(parent: BlockBox, blocks: seq[BoxBuilder], node: StyledNode)
proc buildTable(box: TableBoxBuilder, parent: BlockBox): BlockBox

proc applyInlineDimensions(parent: BlockBox) =
  parent.height += parent.inline.height
  if parent.compheight.issome:
    parent.height = parent.compheight.get
  parent.width = max(parent.width, parent.inline.maxwidth)

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

#TODO this is horribly inefficient
func firstBaseline(bctx: BlockBox): int =
  if bctx.inline != nil:
    if bctx.inline.lines.len > 0:
      return bctx.offset.y + bctx.inline.lines[0].baseline
    return bctx.offset.y
  if bctx.nested.len > 0:
    return bctx.offset.y + bctx.nested[^1].firstBaseline
  bctx.offset.y

#TODO ditto
func baseline(bctx: BlockBox): int =
  if bctx.inline != nil:
    var y = 0
    for line in bctx.inline.lines:
      if line == bctx.inline.lines[^1]:
        return bctx.offset.y + y + line.baseline
      y += line.height
    return bctx.offset.y
  if bctx.nested.len > 0:
    return bctx.offset.y + bctx.nested[^1].baseline
  bctx.offset.y

proc buildInlineBlock(builder: BlockBoxBuilder, parent: InlineContext, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  result = newInlineBlock(parent.viewport, builder, parentWidth)

  if builder.inlinelayout:
    result.innerbox.buildInlineLayout(builder.children)
  else:
    result.innerbox.buildBlockLayout(builder.children, builder.node)

  let pwidth = builder.computed{"width"}
  if pwidth.auto:
    # shrink-to-fit
    result.innerbox.width = min(parentWidth, result.innerbox.width)
  else:
    result.innerbox.width = pwidth.px(parent.viewport, parentWidth)

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

# Copy-pasted wholesale from above. TODO generalize this somehow
proc buildInlineTableBox(builder: TableBoxBuilder, parent: InlineContext, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  result = newInlineBlock(parent.viewport, builder, parentWidth)

  result.innerbox.nested.add(buildTable(builder, result.innerbox))

  let pwidth = builder.computed{"width"}
  if pwidth.auto:
    # shrink-to-fit
    result.innerbox.width = min(parentWidth, result.innerbox.width)
  else:
    result.innerbox.width = pwidth.px(parent.viewport, parentWidth)

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

proc buildInline(viewport: Viewport, box: InlineBoxBuilder, parentWidth: int, parentHeight = none(int)) =
  assert box.ictx != nil
  if box.newline:
    box.ictx.flushLine(box.computed, parentWidth)

  let margin_left = box.computed{"margin-left"}.px(viewport, parentWidth)
  box.ictx.currentLine.width += margin_left

  let paddingformat = ComputedFormat(node: box.node)
  let padding_left = box.computed{"padding-left"}.px(viewport, parentWidth)
  if padding_left > 0:
    box.ictx.currentLine.addSpacing(padding_left, box.ictx.cellheight, paddingformat)

  assert not (box.children.len > 0 and box.text.len > 0)
  for text in box.text:
    box.ictx.renderText(text, parentWidth, box.computed, box.node)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      child.ictx = box.ictx
      buildInline(viewport, child, parentWidth)
    of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
      let child = BlockBoxBuilder(child)
      let iblock = child.buildInlineBlock(box.ictx, parentWidth, parentHeight)
      box.ictx.addAtom(iblock, parentWidth, box.computed, child.computed)
      box.ictx.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  let padding_right = box.computed{"padding-right"}.px(viewport, parentWidth)
  if padding_right > 0:
    # I don't like this, but it works...
    box.ictx.currentLine.addSpacing(padding_right, max(box.ictx.currentLine.height, 1), paddingformat)

  let margin_right = box.computed{"margin-right"}.px(viewport, parentWidth)
  box.ictx.currentLine.width += margin_right

proc buildInlines(parent: BlockBox, inlines: seq[BoxBuilder]): InlineContext =
  let ictx = parent.newInlineContext()
  var usedwidth = parent.compwidth
  if parent.max_width.isSome and parent.max_width.get > usedwidth:
    usedwidth = parent.max_width.get
  if parent.min_width.isSome and parent.min_width.get < usedwidth:
    usedwidth = parent.min_width.get
  if inlines.len > 0:
    for child in inlines:
      case child.computed{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        child.ictx = ictx
        buildInline(parent.viewport, child, usedwidth, parent.compheight)
      of DISPLAY_INLINE_BLOCK, DISPLAY_INLINE_TABLE:
        let child = BlockBoxBuilder(child)
        let iblock = child.buildInlineBlock(ictx, usedwidth)
        ictx.addAtom(iblock, usedwidth, parent.computed, child.computed)
        ictx.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    ictx.finish(parent.computed, usedwidth)
  return ictx

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockBox): ListItemBox =
  result = parent.newListItem(builder)

  if builder.marker != nil:
    result.marker = result.buildInlines(@[BoxBuilder(builder.marker)])

  if builder.content.inlinelayout:
    result.buildInlineLayout(builder.content.children)
  else:
    result.buildBlockLayout(builder.content.children, builder.content.node)

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
    box.offset.x += left.px(box.viewport, last.compwidth)
    box.offset.x += box.margin_left
  elif not right.auto:
    box.offset.x += last.compwidth - right.px(box.viewport, box.compwidth) - box.width
    box.offset.x -= box.margin_right
  if not top.auto:
    box.offset.y += top.px(box.viewport, box.compheight.get(0))
    box.offset.y += box.margin_top
  elif not bottom.auto:
    box.offset.y += last.compheight.get(box.viewport.window.height_px) - bottom.px(box.viewport, box.compheight.get(0)) - box.height
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

  y += box.padding_top
  box.height += box.padding_top

  x += box.padding_left
  case box.computed{"text-align"}
  of TEXT_ALIGN_CHA_CENTER:
    x += box.compwidth div 2
  of TEXT_ALIGN_CHA_LEFT: discard
  of TEXT_ALIGN_CHA_RIGHT:
    x += box.compwidth
  else: discard

  template apply_child(child: BlockBox) =
    child.offset.y = y
    child.offset.x = x
    case
    box.computed{"text-align"}
    of TEXT_ALIGN_CHA_CENTER:
      child.offset.x -= child.width div 2
    of TEXT_ALIGN_CHA_LEFT: discard
    of TEXT_ALIGN_CHA_RIGHT:
      child.offset.x -= child.width
    elif not child.computed{"width"}.auto and child.compwidth < box.compwidth:
      let margin_left = child.computed{"margin-left"}
      let margin_right = child.computed{"margin-right"}
      if margin_left.auto and margin_right.auto:
        child.margin_left += box.compwidth div 2
        child.margin_left -= child.compwidth div 2
        child.margin_right += box.compwidth div 2
        child.margin_right -= child.compwidth div 2
      elif margin_left.auto:
        child.margin_left += box.compwidth
        child.margin_left -= child.compwidth
      elif margin_right.auto:
        child.margin_right += box.compwidth
        child.margin_right -= child.compwidth
    child.offset.x += child.margin_left

    if box.computed{"position"} == POSITION_RELATIVE:
      box.positionRelative(child)
    y += child.height
    box.height += child.height
    box.width = max(box.width, child.width)
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

  box.height += box.padding_bottom

  if box.compheight.issome:
    box.height = box.compheight.get

  box.width += box.padding_left
  box.width += box.padding_right
  if box.max_width.isSome and box.max_width.get < box.width:
    box.width = box.max_width.get
  if box.min_width.isSome and box.width < box.min_width.get:
    box.width = box.min_width.get
  if box.max_height.isSome and box.max_height.get < box.height:
    box.height = box.max_height.get
  if box.min_height.isSome and box.height < box.min_height.get:
    box.height = box.min_height.get

proc buildTableCaption(viewport: Viewport, box: TableCaptionBoxBuilder, maxwidth: int, maxheight: Option[int], shrink = false): BlockBox =
  result = viewport.newFlowRootBox(box, maxwidth, maxheight, shrink)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

proc buildTableCell(viewport: Viewport, box: TableCellBoxBuilder, maxwidth: int, maxheight: Option[int], shrink = true): BlockBox =
  result = viewport.newFlowRootBox(box, maxwidth, maxheight, shrink)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

proc preBuildTableRow(pctx: var TableContext, box: TableRowBoxBuilder, parent: BlockBox): RowContext =
  var ctx = RowContext(builder: box, cells: newSeq[CellWrapper](box.children.len))
  var n = 0
  var i = 0
  for child in box.children:
    assert child.computed{"display"} == DISPLAY_TABLE_CELL
    let cellbuilder = TableCellBoxBuilder(child)
    let cell = parent.viewport.buildTableCell(cellbuilder, parent.compwidth, parent.compheight)
    ctx.cells[i] = CellWrapper(box: cell, builder: cellbuilder, colspan: cellbuilder.colspan)
    let pwidth = cellbuilder.computed{"width"}
    if pctx.cols.len < n + cellbuilder.colspan:
      pctx.cols.setLen(n + cellbuilder.colspan)
    if ctx.reflow.len < n + cellbuilder.colspan:
      ctx.reflow.setLen(n + cellbuilder.colspan)
    let minw = cell.xminwidth div cellbuilder.colspan
    let w = cell.width div cellbuilder.colspan
    for i in n ..< n + cellbuilder.colspan:
      ctx.width += pctx.inlinespacing
      pctx.cols[i].maxwidth = w
      if pctx.cols[i].width < w:
        pctx.cols[i].width = w
        if ctx.reflow.len <= i: ctx.reflow.setLen(i + 1)
        ctx.reflow[i] = true
      if not pwidth.auto:
        let ww = pwidth.px(parent.viewport, parent.compwidth)
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
    n += cellbuilder.colspan
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
      cell = parent.viewport.buildTableCell(cellw.builder, w, none(int), false)
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
    cell.height = max(cell.height, row.height)
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

proc calcUnspecifiedColIndices(ctx: var TableContext, dw: int, weight: var float64): seq[int] =
  var avail = newSeqUninitialized[int](ctx.cols.len)
  var i = 0
  var j = 0
  while i < ctx.cols.len:
    if not ctx.cols[i].wspecified:
      avail[j] = i
      let w = sqrt(float64(ctx.cols[i].width) / float64(dw)) * float64(dw)
      ctx.cols[i].weight = w
      weight += w
      inc j
    else:
      avail.del(j)
    inc i
  return avail

# Table layout. We try to emulate w3m's behavior here:
# 1. Calculate minimum and preferred width of each column
# 2. If column width is not auto, set width to max(min_col_width, specified)
# 3. Calculate the maximum preferred row width. If this is
# a) less than the specified table width:
#      distribute (max_row_width - table_width) among cells with an unspecified
#      width.
# b) greater than the specified table width:
#      distribute -(table_width - max_row_width) among cells with an unspecified
#      width. If this would give any cell a width < min_width, distribute the
#      difference too.
proc buildTable(box: TableBoxBuilder, parent: BlockBox): BlockBox =
  let table = parent.newBlockBox(box)
  var ctx = TableContext(
    collapse: table.computed{"border-collapse"} == BORDER_COLLAPSE_COLLAPSE
  )
  if not ctx.collapse:
    ctx.inlinespacing = table.computed{"border-spacing"}.a.px(parent.viewport)
    ctx.blockspacing = table.computed{"border-spacing"}.b.px(parent.viewport)
  for row in box.rows:
    if unlikely(row.computed{"display"} == DISPLAY_TABLE_CAPTION):
      ctx.caption = TableCaptionBoxBuilder(row)
    else:
      let row = TableRowBoxBuilder(row)
      let rctx = ctx.preBuildTableRow(row, table)
      ctx.rows.add(rctx)
      ctx.maxwidth = max(rctx.width, ctx.maxwidth)
  var forceresize = false
  if not table.computed{"width"}.auto:
    forceresize = true
  var reflow = newSeq[bool](ctx.cols.len)
  if table.compwidth > ctx.maxwidth and (not table.shrink or forceresize):
    let dw = (table.compwidth - ctx.maxwidth)
    var weight: float64
    var avail = ctx.calcUnspecifiedColIndices(dw, weight)
    let unit = float64(dw) / weight
    for i in countdown(avail.high, 0):
      let j = avail[i]
      let x = int(unit * ctx.cols[j].weight)
      ctx.cols[j].width += x
      reflow[j] = true
  elif table.compwidth < ctx.maxwidth:
    var dw = (ctx.maxwidth - table.compwidth)
    var weight: float64
    var avail = ctx.calcUnspecifiedColIndices(dw, weight)
    while avail.len > 0 and dw != 0:
      # divide delta width by sum of sqrt(width) for all elem in avail
      let unit = float64(dw) / weight
      dw = 0
      weight = 0
      for i in countdown(avail.high, 0):
        let j = avail[i]
        let x = int(unit * ctx.cols[j].weight)
        ctx.cols[j].width -= x
        if ctx.cols[j].minwidth > ctx.cols[j].width:
          let d = ctx.cols[j].minwidth - ctx.cols[j].width
          dw += d
          ctx.cols[j].width = ctx.cols[j].minwidth
          avail.del(i)
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
  table.height = table.compheight.get(y)
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
      let caption = table.viewport.buildTableCaption(ctx.caption, table.compwidth, some(table.height), true)
      for r in table.nested:
        r.offset.x += caption.width
      table.nested.insert(caption, 0)
      table.width += caption.width
      table.height = max(table.height, caption.height)
    of CAPTION_SIDE_RIGHT, CAPTION_SIDE_INLINE_END:
      let caption = table.viewport.buildTableCaption(ctx.caption, table.compwidth, some(table.height), true)
      caption.offset.x += table.width
      table.nested.add(caption)
      table.width += caption.width
      table.height = max(table.height, caption.height)
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
proc buildBlock(box: BlockBoxBuilder, parent: BlockBox): BlockBox =
  assert parent != nil
  result = parent.newBlockBox(box)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

# Establish a new flow-root context and build a block box.
proc buildRootBlock(viewport: Viewport, builder: BlockBoxBuilder) =
  let box = viewport.newFlowRootBox(builder, viewport.window.width_px, shrink = false)
  viewport.root.add(box)
  if builder.inlinelayout:
    box.buildInlineLayout(builder.children)
  else:
    box.buildBlockLayout(builder.children, builder.node)

# Generation phase

# Returns a block box, disregarding the computed value of display
proc getBlockBox(computed: CSSComputedValues): BlockBoxBuilder =
  new(result)
  result.computed = computed.copyProperties()
  result.computed{"display"} = DISPLAY_BLOCK

proc getTextBox(box: BoxBuilder): InlineBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = box.computed.inheritProperties()

proc getTextBox(computed: CSSComputedValues): InlineBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = computed.inheritProperties()

proc getMarkerBox(computed: CSSComputedValues, listItemCounter: int): MarkerBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = computed.copyProperties()
  result.computed{"display"} = DISPLAY_INLINE
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
  result.colspan = 1

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
    let bbox = getBlockBox(blockgroup.parent.computed.inheritProperties())
    bbox.inlinelayout = true
    bbox.children = blockgroup.boxes
    blockgroup.parent.children.add(bbox)
    blockgroup.boxes.setLen(0)

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: BlockGroup, computed: CSSComputedValues, str: string): bool =
  return blockgroup.boxes.len > 0 and blockgroup.boxes[^1].computed{"display"} == DISPLAY_INLINE or
    computed{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
    not str.onlyWhitespace()

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
      var wrappervals = ctx.styledNode.computed.inheritProperties()
      wrappervals{"display"} = DISPLAY_TABLE
      if ctx.anonTable == nil:
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
  if styledNode.node != nil:
    let elem = Element(styledNode.node)
    if elem.tagType == TAG_BR:
      ctx.iflush()
      ctx.ibox = box.getTextBox()
      ctx.ibox.newline = true
      ctx.iflush()

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
    box.children.add(childbox)
  of DISPLAY_INLINE:
    ctx.iflush()
    ctx.generateInlineBoxes(styledNode)
  of DISPLAY_INLINE_BLOCK:
    ctx.iflush()
    let childbox = ctx.generateBlockBox(styledNode)
    childbox.computed{"display"} = DISPLAY_INLINE_BLOCK
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

proc generateInlineText(ctx: var InnerBlockContext, text: string, styledNode: StyledNode) =
  if ctx.ibox == nil:
    ctx.ibox = getTextBox(styledNode.computed)
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
    ctx.generateInlineText(text, parent)
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
    ctx.generateInlineText(text, parent)
  of CONTENT_NO_OPEN_QUOTE:
    inc ctx.quoteLevel
  of CONTENT_NO_CLOSE_QUOTE:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
  of CONTENT_STRING:
    #TODO canGenerateAnonymousInline?
    ctx.generateInlineText(child.content.s, parent)

proc generateInlineBoxes(ctx: var InnerBlockContext, styledNode: StyledNode) =
  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      ctx.generateFromElem(child)
    of STYLED_TEXT:
      ctx.generateInlineText(child.text, styledNode)
    of STYLED_REPLACEMENT:
      ctx.generateReplacement(child, styledNode)
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
        ctx.generateInlineText(child.text, ctx.styledNode)
    of STYLED_REPLACEMENT:
      ctx.generateReplacement(child, ctx.styledNode)
  ctx.iflush()

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder), parent: ptr InnerBlockContext = nil): BlockBoxBuilder =
  let box = getBlockBox(styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, viewport, parent)

  if marker.issome:
    ctx.ibox = marker.get
    ctx.iflush()

  ctx.generateInnerBlockBox()

  if ctx.blockgroup.boxes.len > 0:
    # Avoid unnecessary anonymous block boxes
    if box.children.len == 0:
      box.children = ctx.blockgroup.boxes
      box.inlinelayout = true
      ctx.blockgroup.boxes.setLen(0)
  ctx.flush()
  return box

proc generateTableCellBox(styledNode: StyledNode, viewport: Viewport, parent: var InnerBlockContext): TableCellBoxBuilder =
  let box = getTableCellBox(styledNode.computed)
  if styledNode.node != nil and styledNode.node.nodeType == ELEMENT_NODE:
    box.colspan = Element(styledNode.node).attri("colspan").get(1)
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

proc renderLayout*(viewport: var Viewport, document: Document, root: StyledNode) =
  viewport.root.setLen(0)
  let builder = root.generateBlockBox(viewport)
  viewport.buildRootBlock(builder)
