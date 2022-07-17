import math
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

# p is what to use for percentage values
func cells_in(l: CSSLength, state: Viewport, d: int, p: Option[int], o: bool): int =
  return cells(l, d, state.term, p, o)

func cells_w(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppc, p.some, true)

func cells_h(l: CSSLength, state: Viewport, p: Option[int]): int =
  return l.cells_in(state, state.term.ppl, p, false)

func cells_h(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppl, p.some, false)

func px(l: CSSLength, state: Viewport, p = 0): int {.inline.} =
  return px(l, state.term, p)

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
    if ictx.thisrow.atoms.len > 0 or computed.whitespacepre:
      let spacing = computed{"word-spacing"}
      if spacing.auto:
        return ictx.cellwidth * ictx.whitespacenum
      #return spacing.cells_w(ictx.viewport, 0)
      return spacing.px(ictx.viewport) * ictx.whitespacenum
  return 0

func computeLineHeight(viewport: Viewport, computed: CSSComputedValues): int =
  if computed{"line-height"}.auto:
    return viewport.cellheight
  return computed{"line-height"}.px(viewport, viewport.cellheight)

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

proc horizontalAlignRow(ictx: InlineContext, row: InlineRow, computed: CSSComputedValues, maxwidth: int, last = false) =
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
    let x = max(maxwidth, row.width) - row.width
    for atom in row.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_CENTER:
    let x = max((max(maxwidth - row.offset.x, row.width)) div 2 - row.width div 2, 0)
    for atom in row.atoms:
      atom.offset.x += x
  of TEXT_ALIGN_JUSTIFY:
    if not computed.whitespacepre and not last:
      var sumwidth = 0
      var spaces = 0
      for atom in row.atoms:
        if atom of InlineSpacing:
          discard
        else:
          inc spaces
          sumwidth += atom.width
      dec spaces
      if spaces > 0:
        let spacingwidth = (ictx.maxwidth - sumwidth) div spaces
        row.width = 0
        for atom in row.atoms:
          atom.offset.x = row.width
          if atom of InlineSpacing:
            let atom = InlineSpacing(atom)
            atom.width = spacingwidth
          row.width += atom.width
  else:
    discard

proc verticalAlignRow(ictx: InlineContext) =
  let row = ictx.thisrow
  var baseline = if row.height < row.lineheight:
    let lines = row.lineheight div ictx.cellheight
    int(ceil(lines / 2)) * ictx.cellheight
  else:
    0

  # line-height is the minimum line height
  row.height = max(row.height, row.lineheight)

  for atom in row.atoms:
    case atom.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      let len = atom.vertalign.length.px(ictx.viewport, row.lineheight)
      baseline = max(baseline, atom.height + len)
    of VERTICAL_ALIGN_TOP, VERTICAL_ALIGN_BOTTOM:
      row.height = max(atom.height, row.height)
    of VERTICAL_ALIGN_MIDDLE:
      baseline = max(baseline, atom.height div 2)
    else:
      baseline = max(baseline, atom.height)
  row.height = max(baseline, row.height)

  for atom in row.atoms:
    let diff = case atom.vertalign.keyword
    of VERTICAL_ALIGN_BASELINE:
      let len = atom.vertalign.length.px(ictx.viewport, row.lineheight)
      baseline - atom.height - len
    of VERTICAL_ALIGN_MIDDLE:
      baseline - atom.height div 2
    of VERTICAL_ALIGN_TOP:
      0
    of VERTICAL_ALIGN_BOTTOM:
      row.height - atom.height
    else:
      baseline - atom.height
    atom.offset.y += diff

proc addSpacing(row: InlineRow, width, height: int, format: ComputedFormat) {.inline.} =
  let spacing = InlineSpacing(width: width, height: height, format: format)
  spacing.offset.x = row.width
  row.width += spacing.width
  row.atoms.add(spacing)

proc flushWhitespace(ictx: InlineContext, computed: CSSComputedValues) =
  let shift = ictx.computeShift(computed)
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.thisrow.addSpacing(shift, ictx.cellheight, ictx.format)

proc finishRow(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int, force = false) =
  if ictx.thisrow.atoms.len != 0 or force:
    ictx.flushWhitespace(computed)
    ictx.verticalAlignRow()

    let oldrow = ictx.thisrow
    ictx.rows.add(oldrow)
    ictx.height += oldrow.height
    ictx.maxwidth = max(ictx.maxwidth, oldrow.width)
    ictx.thisrow = InlineRow(offset: Offset(y: oldrow.offset.y + oldrow.height))

