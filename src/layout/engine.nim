import options
import unicode

import css/stylednode
import css/values
import html/tags
import html/dom
import io/term
import layout/box
import utils/twtstr

# Build phase
func px(l: CSSLength, viewport: Viewport, p = 0): int {.inline.} =
  return px(l, viewport.term, p)

type InlineState = object
  ictx: InlineContext
  skip: bool
  node: Node
  word: InlineWord
  maxwidth: int
  computed: CSSComputedValues

func whitespacepre(computed: CSSComputedValues): bool {.inline.} =
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_WRAP}

func cellwidth(viewport: Viewport): int {.inline.} =
  viewport.term.ppc

func cellwidth(ictx: InlineContext): int {.inline.} =
  ictx.viewport.cellwidth

func cellheight(viewport: Viewport): int {.inline.} =
  viewport.term.ppl

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
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT:
    # move everything
    let x = max(maxwidth, line.width) - line.width
    for atom in line.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_CENTER:
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
  else:
    discard

# Align atoms (inline boxes, text, etc.) vertically inside the line.
# This currently assumes inline boxes have no margins. TODO fix this.
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
  # The line height should be as high than the highest baseline used by an atom
  # plus that atom's height.
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

proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, computed: CSSComputedValues) =
  var shift = ictx.computeShift(computed)
  ictx.whitespacenum = 0
  # Line wrapping
  if not computed.whitespacepre:
    if ictx.currentLine.width + atom.width + shift > maxwidth:
      ictx.finishLine(computed, maxwidth, false)
      # Recompute on newline
      shift = ictx.computeShift(computed)

  if atom.width > 0 and atom.height > 0:
    atom.vertalign = computed{"vertical-align"}

    if shift > 0:
      ictx.currentLine.addSpacing(shift, ictx.cellheight, ictx.format)

    atom.offset.x += ictx.currentLine.width
    applyLineHeight(ictx.viewport, ictx.currentLine, computed)
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
    state.ictx.addAtom(word, state.maxwidth, state.computed)
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
    else:
      inc state.ictx.whitespacenum

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, computed: CSSComputedValues, node: Node) =
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

proc preferredDimensions(computed: CSSComputedValues, viewport: Viewport, width: int, height: Option[int]): PreferredDimensions =
  let pwidth = computed{"width"}
  if pwidth.auto:
    result.compwidth = width
  else:
    result.compwidth = pwidth.px(viewport, width)

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

proc setPreferredDimensions(bctx: BlockBox, width: int, height: Option[int]) =
  let preferred = preferredDimensions(bctx.computed, bctx.viewport, width, height)
  bctx.compwidth = preferred.compwidth
  bctx.compheight = preferred.compheight
  bctx.padding_top = preferred.padding_top
  bctx.padding_bottom = preferred.padding_bottom
  bctx.padding_left = preferred.padding_left
  bctx.padding_right = preferred.padding_right
  bctx.margin_top = preferred.margin_top
  bctx.margin_bottom = preferred.margin_bottom
  bctx.margin_left = preferred.margin_left
  bctx.margin_right = preferred.margin_right

proc newBlockBox_common2(bctx: BlockBox, parent: BlockBox, box: BoxBuilder) {.inline.} =
  bctx.viewport = parent.viewport
  bctx.computed = box.computed
  bctx.setPreferredDimensions(parent.compwidth, parent.compheight)

proc newBlockBox_common(parent: BlockBox, box: BoxBuilder): BlockBox {.inline.} =
  new(result)
  result.newBlockBox_common2(parent, box)

proc newFlowRootBox(viewport: Viewport, box: BoxBuilder, parentWidth: int, parentHeight = none(int)): BlockBox {.inline.} =
  new(result)
  result.viewport = viewport
  result.computed = box.computed
  result.setPreferredDimensions(parentWidth, parentHeight)
  result.shrink = result.computed{"width"}.auto

proc newBlockBox(parent: BlockBox, box: BlockBoxBuilder): BlockBox =
  result = newBlockBox_common(parent, box)
  result.shrink = result.computed{"width"}.auto and parent.shrink

