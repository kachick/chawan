import math
import options
import unicode

import layout/box
import html/tags
import html/dom
import css/values
import utils/twtstr
import io/term

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

# Build phase

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

# Blocks' positions do not have to be positiond if buildBlocks is called with
# children, whence the separate procedure.
proc positionBlocks(bctx: BlockContext, selfcontained: bool) =
  var y = 0
  var x = 0
  var margin_todo = 0

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
    margin_todo = child.margin_bottom

  var i = 0
  if i < bctx.nested.len:
    let child = bctx.nested[i]

    bctx.margin_top = child.margin_top
    let mtop = bctx.computed{"margin-top"}.px(bctx.viewport, bctx.compwidth)
    if mtop > bctx.margin_top or mtop < 0:
      bctx.margin_top = mtop - bctx.margin_top

    if selfcontained:
      margin_todo = bctx.margin_top
      bctx.height += margin_todo
      y += margin_todo

    apply_child(child)
    inc i

  while i < bctx.nested.len:
    let child = bctx.nested[i]

    if child.margin_top > margin_todo or child.margin_top < 0:
      margin_todo += child.margin_top - margin_todo
    y += margin_todo
    bctx.height += margin_todo

    apply_child(child)
    inc i

  bctx.margin_bottom = margin_todo
  let mbot = bctx.computed{"margin-bottom"}.px(bctx.viewport, bctx.compwidth)
  if mbot > bctx.margin_bottom or mbot < 0:
    bctx.margin_bottom = mbot - bctx.margin_bottom

  if selfcontained:
    bctx.height += bctx.margin_bottom

  bctx.height += bctx.padding_bottom

  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get

  bctx.width += bctx.padding_left
  bctx.width += bctx.padding_right

proc positionInlines(bctx: BlockContext, selfcontained: bool) =
  bctx.margin_top = bctx.computed{"margin-top"}.px(bctx.viewport, bctx.compwidth)
  bctx.margin_bottom = bctx.computed{"margin-bottom"}.px(bctx.viewport, bctx.compwidth)

  bctx.width += bctx.padding_left
  bctx.inline.offset.x += bctx.padding_left

  if selfcontained:
    bctx.inline.offset.x += bctx.margin_top
    bctx.height += bctx.margin_top
    bctx.height += bctx.margin_bottom

  bctx.height += bctx.padding_top
  bctx.inline.offset.x += bctx.padding_top

  bctx.height += bctx.padding_bottom

  bctx.width += bctx.padding_right

  if bctx.computed{"width"}.auto:
    bctx.width = min(bctx.width, bctx.compwidth)
  else:
    bctx.width = bctx.compwidth

proc buildBlock(box: BlockBoxBuilder, parent: BlockContext, selfcontained = false): BlockContext
proc buildInlines(bctx: BlockContext, inlines: seq[BoxBuilder]): InlineContext
proc buildBlocks(bctx: BlockContext, blocks: seq[BoxBuilder], node: Node)

proc applyInlineDimensions(bctx: BlockContext) =
  bctx.height += bctx.inline.height
  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get
  bctx.width = max(bctx.width, bctx.inline.maxwidth)

proc buildInlineBlock(builder: InlineBlockBoxBuilder, parent: InlineContext, parentblock: BlockContext): InlineBlock =
  assert builder.content != nil
  result = parentblock.newInlineBlock(builder)

  let blockbuilder = builder.content
  if blockbuilder.inlinelayout:
    # Builder only contains inline boxes.
    result.bctx.inline = result.bctx.buildInlines(blockbuilder.children)
    result.bctx.applyInlineDimensions()
    result.bctx.positionInlines(false)
  else:
    # Builder only contains block boxes.
    result.bctx.buildBlocks(blockbuilder.children, blockbuilder.node)
    result.bctx.positionBlocks(false)

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