proc finish(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int) =
  ictx.finishRow(computed, maxwidth)
  for row in ictx.rows:
    ictx.horizontalAlignRow(row, computed, maxwidth, row == ictx.rows[^1])

proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, computed: CSSComputedValues) =
  var shift = ictx.computeShift(computed)
  ictx.whitespacenum = 0
  # Line wrapping
  if not computed.whitespacepre:
    if ictx.thisrow.width + atom.width + shift > maxwidth:
      ictx.finishRow(computed, maxwidth, false)
      # Recompute on newline
      shift = ictx.computeShift(computed)

  if atom.width > 0 and atom.height > 0:
    atom.vertalign = computed{"vertical-align"}

    if shift > 0:
      ictx.thisrow.addSpacing(shift, ictx.cellheight, ictx.format)

    atom.offset.x += ictx.thisrow.width
    ictx.thisrow.lineheight = max(ictx.thisrow.lineheight, computeLineHeight(ictx.viewport, computed))
    ictx.thisrow.width += atom.width
    ictx.thisrow.height = max(ictx.thisrow.height, atom.height)
    if atom of InlineWord:
      ictx.format = InlineWord(atom).format
    else:
      ictx.format = nil
    ictx.thisrow.atoms.add(atom)

proc addWord(state: var InlineState) =
  if state.word.str != "":
    var word = state.word
    word.height = state.ictx.cellheight
    state.ictx.addAtom(word, state.maxwidth, state.computed)
    state.newWord()

# Start a new line, even if the previous one is empty
proc flushLine(ictx: InlineContext, computed: CSSComputedValues, maxwidth: int) =
  ictx.thisrow.lineheight = computeLineHeight(ictx.viewport, computed)
  ictx.finishRow(computed, maxwidth, true)

