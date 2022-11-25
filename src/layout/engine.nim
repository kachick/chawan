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
  computed{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_WRAP}

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

proc newBlockBox_common2(box: BlockBox, parent: BlockBox, builder: BoxBuilder) {.inline.} =
  box.viewport = parent.viewport
  box.computed = builder.computed
  box.setPreferredDimensions(parent.compwidth, parent.compheight)

proc newFlowRootBox(viewport: Viewport, box: BoxBuilder, parentWidth: int, parentHeight = none(int)): BlockBox {.inline.} =
  new(result)
  result.viewport = viewport
  result.computed = box.computed
  result.setPreferredDimensions(parentWidth, parentHeight)
  result.shrink = result.computed{"width"}.auto

proc newBlockBox(parent: BlockBox, box: BoxBuilder, ignore_parent_shrink = false): BlockBox =
  new(result)
  result.newBlockBox_common2(parent, box)
  result.shrink = result.computed{"width"}.auto and (ignore_parent_shrink or parent.shrink)

proc newTableCellBox(parent: BlockBox, box: TableCellBoxBuilder): BlockBox =
  return newBlockBox(parent, box, true)

proc newTableRowBox(parent: BlockBox, box: TableRowBoxBuilder): BlockBox =
  return newBlockBox(parent, box)

proc newTableBox(parent: BlockBox, box: TableBoxBuilder): BlockBox =
  let table = newBlockBox(parent, box)
  if box.width.isSome:
    table.compwidth = box.width.get.px(parent.viewport, parent.compwidth)
  return table

proc newListItem(parent: BlockBox, builder: ListItemBoxBuilder): ListItemBox =
  new(result)
  result.newBlockBox_common2(parent, builder.content)

proc newBlockBox(viewport: Viewport, box: BlockBoxBuilder): BlockBox =
  return newFlowRootBox(viewport, box, viewport.window.width_px)

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
    if bctx.shrink:
      bctx.width = min(bctx.width, bctx.compwidth)
    else:
      bctx.width = max(bctx.width, bctx.compwidth)
  else:
    bctx.width = bctx.compwidth