proc buildListItem(builder: ListItemBoxBuilder, parent: BlockContext, selfcontained = false): ListItem =
  result = parent.newListItem(builder)
  var tmp: seq[BoxBuilder]
  tmp.add(builder.marker)
  result.marker = result.buildInlines(tmp)
  if builder.content.inlinelayout:
    # Builder only contains inline boxes.
    result.inline = result.buildInlines(builder.content.children)
    result.applyInlineDimensions()
    result.positionInlines(selfcontained)
  else:
    # Builder only contains block boxes.
    result.buildBlocks(builder.content.children, builder.content.node)
    result.positionBlocks(selfcontained)

proc buildBlocks(bctx: BlockContext, blocks: seq[BoxBuilder], node: Node) =
  for child in blocks:
    case child.computed{"display"}
    of DISPLAY_BLOCK:
      bctx.nested.add(buildBlock(BlockBoxBuilder(child), bctx))
    of DISPLAY_LIST_ITEM:
      bctx.nested.add(buildListItem(ListItemBoxBuilder(child), bctx))
    else:
      assert false, "child.t is " & $child.computed{"display"}

# Build a block box inside another block box, based on a builder.
proc buildBlock(box: BlockBoxBuilder, parent: BlockContext, selfcontained = false): BlockContext =
  assert parent != nil
  result = parent.newBlockContext(box)
  if box.inlinelayout:
    # Builder only contains inline boxes.
    result.inline = result.buildInlines(box.children)
    result.applyInlineDimensions()
    result.positionInlines(selfcontained)
  else:
    # Builder only contains block boxes.
    result.buildBlocks(box.children, box.node)
    result.positionBlocks(selfcontained)

# Build a block box whose parent is the viewport, based on a builder.
proc buildBlock(box: BlockBoxBuilder, viewport: Viewport, selfcontained = false): BlockContext =
  result = viewport.newBlockContext(box)
  if box.inlinelayout:
    # Builder only contains inline boxes.
    result.inline = result.buildInlines(box.children)
    result.applyInlineDimensions()
    result.positionInlines(selfcontained)
  else:
    # Builder only contains block boxes.
    result.buildBlocks(box.children, box.node)
    result.positionBlocks(selfcontained)

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

proc getMarkerBox(elem: Element): MarkerBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.computed = elem.css.inheritProperties()
  result.computed.setDisplay(DISPLAY_INLINE)

  if elem.tagType == TAG_LI:
    result.ordinalvalue = HTMLLIElement(elem).ordinalvalue
  else:
    result.ordinalvalue = 1
  if elem.css{"list-style-position"} == LIST_STYLE_POSITION_INSIDE:
    result.inside = true
  result.text.add(elem.css{"list-style-type"}.listMarker(result.ordinalvalue))

proc getListItemBox(elem: Element): ListItemBoxBuilder =
  assert elem.css{"display"} == DISPLAY_LIST_ITEM
  new(result)
  result.computed = elem.css.copyProperties()
  result.marker = getMarkerBox(elem)