proc checkWrap(state: var InlineState, r: Rune) =
  if state.computed{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  let shift = state.ictx.computeShift(state.computed)
  case state.computed{"word-break"}
  of WORD_BREAK_BREAK_ALL:
    if state.ictx.thisrow.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.addWord()
      state.ictx.finishRow(state.computed, state.maxwidth, false)
      state.ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    if state.ictx.thisrow.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.ictx.finishRow(state.computed, state.maxwidth, false)
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
    #bctx.compheight = pheight.cells_h(bctx.viewport, height).some
    if pheight.unit != UNIT_PERC:
      result.compheight = pheight.px(viewport).some
    elif height.issome:
      result.compheight = pheight.px(viewport, height.get).some

proc setPreferredDimensions(bctx: BlockContext, width: int, height: Option[int]) =
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

proc newBlockContext_common2(bctx: BlockContext, parent: BlockContext, box: BoxBuilder) {.inline.} =
  bctx.viewport = parent.viewport
  bctx.computed = box.computed
  bctx.setPreferredDimensions(parent.compwidth, parent.compheight)

proc newBlockContext_common(parent: BlockContext, box: BoxBuilder): BlockContext {.inline.} =
  new(result)
  result.newBlockContext_common2(parent, box)

proc newBlockContext(parent: BlockContext, box: BlockBoxBuilder): BlockContext =
  result = newBlockContext_common(parent, box)
  result.shrink = result.computed{"width"}.auto and parent.shrink

proc newListItem(parent: BlockContext, builder: ListItemBoxBuilder): ListItem =
  new(result)
  result.newBlockContext_common2(parent, builder.content)
  result.shrink = result.computed{"width"}.auto and parent.shrink

proc newInlineBlockContext(parent: BlockContext, builder: InlineBlockBoxBuilder): BlockContext =
  result = newBlockContext_common(parent, builder.content)
  result.shrink = result.computed{"width"}.auto

proc newInlineBlock(parent: BlockContext, builder: InlineBlockBoxBuilder): InlineBlock =
  new(result)
  result.bctx = parent.newInlineBlockContext(builder)

proc newBlockContext(viewport: Viewport, box: BlockBoxBuilder): BlockContext =
  new(result)
  result.viewport = viewport
  result.computed = box.computed
  result.setPreferredDimensions(viewport.term.width_px, none(int))
  result.shrink = result.computed{"width"}.auto

proc newInlineContext(bctx: BlockContext): InlineContext =
  new(result)
  result.thisrow = InlineRow()
  result.viewport = bctx.viewport
  result.shrink = bctx.shrink

proc positionInlines(bctx: BlockContext) =
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

proc buildBlock(box: BlockBoxBuilder, parent: BlockContext): BlockContext
proc buildInlines(bctx: BlockContext, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(bctx: BlockContext, blocks: seq[BoxBuilder], node: Node)

proc applyInlineDimensions(bctx: BlockContext) =
  bctx.height += bctx.inline.height
  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get
  bctx.width = max(bctx.width, bctx.inline.maxwidth)

# Builder only contains inline boxes.
proc buildInlineLayout(bctx: BlockContext, children: seq[BoxBuilder]) =
  bctx.inline = bctx.buildInlines(children)
  bctx.applyInlineDimensions()
  bctx.positionInlines()

proc buildBlockLayout(bctx: BlockContext, children: seq[BoxBuilder], node: Node) =
  bctx.buildBlocks(children, node)

proc buildInlineBlock(builder: InlineBlockBoxBuilder, parent: InlineContext, parentblock: BlockContext): InlineBlock =
  assert builder.content != nil
  result = parentblock.newInlineBlock(builder)

  let blockbuilder = builder.content
  if blockbuilder.inlinelayout:
    result.bctx.buildInlineLayout(blockbuilder.children)
  else:
    # Builder only contains block boxes.
    result.bctx.buildBlocks(blockbuilder.children, blockbuilder.node)

  let preferred = preferredDimensions(builder.computed, parentblock.viewport, parentblock.compwidth, parentblock.compheight)
  let pwidth = builder.computed{"width"}
  if pwidth.auto:
    # Half-baked shrink-to-fit
    result.bctx.width = min(max(result.bctx.width, parent.maxwidth), preferred.compwidth)
  else:
    result.bctx.width = preferred.compwidth

  # Set inline block dimensions,
  result.width = result.bctx.width
  result.height = result.bctx.height

  # Plus margins, for the final result.
  result.width += result.bctx.margin_left
  result.height += result.bctx.margin_top
  result.width += result.bctx.margin_right
  result.height += result.bctx.margin_bottom

  # Set offset here because positionInlines will reset it.
  result.bctx.offset.x = result.bctx.margin_left
  result.bctx.offset.y = result.bctx.margin_top

proc buildInline(bctx: BlockContext, box: InlineBoxBuilder) =
  assert box.ictx != nil
  if box.newline:
    box.ictx.flushLine(bctx.computed, bctx.compwidth)

  let margin_left = box.computed{"margin-left"}.px(bctx.viewport, bctx.compwidth)
  box.ictx.thisrow.width += margin_left

  let paddingformat = ComputedFormat(node: box.node)
  let padding_left = box.computed{"padding-left"}.px(bctx.viewport, bctx.compwidth)
  if padding_left > 0:
    box.ictx.thisrow.addSpacing(padding_left, box.ictx.cellheight, paddingformat)

  for text in box.text:
    assert box.children.len == 0
    box.ictx.renderText(text, bctx.compwidth, box.computed, box.node)

  for child in box.children:
    case child.computed{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      child.ictx = box.ictx
      bctx.buildInline(child)
    of DISPLAY_INLINE_BLOCK:
      let child = InlineBlockBoxBuilder(child)
      let iblock = child.buildInlineBlock(box.ictx, bctx)
      box.ictx.addAtom(iblock, bctx.compwidth, child.computed)
      box.ictx.whitespacenum = 0
    else:
      assert false, "child.t is " & $child.computed{"display"}

  let padding_right = box.computed{"padding-right"}.px(bctx.viewport, bctx.compwidth)
  if padding_right > 0:
    box.ictx.thisrow.addSpacing(padding_right, max(box.ictx.thisrow.height, 1), paddingformat)

  let margin_right = box.computed{"margin-right"}.px(bctx.viewport, bctx.compwidth)
  box.ictx.thisrow.width += margin_right

proc buildInlines(bctx: BlockContext, inlines: seq[BoxBuilder]): InlineContext =
  let ictx = bctx.newInlineContext()
  if inlines.len > 0:
    for child in inlines:
      case child.computed{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        child.ictx = ictx
        bctx.buildInline(child)
      of DISPLAY_INLINE_BLOCK:
        let child = InlineBlockBoxBuilder(child)
        let iblock = child.buildInlineBlock(ictx, bctx)
        ictx.addAtom(iblock, bctx.compwidth, child.computed)
        ictx.whitespacenum = 0
      else:
        assert false, "child.t is " & $child.computed{"display"}
    ictx.finish(bctx.computed, bctx.compwidth)

  return ictx

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockContext): ListItem =
  result = parent.newListItem(builder)
  result.marker = result.buildInlines(@[BoxBuilder(builder.marker)])
  if builder.content.inlinelayout:
    result.buildInlineLayout(builder.content.children)
  else:
    result.buildBlockLayout(builder.content.children, builder.content.node)

# Blocks' positions do not have to be positioned if buildBlocks is called with
# children, whence the separate procedure.
proc positionBlocks(bctx: BlockContext) =
  var y = 0
  var x = 0
  var margin_todo: Strut

  y += bctx.padding_top
  bctx.height += bctx.padding_top

  x += bctx.padding_left
  if bctx.computed{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
    x += bctx.compwidth div 2

  template apply_child(child: BlockContext) =
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


proc buildBlocks(bctx: BlockContext, blocks: seq[BoxBuilder], node: Node) =
  for child in blocks:
    var cblock: BlockContext
    case child.computed{"display"}
    of DISPLAY_BLOCK: cblock = buildBlock(BlockBoxBuilder(child), bctx)
    of DISPLAY_LIST_ITEM: cblock = buildListItem(ListItemBoxBuilder(child), bctx)
    else: assert false, "child.t is " & $child.computed{"display"}
    bctx.nested.add(cblock)
  bctx.positionBlocks()

# Build a block box inside another block box, based on a builder.
proc buildBlock(box: BlockBoxBuilder, parent: BlockContext): BlockContext =
  assert parent != nil
  result = parent.newBlockContext(box)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlockLayout(box.children, box.node)

# Establish a new flow-root context and build a block box.
proc buildRootBlock(box: BlockBoxBuilder, viewport: Viewport): BlockContext =
  result = viewport.newBlockContext(box)
  if box.inlinelayout:
    result.buildInlineLayout(box.children)
  else:
    result.buildBlocks(box.children, box.node)

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

  if result.computed{"display"} == DISPLAY_LIST_ITEM:
    result.ordinalvalue = listItemCounter
  else:
    result.ordinalvalue = 1
  if computed{"list-style-position"} == LIST_STYLE_POSITION_INSIDE:
    result.inside = true
  result.text.add(computed{"list-style-type"}.listMarker(result.ordinalvalue))

proc getListItemBox(computed: CSSComputedValues, listItemCounter: int): ListItemBoxBuilder =
  new(result)
  result.computed = computed.copyProperties()
  result.marker = getMarkerBox(computed, listItemCounter)

func getInputBox(parent: BoxBuilder, input: HTMLInputElement): InlineBoxBuilder =
  let textbox = parent.getTextBox()
  textbox.node = input
  textbox.text.add(input.inputString())
  return textbox

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: seq[BoxBuilder], computed: CSSComputedValues, str: string): bool =
  return blockgroup.len > 0 and blockgroup[^1].computed{"display"} == DISPLAY_INLINE or
    computed{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
    not str.onlyWhitespace()

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport): BlockBoxBuilder

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

proc generateInlineBoxes(box: BlockBoxBuilder, styledNode: StyledNode, blockgroup: var seq[BoxBuilder], viewport: Viewport)

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
    childbox.content = styledNode.generateBlockBox(viewport)
    box.children.add(childbox)
    inc listItemCounter
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlineBoxes(styledNode, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(box.computed)
    childbox.content = styledNode.generateBlockBox(viewport)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateInlineBoxes(box: BlockBoxBuilder, styledNode: StyledNode, blockgroup: var seq[BoxBuilder], viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil
  var listItemCounter = 1 # ordinal value of current list

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

proc generateBlockBox(styledNode: StyledNode, viewport: Viewport): BlockBoxBuilder =
  let elem = Element(styledNode.node)
  let box = getBlockBox(styledNode.computed)
  var blockgroup: seq[BoxBuilder]
  var ibox: InlineBoxBuilder = nil
  var listItemCounter = 1 # ordinal value of current list
  
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