proc buildBlock(box: BlockBoxBuilder, parent: BlockBox): BlockBox
proc buildInlines(bctx: BlockBox, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(bctx: BlockBox, blocks: seq[BoxBuilder], node: StyledNode)

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
proc buildBlockLayout(bctx: BlockBox, children: seq[BoxBuilder], node: StyledNode) =
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

  assert not (box.children.len > 0 and box.text.len > 0)
  for text in box.text:
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
  if bctx.computed{"text-align"} == TEXT_ALIGN_CHA_CENTER:
    x += bctx.compwidth div 2

  template apply_child(child: BlockBox) =
    child.offset.y = y
    child.offset.x = x + child.margin_left
    if bctx.computed{"text-align"} == TEXT_ALIGN_CHA_CENTER:
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

proc buildTableCell(box: TableCellBoxBuilder, parent: BlockBox, cellwidth = none(int)): BlockBox =
  result = parent.newTableCellBox(box)
  if cellwidth.isSome:
    result.compwidth = cellwidth.get
    result.shrink = true
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

proc preBuildTableRow(pctx: var TableContext, box: TableRowBoxBuilder, parent: BlockBox): RowContext =
  var ctx = RowContext(builder: box, cells: newSeq[CellWrapper](box.children.len))
  if pctx.colwidths.len < box.children.len:
    pctx.colwidths.setLen(box.children.len)
  var n = 0
  var i = 0
  var rctx: RowContext
  for child in box.children:
    assert child.computed{"display"} == DISPLAY_TABLE_CELL
    let cellbuilder = TableCellBoxBuilder(child)
    let cell = buildTableCell(cellbuilder, parent)
    ctx.cells[i] = CellWrapper(box: cell, builder: cellbuilder, colspan: cellbuilder.colspan)
    let pwidth = cellbuilder.computed{"width"}
    if pctx.colwidths.len <= n:
      pctx.colwidths.setLen(n + 1)
    if pctx.colwidths_specified.len <= n:
      if not pwidth.auto:
        pctx.colwidths_specified.setLen(n + 1)
    for i in n ..< n + cellbuilder.colspan:
      pctx.colwidths[i] = max(cell.width div cellbuilder.colspan, pctx.colwidths[i])
      if not pwidth.auto:
        pctx.colwidths_specified[i] = cell.compwidth
    n += cellbuilder.colspan
    ctx.width += cell.width
    inc i
  return ctx

proc buildTableRow(pctx: TableContext, ctx: RowContext, parent: BlockBox, builder: TableRowBoxBuilder): BlockBox =
  var x = 0
  var n = 0
  let row = newTableRowBox(parent, builder)
  for cellw in ctx.cells:
    var cell = cellw.box
    cell.offset.x += x
    var w = 0
    for i in n ..< n + cellw.colspan:
      w += pctx.colwidths[i]
    x += w
    if pctx.reflow.len > n:
      for i in n ..< min(n + cellw.colspan, pctx.reflow.len):
        if pctx.reflow[i]:
          cell = buildTableCell(cellw.builder, parent, some(w))
    n += cellw.colspan
    row.nested.add(cell)
    row.height = max(row.height, cell.height)
  row.width = x
  return row

iterator rows(builder: TableBoxBuilder): TableRowBoxBuilder =
  for child in builder.children:
    assert child.computed{"display"} in {DISPLAY_TABLE_ROW, DISPLAY_TABLE_ROW_GROUP}
    case child.computed{"display"}
    of DISPLAY_TABLE_ROW:
      yield TableRowBoxBuilder(child)
    of DISPLAY_TABLE_ROW_GROUP:
      for child in TableRowGroupBoxBuilder(child).children:
        assert child.computed{"display"} == DISPLAY_TABLE_ROW
        yield TableRowBoxBuilder(child)
    else: discard

proc buildTable(box: TableBoxBuilder, parent: BlockBox): BlockBox =
  let table = parent.newTableBox(box)
  var ctx: TableContext
  var maxw = 0
  for row in box.rows:
    let rctx = ctx.preBuildTableRow(row, table)
    ctx.rows.add(rctx)
    maxw = max(rctx.width, maxw)
  if maxw > table.compwidth and false: #TODO
    for n in ctx.colwidths_specified:
      maxw -= n
    ctx.reflow.setLen(ctx.colwidths.len)
    for i in 0 ..< ctx.colwidths.len:
      if ctx.colwidths[i] != 0:
        ctx.colwidths[i] -= (maxw - table.compwidth) div ctx.colwidths[i]
        ctx.reflow[i] = true
  for roww in ctx.rows:
    let row = ctx.buildTableRow(roww, table, roww.builder)
    row.offset.y += table.height
    table.height += row.height
    table.nested.add(row)
    table.width = max(row.width, table.width)
  return table

proc buildBlocks(bctx: BlockBox, blocks: seq[BoxBuilder], node: StyledNode) =
  for child in blocks:
    var cblock: BlockBox
    case child.computed{"display"}
    of DISPLAY_BLOCK: cblock = buildBlock(BlockBoxBuilder(child), bctx)
    of DISPLAY_LIST_ITEM: cblock = buildListItem(ListItemBoxBuilder(child), bctx)
    of DISPLAY_TABLE: cblock = buildTable(TableBoxBuilder(child), bctx)
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
  result.shrink = false
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

type BlockGroup = object
  parent: BoxBuilder
  boxes: seq[BoxBuilder]
  listItemCounter: int

proc add(blockgroup: var BlockGroup, box: BoxBuilder) {.inline.} =
  blockgroup.boxes.add(box)

proc flush(blockgroup: var BlockGroup) {.inline.} =
  if blockgroup.boxes.len > 0:
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

template flush_ibox() =
  if ibox != nil:
    assert ibox.computed{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK}
    blockgroup.add(ibox)
    ibox = nil

proc newBlockGroup(parent: BoxBuilder): BlockGroup =
  result.parent = parent
  result.listItemCounter = 1

proc generateTableBox(styledNode: StyledNode, viewport: Viewport): TableBoxBuilder
proc generateTableRowGroupBox(styledNode: StyledNode, viewport: Viewport): TableRowGroupBoxBuilder
proc generateTableRowBox(styledNode: StyledNode, viewport: Viewport): TableRowBoxBuilder
proc generateTableCellBox(styledNode: StyledNode, viewport: Viewport): TableCellBoxBuilder

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder)): BlockBoxBuilder

proc generateInlineBoxes(box: BoxBuilder, styledNode: StyledNode, blockgroup: var BlockGroup, viewport: Viewport)