func getInputBox(parent: BoxBuilder, input: HTMLInputElement, viewport: Viewport): InlineBoxBuilder =
  let textbox = parent.getTextBox()
  textbox.node = input
  textbox.text.add(input.inputString())
  return textbox

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: seq[BoxBuilder], computed: CSSComputedValues, text: Text): bool =
  return blockgroup.len > 0 and blockgroup[^1].computed{"display"} == DISPLAY_INLINE or
    computed{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
    not text.data.onlyWhitespace()

proc generateBlockBox(elem: Element, viewport: Viewport): BlockBoxBuilder

template flush_block_group3(computed: CSSComputedValues) =
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

proc generateInlineBoxes(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport)

proc generateFromElem(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder) =
  if elem.tagType == TAG_BR:
    ibox = box.getTextBox()
    ibox.newline = true
    flush_ibox

  case elem.css{"display"}
  of DISPLAY_BLOCK:
    flush_block_group3(elem.css)
    let childbox = elem.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    flush_block_group3(elem.css)
    let childbox = getListItemBox(elem)
    childbox.content = elem.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlineBoxes(elem, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(box.computed)
    childbox.content = elem.generateBlockBox(viewport)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateInlinePseudoBox(box: BlockBoxBuilder, computed: CSSComputedValues, blockgroup: var seq[BoxBuilder], viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil

  if computed{"content"}.len > 0:
    ibox = getTextBox(computed)
    ibox.text.add($computed{"content"})

  flush_ibox

proc generateBlockPseudoBox(computed: CSSComputedValues, viewport: Viewport): BlockBoxBuilder =
  let box = getBlockBox(computed)
  var blockgroup: seq[BoxBuilder]
  var ibox: InlineBoxBuilder = nil

  if computed{"content"}.len > 0:
    ibox = getTextBox(computed)
    ibox.text.add($computed{"content"})
    flush_ibox
    flush_block_group3(computed)

  return box

proc generatePseudo(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder, computed: CSSComputedValues) =
  case computed{"display"}
  of DISPLAY_BLOCK:
    flush_block_group3(elem.css)
    let childbox = generateBlockPseudoBox(computed, viewport)
    box.children.add(childbox)
  of DISPLAY_LIST_ITEM:
    flush_block_group3(elem.css)
    let childbox = getListItemBox(elem)
    childbox.content = elem.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlinePseudoBox(computed, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(box.computed)
    childbox.content = generateBlockPseudoBox(computed, viewport)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateBoxBefore(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder) =
  if elem.pseudo[PSEUDO_BEFORE] != nil:
    box.generatePseudo(elem, blockgroup, viewport, ibox, elem.pseudo[PSEUDO_BEFORE])

  if elem.tagType == TAG_INPUT:
    flush_ibox
    let input = HTMLInputElement(elem)
    ibox = box.getInputBox(input, viewport)

proc generateBoxAfter(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder) =
  if elem.pseudo[PSEUDO_AFTER] != nil:
    box.generatePseudo(elem, blockgroup, viewport, ibox, elem.pseudo[PSEUDO_AFTER])

proc generateInlineBoxes(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil

  generateBoxBefore(box, elem, blockgroup, viewport, ibox)

  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      let child = Element(child)
      box.generateFromElem(child, blockgroup, viewport, ibox)
    of TEXT_NODE:
      let child = Text(child)
      if ibox == nil:
        ibox = getTextBox(elem.css)
        ibox.node = elem
      ibox.text.add(child.data)
    else: discard

  generateBoxAfter(box, elem, blockgroup, viewport, ibox)

  flush_ibox

proc generateBlockBox(elem: Element, viewport: Viewport): BlockBoxBuilder =
  let box = getBlockBox(elem.css)
  var blockgroup: seq[BoxBuilder]
  var ibox: InlineBoxBuilder = nil

  generateBoxBefore(box, elem, blockgroup, viewport, ibox)
  
  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      flush_ibox
      let child = Element(child)
      box.generateFromElem(child, blockgroup, viewport, ibox)
    of TEXT_NODE:
      let child = Text(child)
      if canGenerateAnonymousInline(blockgroup, box.computed, child):
        if ibox == nil:
          ibox = getTextBox(elem.css)
          ibox.node = elem
        ibox.text.add(child.data)
    else: discard

  generateBoxAfter(box, elem, blockgroup, viewport, ibox)

  flush_ibox
  if blockgroup.len > 0:
    # Avoid unnecessary anonymous block boxes
    if box.children.len == 0:
      box.children = blockgroup
      box.inlinelayout = true
    else:
      flush_block_group3(elem.css)
  return box

proc generateBoxBuilders(elem: Element, viewport: Viewport): BlockBoxBuilder =
  return generateBlockBox(elem, viewport)

proc renderLayout*(viewport: var Viewport, document: Document) =
  viewport.root = document.html.generateBoxBuilders(viewport)
  viewport.root.bctx = buildBlock(viewport.root, viewport)