proc newListItem(parent: BlockBox, builder: ListItemBoxBuilder): ListItemBox =
  new(result)
  result.newBlockBox_common2(parent, builder.content)
  result.shrink = result.computed{"width"}.auto and parent.shrink

proc newBlockBox(viewport: Viewport, box: BlockBoxBuilder): BlockBox =
  result = newFlowRootBox(viewport, box, viewport.term.width_px)

proc newInlineBlock(viewport: Viewport, builder: InlineBlockBoxBuilder, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  new(result)
  result.bctx = newFlowRootBox(viewport, builder.content, parentWidth, parentHeight)

proc newInlineContext(bctx: BlockBox): InlineContext =
  new(result)
  result.currentLine = LineBox()
  result.viewport = bctx.viewport
  result.shrink = bctx.shrink

proc positionInlines(bctx: BlockBox) =
  bctx.width += bctx.padding_left
  bctx.inline.offset.x += bctx.padding_left

  bctx.height += bctx.padding_top
  bctx.inline.offset.y += bctx.padding_top

  bctx.height += bctx.padding_bottom

  bctx.width += bctx.padding_right

  if bctx.computed{"width"}.auto:
    bctx.width = min(bctx.width, bctx.compwidth)
  else:
    bctx.width = bctx.compwidth

proc buildBlock(box: BlockBoxBuilder, parent: BlockBox): BlockBox
proc buildInlines(bctx: BlockBox, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(bctx: BlockBox, blocks: seq[BoxBuilder], node: Node)

proc applyInlineDimensions(bctx: BlockBox) =
  bctx.height += bctx.inline.height
  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get
  bctx.width = max(bctx.width, bctx.inline.maxwidth)

# Builder only contains inline boxes.
proc buildInlineLayout(bctx: BlockBox, children: seq[BoxBuilder]) =
  bctx.inline = bctx.buildInlines(children)
  bctx.applyInlineDimensions()
  bctx.positionInlines()

# Builder only contains block boxes.
proc buildBlockLayout(bctx: BlockBox, children: seq[BoxBuilder], node: Node) =
  bctx.buildBlocks(children, node)

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

proc buildInlineBlock(builder: InlineBlockBoxBuilder, parent: InlineContext, parentWidth: int, parentHeight = none(int)): InlineBlockBox =
  assert builder.content != nil
  result = newInlineBlock(parent.viewport, builder, parentWidth)

  let blockbuilder = builder.content
  if blockbuilder.inlinelayout:
    result.bctx.buildInlineLayout(blockbuilder.children)
  else:
    result.bctx.buildBlockLayout(blockbuilder.children, blockbuilder.node)

  let pwidth = builder.computed{"width"}
  if pwidth.auto:
    # Half-baked shrink-to-fit
    # Currently the misery that is determining content width is deferred to the
    # inline layouting algorithm, which doesn't work that great but that's what
    # we have.
    result.bctx.width = min(parentWidth, result.bctx.width)
  else:
    result.bctx.width = pwidth.px(parent.viewport, parentWidth)

  # Apply the block box's properties to the atom itself.
  result.width = result.bctx.width
  result.height = result.bctx.height

  result.margin_top = result.bctx.margin_top
  result.margin_bottom = result.bctx.margin_bottom

  result.baseline = result.bctx.baseline

  # I don't like this, but it works...
  result.offset.x = result.bctx.margin_left
  result.width += result.bctx.margin_left
  result.width += result.bctx.margin_right

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

  for text in box.text:
    assert box.children.len == 0
    box.ictx.renderText(text, parentWidth, box.computed, box.node)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      child.ictx = box.ictx
      buildInline(viewport, child, parentWidth)
    of DISPLAY_INLINE_BLOCK:
      let child = InlineBlockBoxBuilder(child)
      let iblock = child.buildInlineBlock(box.ictx, parentWidth, parentHeight)
      box.ictx.addAtom(iblock, parentWidth, child.computed)
      box.ictx.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  let padding_right = box.computed{"padding-right"}.px(viewport, parentWidth)
  if padding_right > 0:
    # I don't like this, but it works...
    box.ictx.currentLine.addSpacing(padding_right, max(box.ictx.currentLine.height, 1), paddingformat)

  let margin_right = box.computed{"margin-right"}.px(viewport, parentWidth)
  box.ictx.currentLine.width += margin_right

proc buildInlines(bctx: BlockBox, inlines: seq[BoxBuilder]): InlineContext =
  let ictx = bctx.newInlineContext()
  if inlines.len > 0:
    for child in inlines:
      case child.computed{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        child.ictx = ictx
        buildInline(bctx.viewport, child, bctx.compwidth, bctx.compheight)
      of DISPLAY_INLINE_BLOCK:
        let child = InlineBlockBoxBuilder(child)
        let iblock = child.buildInlineBlock(ictx, bctx.compwidth)
        ictx.addAtom(iblock, bctx.compwidth, child.computed)
        ictx.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    ictx.finish(bctx.computed, bctx.compwidth)

  return ictx

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockBox): ListItemBox =
  result = parent.newListItem(builder)

  if builder.marker != nil:
    result.marker = result.buildInlines(@[BoxBuilder(builder.marker)])

  if builder.content.inlinelayout:
    result.buildInlineLayout(builder.content.children)
  else:
    result.buildBlockLayout(builder.content.children, builder.content.node)

proc positionBlocks(bctx: BlockBox) =
  var y = 0
  var x = 0
  var margin_todo: Strut

  y += bctx.padding_top
  bctx.height += bctx.padding_top

  x += bctx.padding_left
  if bctx.computed{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
    x += bctx.compwidth div 2

  template apply_child(child: BlockBox) =
    child.offset.y = y
    child.offset.x = x + child.margin_left
    if bctx.computed{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
      child.offset.x -= child.width div 2
    y += child.height
    bctx.height += child.height
    bctx.width = max(bctx.width, child.width)
    margin_todo = Strut()
    margin_todo.append(child.margin_bottom)

  if bctx.nested.len > 0:
    let child = bctx.nested[0]

    margin_todo.append(bctx.margin_top)
    margin_todo.append(child.margin_top)
    bctx.margin_top = margin_todo.sum()

    apply_child(child)

  var i = 1
  while i < bctx.nested.len:
    let child = bctx.nested[i]

    margin_todo.append(child.margin_top)
    y += margin_todo.sum()
    bctx.height += margin_todo.sum()

    apply_child(child)
    inc i

  margin_todo.append(bctx.margin_bottom)
  bctx.margin_bottom = margin_todo.sum()

  bctx.height += bctx.padding_bottom

  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get

  bctx.width += bctx.padding_left
  bctx.width += bctx.padding_right

proc buildBlocks(bctx: BlockBox, blocks: seq[BoxBuilder], node: Node) =
  for child in blocks:
    var cblock: BlockBox
    case child.computed{"display"}
    of DISPLAY_BLOCK: cblock = buildBlock(BlockBoxBuilder(child), bctx)
    of DISPLAY_LIST_ITEM: cblock = buildListItem(ListItemBoxBuilder(child), bctx)
    else: assert false, "child.t is " & $child.computed{"display"}
    bctx.nested.add(cblock)
  bctx.positionBlocks()

# Build a block box inside another block box, based on a builder.
proc buildBlock(box: BlockBoxBuilder, parent: BlockBox): BlockBox =
  assert parent != nil
  result = parent.newBlockBox(box)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

# Establish a new flow-root context and build a block box.
proc buildRootBlock(box: BlockBoxBuilder, viewport: Viewport): BlockBox =
  result = viewport.newBlockBox(box)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

# Generation phase

#WARNING yes there is a {}= macro but that modifies the computed value
# reference itself and those are copied across arrays...
#TODO figure out something here
proc setDisplay(computed: var CSSComputedValues, display: CSSDisplay) =
  computed[PROPERTY_DISPLAY] = CSSComputedValue(t: PROPERTY_DISPLAY, v: VALUE_DISPLAY, display: display)

# Returns a block box, disregarding the computed value of display
proc getBlockBox(computed: CSSComputedValues): BlockBoxBuilder =
  new(result)
  result.computed = computed.copyProperties()
  result.computed.setDisplay(DISPLAY_BLOCK)

proc getInlineBlockBox(computed: CSSComputedValues): InlineBlockBoxBuilder =
  new(result)
  result.computed = computed.copyProperties()
  result.computed.setDisplay(DISPLAY_INLINE_BLOCK)

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
  result.computed.setDisplay(DISPLAY_INLINE)

  result.ordinalvalue = listItemCounter
  result.text.add(computed{"list-style-type"}.listMarker(result.ordinalvalue))

proc getListItemBox(computed: CSSComputedValues, listItemCounter: int): ListItemBoxBuilder =
  new(result)
  result.computed = computed.copyProperties()
  result.marker = getMarkerBox(computed, listItemCounter)

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: seq[BoxBuilder], computed: CSSComputedValues, str: string): bool =
  return blockgroup.len > 0 and blockgroup[^1].computed{"display"} == DISPLAY_INLINE or
    computed{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
    not str.onlyWhitespace()

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder)): BlockBoxBuilder

template flush_block_group(computed: CSSComputedValues) =
  if blockgroup.len > 0:
    let bbox = getBlockBox(computed.inheritProperties())
    bbox.inlinelayout = true
    bbox.children = blockgroup
    box.children.add(bbox)
    blockgroup.setLen(0)

template flush_ibox() =
  if ibox != nil:
    assert ibox.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK}
    blockgroup.add(ibox)
    ibox = nil

proc generateInlineBoxes(box: BlockBoxBuilder, styledNode: StyledNode, blockgroup: var seq[BoxBuilder], viewport: Viewport, listItemCounter: var int)

proc generateFromElem(box: BlockBoxBuilder, styledNode: StyledNode, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder, listItemCounter: var int) =
  if styledNode.node != nil:
    let elem = Element(styledNode.node)
    if elem.tagType == TAG_BR:
      ibox = box.getTextBox()
      ibox.newline = true
      flush_ibox

  case styledNode.computed{"display"}
  of DISPLAY_BLOCK:
    flush_block_group(styledNode.computed)
    let childbox = styledNode.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    flush_block_group(styledNode.computed)
    let childbox = getListItemBox(styledNode.computed, listItemCounter)
    if childbox.computed{"list-style-position"} == LIST_STYLE_POSITION_INSIDE:
      childbox.content = styledNode.generateBlockBox(viewport, some(childbox.marker))
      childbox.marker = nil
    else:
      childbox.content = styledNode.generateBlockBox(viewport)
    box.children.add(childbox)
    inc listItemCounter
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlineBoxes(styledNode, blockgroup, viewport, listItemCounter)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(styledNode.computed)
    childbox.content = styledNode.generateBlockBox(viewport)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateInlineBoxes(box: BlockBoxBuilder, styledNode: StyledNode, blockgroup: var seq[BoxBuilder], viewport: Viewport, listItemCounter: var int) =
  var ibox: InlineBoxBuilder = nil

  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      box.generateFromElem(child, blockgroup, viewport, ibox, listItemCounter)
    of STYLED_TEXT:
      if ibox == nil:
        ibox = getTextBox(styledNode.computed)
        ibox.node = styledNode.node
      ibox.text.add(child.text)

  flush_ibox

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder)): BlockBoxBuilder =
  let box = getBlockBox(styledNode.computed)
  var blockgroup: seq[BoxBuilder]
  var ibox: InlineBoxBuilder = nil
  var listItemCounter = 1 # ordinal value of current list

  if marker.issome:
    ibox = marker.get
    flush_ibox
  
  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      flush_ibox
      box.generateFromElem(child, blockgroup, viewport, ibox, listItemCounter)
    of STYLED_TEXT:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode.node
        ibox.text.add(child.text)

  flush_ibox
  if blockgroup.len > 0:
    # Avoid unnecessary anonymous block boxes
    if box.children.len == 0:
      box.children = blockgroup
      box.inlinelayout = true
    else:
      flush_block_group(styledNode.computed)
  return box


proc renderLayout*(viewport: var Viewport, document: Document, root: StyledNode) =
  let builder = root.generateBlockBox(viewport)
  viewport.root = buildRootBlock(builder, viewport)
