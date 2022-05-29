import math
import options
import unicode

import layout/box
import html/tags
import html/dom
import css/values
import utils/twtstr
import io/term

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
  specified: CSSComputedValues

func whitespacepre(specified: CSSComputedValues): bool {.inline.} =
  specified{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_WRAP}

func cellwidth(viewport: Viewport): int {.inline.} =
  viewport.term.ppc

func cellwidth(ictx: InlineContext): int {.inline.} =
  ictx.viewport.cellwidth

func cellheight(viewport: Viewport): int {.inline.} =
  viewport.term.ppl

func cellheight(ictx: InlineContext): int {.inline.} =
  ictx.viewport.cellheight

# Whitespace between words
func computeShift(ictx: InlineContext, specified: CSSComputedValues): int =
  if ictx.whitespacenum > 0:
    if ictx.thisrow.atoms.len > 0 or specified.whitespacepre:
      let spacing = specified{"word-spacing"}
      if spacing.auto:
        return ictx.cellwidth * ictx.whitespacenum
      #return spacing.cells_w(ictx.viewport, 0)
      return spacing.px(ictx.viewport) * ictx.whitespacenum
  return 0

func computeLineHeight(viewport: Viewport, specified: CSSComputedValues): int =
  if specified{"line-height"}.auto:
    return viewport.cellheight
  return specified{"line-height"}.px(viewport, viewport.cellheight)

proc newWord(state: var InlineState) =
  let word = InlineWord()
  let format = ComputedFormat()
  let specified = state.specified
  format.color = specified{"color"}
  format.fontstyle = specified{"font-style"}
  format.fontweight = specified{"font-weight"}
  format.textdecoration = specified{"text-decoration"}
  format.node = state.node
  word.format = format
  state.ictx.format = format
  state.word = word

proc horizontalAlignRow(ictx: InlineContext, row: InlineRow, specified: CSSComputedValues, maxwidth: int, last = false) =
  let maxwidth = if ictx.shrink:
    ictx.maxwidth
  else:
    maxwidth
  # we don't support directions for now so left = start and right = end
  case specified{"text-align"}
  of TEXT_ALIGN_START, TEXT_ALIGN_LEFT:
    discard
  of TEXT_ALIGN_END, TEXT_ALIGN_RIGHT:
    # move everything
    let x = max(maxwidth, row.width) - row.width
    for atom in row.atoms:
      atom.relx += x
  of TEXT_ALIGN_CENTER:
    let x = max((max(maxwidth - row.relx, row.width)) div 2 - row.width div 2, 0)
    for atom in row.atoms:
      atom.relx += x
  of TEXT_ALIGN_JUSTIFY:
    if not specified.whitespacepre and not last:
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
        let oldwidth = row.width
        row.width = 0
        for atom in row.atoms:
          atom.relx = row.width
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
    atom.rely += diff

proc addSpacing(row: InlineRow, width, height: int, format: ComputedFormat) {.inline.} =
  let spacing = InlineSpacing(width: width, height: height, format: format)
  spacing.relx = row.width
  row.width += spacing.width
  row.atoms.add(spacing)

proc flushWhitespace(ictx: InlineContext, specified: CSSComputedValues) =
  let shift = ictx.computeShift(specified)
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.thisrow.addSpacing(shift, ictx.cellheight, ictx.format)

proc finishRow(ictx: InlineContext, specified: CSSComputedValues, maxwidth: int, force = false) =
  if ictx.thisrow.atoms.len != 0 or force:
    ictx.flushWhitespace(specified)
    ictx.verticalAlignRow()

    let oldrow = ictx.thisrow
    ictx.rows.add(oldrow)
    ictx.height += oldrow.height
    ictx.maxwidth = max(ictx.maxwidth, oldrow.width)
    ictx.thisrow = InlineRow(rely: oldrow.rely + oldrow.height)

proc finish(ictx: InlineContext, specified: CSSComputedValues, maxwidth: int) =
  ictx.finishRow(specified, maxwidth)
  for row in ictx.rows:
    ictx.horizontalAlignRow(row, specified, maxwidth, row == ictx.rows[^1])

proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, specified: CSSComputedValues) =
  var shift = ictx.computeShift(specified)
  ictx.whitespacenum = 0
  # Line wrapping
  if not specified.whitespacepre:
    if ictx.thisrow.width + atom.width + shift > maxwidth:
      ictx.finishRow(specified, maxwidth, false)
      # Recompute on newline
      shift = ictx.computeShift(specified)

  if atom.width > 0 and atom.height > 0:
    atom.vertalign = specified{"vertical-align"}

    if shift > 0:
      ictx.thisrow.addSpacing(shift, ictx.cellheight, ictx.format)

    atom.relx += ictx.thisrow.width
    ictx.thisrow.lineheight = max(ictx.thisrow.lineheight, computeLineHeight(ictx.viewport, specified))
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
    state.ictx.addAtom(word, state.maxwidth, state.specified)
    state.newWord()

# Start a new line, even if the previous one is empty
proc flushLine(ictx: InlineContext, specified: CSSComputedValues, maxwidth: int) =
  ictx.thisrow.lineheight = computeLineHeight(ictx.viewport, specified)
  ictx.finishRow(specified, maxwidth, true)

proc checkWrap(state: var InlineState, r: Rune) =
  if state.specified{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  let shift = state.ictx.computeShift(state.specified)
  case state.specified{"word-break"}
  of WORD_BREAK_BREAK_ALL:
    if state.ictx.thisrow.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.addWord()
      state.ictx.finishRow(state.specified, state.maxwidth, false)
      state.ictx.whitespacenum = 0
  of WORD_BREAK_KEEP_ALL:
    if state.ictx.thisrow.width + state.word.width + shift + r.width() * state.ictx.cellwidth > state.maxwidth:
      state.ictx.finishRow(state.specified, state.maxwidth, false)
      state.ictx.whitespacenum = 0
  else: discard

proc processWhitespace(state: var InlineState, c: char) =
  state.addWord()
  case state.specified{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    state.ictx.whitespacenum = max(state.ictx.whitespacenum, 1)
  of WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    if c == '\n':
      state.ictx.flushLine(state.specified, state.maxwidth)
    else:
      inc state.ictx.whitespacenum

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, specified: CSSComputedValues, node: Node) =
  var state: InlineState
  state.specified = specified
  state.ictx = ictx
  state.maxwidth = maxwidth
  state.node = node
  state.ictx.flushWhitespace(state.specified)
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

proc computedDimensions(bctx: BlockContext, width: int, height: Option[int]) =
  let pwidth = bctx.specified{"width"}
  if pwidth.auto:
    bctx.compwidth = width
  else:
    bctx.compwidth = pwidth.px(bctx.viewport, width)

  bctx.margin_left = bctx.specified{"margin-left"}.px(bctx.viewport, width)
  bctx.margin_right = bctx.specified{"margin-right"}.px(bctx.viewport, width)

  bctx.padding_top = bctx.specified{"padding-top"}.px(bctx.viewport, width)
  bctx.padding_bottom = bctx.specified{"padding-bottom"}.px(bctx.viewport, width)
  bctx.padding_left = bctx.specified{"padding-left"}.px(bctx.viewport, width)
  bctx.padding_right = bctx.specified{"padding-right"}.px(bctx.viewport, width)

  if bctx.compwidth >= width:
    bctx.compwidth -= bctx.margin_left
    bctx.compwidth -= bctx.margin_right

    bctx.compwidth -= bctx.padding_left
    bctx.compwidth -= bctx.padding_right

  let pheight = bctx.specified{"height"}
  if not pheight.auto:
    #bctx.compheight = pheight.cells_h(bctx.viewport, height).some
    if pheight.unit != UNIT_PERC:
      bctx.compheight = pheight.px(bctx.viewport).some
    elif height.issome:
      bctx.compheight = pheight.px(bctx.viewport, height.get).some

proc newBlockContext_common(parent: BlockContext, box: BoxBuilder): BlockContext {.inline.} =
  new(result)

  result.viewport = parent.viewport
  result.specified = box.specified
  result.computedDimensions(parent.compwidth, parent.compheight)

proc newBlockContext(parent: BlockContext, box: BlockBoxBuilder): BlockContext =
  result = newBlockContext_common(parent, box)
  result.offset = Offset(t: OFFSET_BLOCK_CONTEXT)
  if parent.nested.len > 0:
    result.offset.prev_sibling = parent.nested[^1].offset
  result.shrink = result.specified{"width"}.auto and parent.shrink

proc newInlineBlockContext(parent: BlockContext, box: InlineBlockBoxBuilder): BlockContext =
  result = newBlockContext_common(parent, box)
  result.shrink = result.specified{"width"}.auto

proc newInlineBlock(parent: BlockContext, box: InlineBlockBoxBuilder): InlineBlock =
  new(result)
  result.bctx = parent.newInlineBlockContext(box)

# Anonymous block box.
proc newBlockContext(parent: BlockContext): BlockContext =
  new(result)
  result.specified = parent.specified.inheritProperties()
  result.viewport = parent.viewport
  result.offset = Offset(t: OFFSET_BLOCK_CONTEXT)
  result.computedDimensions(parent.compwidth, parent.compheight)
  result.shrink = result.specified{"width"}.auto and parent.shrink

# Anonymous block box (root).
proc newBlockContext(viewport: Viewport): BlockContext =
  new(result)
  result.specified = rootProperties()
  result.viewport = viewport
  result.offset = Offset(t: OFFSET_BLOCK_CONTEXT)
  result.computedDimensions(viewport.term.width_px, none(int))

proc newInlineContext(bctx: BlockContext): InlineContext =
  new(result)
  result.thisrow = InlineRow()
  result.viewport = bctx.viewport
  result.shrink = bctx.shrink
  bctx.inline = result

# Blocks' positions do not have to be positiond if buildBlocks is called with
# children, whence the separate procedure.
proc positionBlocks(bctx: BlockContext, selfcontained: bool) =
  var y = 0
  var x = 0
  var margin_todo = 0

  y += bctx.padding_top
  bctx.height += bctx.padding_top

  x += bctx.padding_left
  if bctx.specified{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
    x += bctx.compwidth div 2

  template apply_child(child: BlockContext) =
    child.offset.rel.y = y
    child.offset.rel.x = x + child.margin_left
    if bctx.specified{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
      child.offset.rel.x -= child.width div 2
    y += child.height
    bctx.height += child.height
    bctx.width = max(bctx.width, child.width)
    margin_todo = child.margin_bottom

  var i = 0
  if i < bctx.nested.len:
    let child = bctx.nested[i]

    bctx.margin_top = child.margin_top
    let mtop = bctx.specified{"margin-top"}.px(bctx.viewport, bctx.compwidth)
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
  let mbot = bctx.specified{"margin-bottom"}.px(bctx.viewport, bctx.compwidth)
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
  bctx.margin_top = bctx.specified{"margin-top"}.px(bctx.viewport, bctx.compwidth)
  bctx.margin_bottom = bctx.specified{"margin-bottom"}.px(bctx.viewport, bctx.compwidth)

  bctx.width += bctx.padding_left
  bctx.inline.relx += bctx.padding_left

  if selfcontained:
    bctx.inline.rely += bctx.margin_top
    bctx.height += bctx.margin_top
    bctx.height += bctx.margin_bottom

  bctx.height += bctx.padding_top
  bctx.inline.rely += bctx.padding_top

  bctx.height += bctx.padding_bottom

  bctx.width += bctx.padding_right

  if bctx.specified{"width"}.auto:
    bctx.width = min(bctx.width, bctx.compwidth)
  else:
    bctx.width = bctx.compwidth

proc buildBlock(box: BlockBoxBuilder, parent: BlockContext, selfcontained = false): BlockContext

#TODO
proc buildInlineBlock(builder: InlineBlockBoxBuilder, parent: InlineContext, parentblock: BlockContext): InlineBlock =
  return

proc buildInlineBlock(bctx: BlockContext, box: InlineBlockBoxBuilder) =
  assert box.children.len == 1 and box.children[0].specified{"display"} == DISPLAY_BLOCK
  #TODO
  
  #let nestedblock = BlockBoxBuilder(box.children[0])
  #nestedblock.bctx = bctx.newInlineBlockContext(box)
  #nestedblock.buildBlock(bctx)

  #let box = InlineBlockBoxBuilder(box)
  #box.iblock = InlineBlock(bctx: nestedblock.bctx)
  #box.bctx = box.iblock.bctx

  #buildBlock(box, bctx, true)

  #let iblock = box.iblock
  #iblock.relx = iblock.bctx.relx + iblock.bctx.margin_left
  #iblock.width = iblock.bctx.width + iblock.bctx.margin_left + iblock.bctx.margin_right
  #iblock.height = iblock.bctx.height

  #box.ictx.addAtom(box.iblock, bctx.compwidth, box.specified)
  #box.ictx.whitespacenum = 0

proc buildInline(bctx: BlockContext, box: InlineBoxBuilder) =
  assert box.ictx != nil
  if box.newline:
    box.ictx.flushLine(bctx.specified, bctx.compwidth)

  let margin_left = box.specified{"margin-left"}.px(bctx.viewport, bctx.compwidth)
  box.ictx.thisrow.width += margin_left

  let paddingformat = ComputedFormat(node: box.node)
  let padding_left = box.specified{"padding-left"}.px(bctx.viewport, bctx.compwidth)
  if padding_left > 0:
    box.ictx.thisrow.addSpacing(padding_left, box.ictx.cellheight, paddingformat)

  for text in box.text:
    assert box.children.len == 0
    box.ictx.renderText(text, bctx.compwidth, box.specified, box.node)

  for child in box.children:
    case child.specified{"display"}
    of DISPLAY_INLINE:
      let child = InlineBoxBuilder(child)
      child.ictx = box.ictx
      bctx.buildInline(child)
    of DISPLAY_INLINE_BLOCK:
      #TODO
      #let child = InlineBlockBoxBuilder(child)
      #child.ictx = box.ictx
      #bctx.buildInlineBlock(child)
      discard
    else:
      assert false, "child.t is " & $child.specified{"display"}

  let padding_right = box.specified{"padding-right"}.px(bctx.viewport, bctx.compwidth)
  if padding_right > 0:
    box.ictx.thisrow.addSpacing(padding_right, max(box.ictx.thisrow.height, 1), paddingformat)

  let margin_right = box.specified{"margin-right"}.px(bctx.viewport, bctx.compwidth)
  box.ictx.thisrow.width += margin_right

proc buildInlines(bctx: BlockContext, inlines: seq[BoxBuilder]) =
  let ictx = bctx.newInlineContext()
  if inlines.len > 0:
    for child in inlines:
      case child.specified{"display"}
      of DISPLAY_INLINE:
        let child = InlineBoxBuilder(child)
        child.ictx = ictx
        #if child of MarkerBox:
        #  let child = MarkerBox(child)
        #  if child.outside:
        #    bctx.buildMarkerOutside(child)
        #  else:
        #    bctx.buildInline(child)
        #else:
        bctx.buildInline(child)
      of DISPLAY_INLINE_BLOCK:
        let child = InlineBlockBoxBuilder(child)
        child.ictx = ictx
        bctx.buildInlineBlock(child)
      else:
        assert false, "child.t is " & $child.specified{"display"}
    ictx.finish(bctx.specified, bctx.compwidth)

  bctx.height += ictx.height
  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get
  bctx.width = max(bctx.width, ictx.maxwidth)

proc buildBlocks(bctx: BlockContext, blocks: seq[BoxBuilder], node: Node) =
  for child in blocks:
    case child.specified{"display"}
    of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
      bctx.nested.add(buildBlock(BlockBoxBuilder(child), bctx))
    else:
      assert false, "child.t is " & $child.specified{"display"}

# Build a block box inside another block box, based on a builder.
proc buildBlock(box: BlockBoxBuilder, parent: BlockContext, selfcontained = false): BlockContext =
  assert parent != nil
  result = parent.newBlockContext()
  if box.inlinelayout:
    # Builder only contains inline boxes.
    result.buildInlines(box.children)
    result.positionInlines(selfcontained)
  else:
    # Builder only contains block boxes.
    result.buildBlocks(box.children, box.node)
    result.positionBlocks(selfcontained)

# Build a block box whose parent is the viewport, based on a builder.
proc buildBlock(box: BlockBoxBuilder, viewport: Viewport, selfcontained = false): BlockContext =
  result = viewport.newBlockContext()
  if box.inlinelayout:
    # Builder only contains inline boxes.
    result.buildInlines(box.children)
    result.positionInlines(selfcontained)
  else:
    # Builder only contains block boxes.
    result.buildBlocks(box.children, box.node)
    result.positionBlocks(selfcontained)

# Generation phase

proc getInlineBlockBox(specified: CSSComputedValues): InlineBlockBoxBuilder =
  assert specified{"display"} == DISPLAY_INLINE_BLOCK
  new(result)
  result.specified = specified

# Returns a block box, disregarding the specified value of display
proc getBlockBox(specified: CSSComputedValues): BlockBoxBuilder =
  new(result)
  result.specified = specified.copyProperties()
  #WARNING yes there is a {}= macro but that modifies the specified value
  # reference itself and those are copied across arrays...
  #TODO figure something out here
  result.specified[PROPERTY_DISPLAY] = CSSComputedValue(t: PROPERTY_DISPLAY, v: VALUE_DISPLAY, display: DISPLAY_BLOCK)

proc getTextBox(box: BoxBuilder): InlineBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.specified = box.specified.inheritProperties()

proc getTextBox(specified: CSSComputedValues): InlineBoxBuilder =
  new(result)
  result.inlinelayout = true
  result.specified = specified.inheritProperties()

#TODO
#proc getMarkerBox(box: Box): MarkerBox =
#  new(result)
#  result.inlinelayout = true
#  result.specified = box.specified.inheritProperties()

func getInputBox(parent: BoxBuilder, input: HTMLInputElement, viewport: Viewport): InlineBoxBuilder =
  let textbox = parent.getTextBox()
  textbox.node = input
  textbox.text.add(input.inputString())
  return textbox

func getInputBox(specified: CSSComputedValues, input: HTMLInputElement, viewport: Viewport): InlineBoxBuilder =
  let textbox = specified.getTextBox()
  textbox.node = input
  textbox.text.add(input.inputString())
  return textbox

# Don't generate empty anonymous inline blocks between block boxes
func canGenerateAnonymousInline(blockgroup: seq[BoxBuilder], specified: CSSComputedValues, text: Text): bool =
  return blockgroup.len > 0 and blockgroup[^1].specified{"display"} == DISPLAY_INLINE or
    specified{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
    not text.data.onlyWhitespace()

proc generateBlockBox(elem: Element, viewport: Viewport): BlockBoxBuilder

template flush_block_group3(specified: CSSComputedValues) =
  if blockgroup.len > 0:
    let bbox = getBlockBox(specified.inheritProperties())
    bbox.inlinelayout = true
    bbox.children = blockgroup
    box.children.add(bbox)
    blockgroup.setLen(0)

template flush_ibox() =
  if ibox != nil:
    assert ibox.specified{"display"} in {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK}
    blockgroup.add(ibox)
    ibox = nil

template generate_from_elem(child: Element) =
  if child.tagType == TAG_BR:
    flush_ibox
    ibox = box.getTextBox()
    ibox.newline = true

  case child.css{"display"}
  of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
    flush_block_group3(elem.css)
    let childbox = child.generateBlockBox(viewport)
    box.children.add(childbox)
  of DISPLAY_INLINE:
    flush_ibox

    box.generateInlineBoxes(child, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(child.css)
    let childblock = child.generateBlockBox(viewport)
    childbox.children.add(childblock)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateInlinePseudoBox(box: BlockBoxBuilder, specified: CSSComputedValues, blockgroup: var seq[BoxBuilder], viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil

  if specified{"content"}.len > 0:
    ibox = getTextBox(specified)
    ibox.text.add($specified{"content"})

  flush_ibox

proc generateBlockPseudoBox(specified: CSSComputedValues, viewport: Viewport): BlockBoxBuilder =
  let box = getBlockBox(specified)
  var blockgroup: seq[BoxBuilder]
  var ibox: InlineBoxBuilder = nil

  if specified{"content"}.len > 0:
    ibox = getTextBox(specified)
    ibox.text.add($specified{"content"})
    flush_ibox
    flush_block_group3(specified)

  return box

template generate_pseudo(specified: CSSComputedValues) =
  case specified{"display"}
  of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
    flush_block_group3(elem.css)
    let childbox = generateBlockPseudoBox(specified, viewport)
    box.children.add(childbox)
  of DISPLAY_INLINE:
    flush_ibox
    box.generateInlinePseudoBox(specified, blockgroup, viewport)
  of DISPLAY_INLINE_BLOCK:
    flush_ibox
    let childbox = getInlineBlockBox(specified)
    let childblock = generateBlockPseudoBox(specified, viewport)
    childbox.children.add(childblock)
    blockgroup.add(childbox)
  else:
    discard #TODO

proc generateBoxBefore(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder) =
  if elem.pseudo[PSEUDO_BEFORE] != nil:
    generate_pseudo(elem.pseudo[PSEUDO_BEFORE])

  #TODO
  #if box.specified{"display"} == DISPLAY_LIST_ITEM:
  #  flush_ibox
  #  var ordinalvalue = 1
  #  if elem.tagType == TAG_LI:
  #    ordinalvalue = HTMLLIElement(elem).ordinalvalue
  #  let marker = box.getMarkerBox()
  #  marker.node = elem
  #  marker.text.add(elem.css{"list-style-type"}.listMarker(ordinalvalue))
  #  if elem.css{"list-style-position"} == LIST_STYLE_POSITION_OUTSIDE:
  #    marker.outside = true
  #  ibox = marker

  if elem.tagType == TAG_INPUT:
    flush_ibox
    let input = HTMLInputElement(elem)
    ibox = box.getInputBox(input, viewport)

proc generateBoxAfter(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport, ibox: var InlineBoxBuilder) =
  if elem.pseudo[PSEUDO_AFTER] != nil:
    generate_pseudo(elem.pseudo[PSEUDO_AFTER])

proc generateInlineBoxes(box: BlockBoxBuilder, elem: Element, blockgroup: var seq[BoxBuilder], viewport: Viewport) =
  var ibox: InlineBoxBuilder = nil

  generateBoxBefore(box, elem, blockgroup, viewport, ibox)

  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      let child = Element(child)
      generate_from_elem(child)
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
      let child = Element(child)
      generate_from_elem(child)
    of TEXT_NODE:
      let child = Text(child)
      if canGenerateAnonymousInline(blockgroup, box.specified, child):
        if ibox == nil:
          ibox = getTextBox(elem.css)
          ibox.node = elem
        ibox.text.add(child.data)
    else: discard

  generateBoxAfter(box, elem, blockgroup, viewport, ibox)

  flush_ibox
  flush_block_group3(elem.css)
  return box

proc generateBoxBuilders(elem: Element, viewport: Viewport): BlockBoxBuilder =
  return generateBlockBox(elem, viewport)

proc renderLayout*(viewport: var Viewport, document: Document) =
  viewport.root = document.root.generateBlockBox(viewport)
  viewport.root.bctx = buildBlock(viewport.root, viewport)