proc generateFromElem(styledNode: StyledNode, blockgroup: var BlockGroup, viewport: Viewport, ibox: var InlineBoxBuilder) =
  let box = blockgroup.parent
  if styledNode.node != nil:
    let elem = Element(styledNode.node)
    if elem.tagType == TAG_BR:
      ibox = box.getTextBox()
      ibox.newline = true
      flush_ibox

  case styledNode.computed{"display"}
  of DISPLAY_BLOCK:
    blockgroup.flush()
    let childbox = styledNode.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    blockgroup.flush()
    let childbox = getListItemBox(styledNode.computed, blockgroup.listItemCounter)
    if childbox.computed{"list-style-position"} == LIST_STYLE_POSITION_INSIDE:
      childbox.content = styledNode.generateBlockBox(viewport, some(childbox.marker))
      childbox.marker = nil
    else:
      childbox.content = styledNode.generateBlockBox(viewport)
    box.children.add(childbox)
    inc blockgroup.listItemCounter
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlineBoxes(styledNode, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(styledNode.computed)
    childbox.content = styledNode.generateBlockBox(viewport)
    blockgroup.add(childbox)
  of DISPLAY_TABLE:
    blockgroup.flush()
    let childbox = styledNode.generateTableBox(viewport)
    box.children.add(childbox)
  of DISPLAY_TABLE_ROW:
    blockgroup.flush()
    let childbox = styledNode.generateTableRowBox(viewport)
    box.children.add(childbox)
  of DISPLAY_TABLE_ROW_GROUP:
    blockgroup.flush()
    let childbox = styledNode.generateTableRowGroupBox(viewport)
    box.children.add(childbox)
  of DISPLAY_TABLE_CELL:
    blockgroup.flush()
    let childbox = styledNode.generateTableCellBox(viewport)
    box.children.add(childbox)
  of DISPLAY_TABLE_COLUMN:
    discard #TODO
  of DISPLAY_TABLE_COLUMN_GROUP:
    discard #TODO
  of DISPLAY_NONE: discard
  else:
    discard #TODO

proc generateInlineBoxes(box: BoxBuilder, styledNode: StyledNode, blockgroup: var BlockGroup, viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil

  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      generateFromElem(child, blockgroup, viewport, ibox)
    of STYLED_TEXT:
      if ibox == nil:
        ibox = getTextBox(styledNode.computed)
        ibox.node = styledNode
      ibox.text.add(child.text)

  flush_ibox

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport, marker = none(MarkerBoxBuilder)): BlockBoxBuilder =
  let box = getBlockBox(styledNode.computed)
  var blockgroup = newBlockGroup(box)
  var ibox: InlineBoxBuilder = nil

  if marker.issome:
    ibox = marker.get
    flush_ibox
  
  for child in styledNode.children:
    case child.t
    of STYLED_ELEMENT:
      flush_ibox
      generateFromElem(child, blockgroup, viewport, ibox)
    of STYLED_TEXT:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode
        ibox.text.add(child.text)

  flush_ibox
  if blockgroup.boxes.len > 0:
    # Avoid unnecessary anonymous block boxes
    if box.children.len == 0:
      box.children = blockgroup.boxes
      box.inlinelayout = true
    else:
      blockgroup.flush()
  return box

const RowGroupBox = {DISPLAY_TABLE_ROW_GROUP, DISPLAY_TABLE_HEADER_GROUP,
                     DISPLAY_TABLE_FOOTER_GROUP}
const ProperTableChild = {DISPLAY_TABLE_ROW, DISPLAY_TABLE_COLUMN,
                          DISPLAY_TABLE_COLUMN_GROUP} + RowGroupBox
const ProperTableRowParent = {DISPLAY_TABLE, DISPLAY_INLINE_TABLE} + RowGroupBox
const InternalTableBox = {DISPLAY_TABLE_CELL, DISPLAY_TABLE_ROW, DISPLAY_TABLE_COLUMN, DISPLAY_TABLE_COLUMN_GROUP} + RowGroupBox
const TabularContainer = {DISPLAY_TABLE_ROW} + ProperTableRowParent

# Whether an internal table box is misparented.
func isMisparented(box: BoxBuilder, parent: BoxBuilder): bool =
  case box.computed{"display"}
  of DISPLAY_TABLE_ROW:
    return parent.computed{"display"} notin {DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE, DISPLAY_INLINE_TABLE}
  of DISPLAY_TABLE_COLUMN:
    return parent.computed{"display"} notin {DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE, DISPLAY_INLINE_TABLE}
  of RowGroupBox, DISPLAY_TABLE_COLUMN_GROUP, DISPLAY_TABLE_CAPTION:
    return parent.computed{"display"} notin {DISPLAY_TABLE, DISPLAY_INLINE_TABLE}
  else: assert false

proc generateTableCellBox(styledNode: StyledNode, viewport: Viewport): TableCellBoxBuilder =
  let box = getTableCellBox(styledNode.computed)
  if styledNode.node != nil and styledNode.node.nodeType == ELEMENT_NODE:
    box.colspan = Element(styledNode.node).attri("colspan").get(1)
  var blockgroup = newBlockGroup(box)
  var ibox: InlineBoxBuilder = nil
  for child in styledNode.children:
    if child.t == STYLED_ELEMENT:
      flush_ibox
      generateFromElem(child, blockgroup, viewport, ibox)
    else:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode
        ibox.text.add(child.text)
  flush_ibox
  if blockgroup.boxes.len > 0:
    # Avoid unnecessary anonymous block boxes
    if box.children.len == 0:
      box.children = blockgroup.boxes
      box.inlinelayout = true
    else:
      blockgroup.flush()
  return box

proc generateTableRowChildWrappers(box: TableRowBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals.setDisplay(DISPLAY_TABLE_CELL)
  for child in box.children:
    if child.computed{"display"} == DISPLAY_TABLE_CELL:
      newchildren.add(child)
    else:
      let wrapper = getTableCellBox(wrappervals)
      wrapper.children.add(child)
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowBox(styledNode: StyledNode, viewport: Viewport): TableRowBoxBuilder =
  let box = getTableRowBox(styledNode.computed)
  var blockgroup = newBlockGroup(box)
  var ibox: InlineBoxBuilder = nil
  for child in styledNode.children:
    if child.t == STYLED_ELEMENT:
      generateFromElem(child, blockgroup, viewport, ibox)
    else:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode
        ibox.text.add(child.text)
  return box

proc generateTableRowGroupChildWrappers(box: TableRowGroupBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals.setDisplay(DISPLAY_TABLE_CELL)
  for child in box.children:
    if child.computed{"display"} == DISPLAY_TABLE_ROW:
      newchildren.add(child)
    else:
      let wrapper = getTableRowBox(wrappervals)
      wrapper.children.add(child)
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableRowGroupBox(styledNode: StyledNode, viewport: Viewport): TableRowGroupBoxBuilder =
  let box = getTableRowGroupBox(styledNode.computed)
  var blockgroup = newBlockGroup(box)
  var ibox: InlineBoxBuilder = nil
  for child in styledNode.children:
    if child.t == STYLED_ELEMENT:
      generateFromElem(child, blockgroup, viewport, ibox)
    else:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode
        ibox.text.add(child.text)
  return box

proc generateTableChildWrappers(box: TableBoxBuilder) =
  var newchildren = newSeqOfCap[BoxBuilder](box.children.len)
  var wrappervals = box.computed.inheritProperties()
  wrappervals.setDisplay(DISPLAY_TABLE_ROW)
  for child in box.children:
    if child.computed{"display"} in ProperTableChild:
      newchildren.add(child)
    else:
      let wrapper = getTableRowBox(wrappervals)
      wrapper.children.add(child)
      wrapper.generateTableRowChildWrappers()
      newchildren.add(wrapper)
  box.children = newchildren

proc generateTableBox(styledNode: StyledNode, viewport: Viewport): TableBoxBuilder =
  let box = getTableBox(styledNode.computed)
  var blockgroup = newBlockGroup(box) #TODO this probably shouldn't exist
  if styledNode.node != nil and styledNode.node.nodeType == ELEMENT_NODE:
    #TODO put this in dom or something
    let s = Element(styledNode.node).attr("width")
    box.width = parseDimensionValues(s)
  var ibox: InlineBoxBuilder = nil
  var listItemCounter = 1
  for child in styledNode.children:
    if child.t == STYLED_ELEMENT:
      generateFromElem(child, blockgroup, viewport, ibox)
    else:
      if canGenerateAnonymousInline(blockgroup, box.computed, child.text):
        if ibox == nil:
          ibox = getTextBox(styledNode.computed)
          ibox.node = styledNode
        ibox.text.add(child.text)
  flush_ibox
  blockgroup.flush()
  box.generateTableChildWrappers()
  #TODO generate missing parents
  return box

proc renderLayout*(viewport: var Viewport, document: Document, root: StyledNode) =
  let builder = root.generateBlockBox(viewport)
  viewport.root = buildRootBlock(builder, viewport)
