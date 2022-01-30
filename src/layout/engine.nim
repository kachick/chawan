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

type InlineState = object
  ictx: InlineContext
  skip: bool
  node: Node
  word: InlineWord
  maxwidth: int
  specified: CSSSpecifiedValues

func whitespacepre(specified: CSSSpecifiedValues): bool {.inline.} =
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
func computeShift(ictx: InlineContext, specified: CSSSpecifiedValues): int =
  if ictx.whitespacenum > 0:
    if ictx.thisrow.atoms.len > 0 or specified.whitespacepre:
      let spacing = specified{"word-spacing"}
      if spacing.auto:
        return ictx.cellwidth * ictx.whitespacenum
      #return spacing.cells_w(ictx.viewport, 0)
      return spacing.px(ictx.viewport) * ictx.whitespacenum
  return 0

func computeLineHeight(viewport: Viewport, specified: CSSSpecifiedValues): int =
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

proc horizontalAlignRow(ictx: InlineContext, row: InlineRow, specified: CSSSpecifiedValues, maxwidth: int, last = false) =
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

proc flushWhitespace(ictx: InlineContext, specified: CSSSpecifiedValues) =
  let shift = ictx.computeShift(specified)
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.thisrow.addSpacing(shift, ictx.cellheight, ictx.format)

proc finishRow(ictx: InlineContext, specified: CSSSpecifiedValues, maxwidth: int, force = false) =
  if ictx.thisrow.atoms.len != 0 or force:
    ictx.flushWhitespace(specified)
    ictx.verticalAlignRow()

    let oldrow = ictx.thisrow
    ictx.rows.add(oldrow)
    ictx.height += oldrow.height
    ictx.maxwidth = max(ictx.maxwidth, oldrow.width)
    ictx.thisrow = InlineRow(rely: oldrow.rely + oldrow.height)

proc finish(ictx: InlineContext, specified: CSSSpecifiedValues, maxwidth: int) =
  ictx.finishRow(specified, maxwidth)
  for row in ictx.rows:
    ictx.horizontalAlignRow(row, specified, maxwidth, row == ictx.rows[^1])

proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, specified: CSSSpecifiedValues) =
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
proc flushLine(ictx: InlineContext, specified: CSSSpecifiedValues, maxwidth: int) =
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

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, specified: CSSSpecifiedValues, node: Node) =
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

proc newBlockContext_common(parent: BlockContext, box: CSSBox): BlockContext {.inline.} =
  new(result)

  result.viewport = parent.viewport
  result.specified = box.specified
  result.computedDimensions(parent.compwidth, parent.compheight)

proc newBlockContext(parent: BlockContext, box: BlockBox): BlockContext =
  result = newBlockContext_common(parent, box)
  result.shrink = result.specified{"width"}.auto and parent.shrink

proc newInlineBlockContext(parent: BlockContext, box: InlineBlockBox): BlockContext =
  result = newBlockContext_common(parent, box)
  result.shrink = result.specified{"width"}.auto

# Anonymous block box.
proc newBlockContext(parent: BlockContext): BlockContext =
  new(result)
  result.specified = parent.specified.inheritProperties()
  result.viewport = parent.viewport
  result.computedDimensions(parent.compwidth, parent.compheight)
  result.shrink = result.specified{"width"}.auto and parent.shrink

# Anonymous block box (root).
proc newBlockContext(viewport: Viewport): BlockContext =
  new(result)
  result.specified = rootProperties()
  result.viewport = viewport
  result.computedDimensions(viewport.term.width_px, none(int))

proc newInlineContext(bctx: BlockContext): InlineContext =
  new(result)
  result.thisrow = InlineRow()
  result.viewport = bctx.viewport
  result.shrink = bctx.shrink
  bctx.inline = result

# Blocks' positions do not have to be arranged if alignBlocks is called with
# children, whence the separate procedure.
proc arrangeBlocks(bctx: BlockContext, selfcontained: bool) =
  var y = 0
  var x = 0
  var margin_todo = 0

  y += bctx.padding_top
  bctx.height += bctx.padding_top

  x += bctx.padding_left
  if bctx.specified{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
    x += bctx.compwidth div 2

  template apply_child(child: BlockContext) =
    child.rely = y
    child.relx = x + child.margin_left
    if bctx.specified{"text-align"} == TEXT_ALIGN_MOZ_CENTER:
      child.relx -= child.width div 2
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

proc arrangeInlines(bctx: BlockContext, selfcontained: bool) =
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

proc alignBlock(box: BlockBox, selfcontained = false)

proc alignInlineBlock(bctx: BlockContext, box: InlineBlockBox) =
  if box.bctx.done:
    return
  alignBlock(box, true)

  box.bctx.relx += box.bctx.margin_left
  box.bctx.width += box.bctx.margin_left
  box.bctx.width += box.bctx.margin_right

  box.ictx.addAtom(box.bctx, bctx.compwidth, box.specified)
  box.ictx.whitespacenum = 0

# ew.
proc alignMarkerOutside(bctx: BlockContext, box: MarkerBox) =
  let oldwidth = box.ictx.thisrow.width
  let oldheight = box.ictx.thisrow.height
  assert box.text.len == 1
  assert box.children.len == 0

  box.ictx.renderText(box.text[0], bctx.compwidth, box.specified, box.node)
  # We assume this renders one row only. But there's no guarantee it does...
  if box.ictx.thisrow.atoms.len > 0:
    let atom = box.ictx.thisrow.atoms[^1]
    atom.relx -= atom.width

    box.ictx.flushWhitespace(box.specified)
    let ws = box.ictx.thisrow.atoms[^1]

    # If flushWhitespace did anything
    if ws != atom:
      atom.relx -= ws.width

    box.ictx.thisrow.width = oldwidth
    box.ictx.height -= box.ictx.thisrow.height - oldheight
    box.ictx.thisrow.height = oldheight

proc alignInline(bctx: BlockContext, box: InlineBox) =
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
    case child.t
    of DISPLAY_INLINE:
      let child = InlineBox(child)
      child.ictx = box.ictx
      if child of MarkerBox:
        let child = MarkerBox(child)
        if child.outside:
          bctx.alignMarkerOutside(child)
        else:
          bctx.alignInline(child)
      else:
        bctx.alignInline(child)
    of DISPLAY_INLINE_BLOCK:
      let child = InlineBlockBox(child)
      child.ictx = box.ictx
      bctx.alignInlineBlock(child)
    else:
      assert false, "child.t is " & $child.t

  let padding_right = box.specified{"padding-right"}.px(bctx.viewport, bctx.compwidth)
  if padding_right > 0:
    box.ictx.thisrow.addSpacing(padding_right, max(box.ictx.thisrow.height, 1), paddingformat)

  let margin_right = box.specified{"margin-right"}.px(bctx.viewport, bctx.compwidth)
  box.ictx.thisrow.width += margin_right

proc alignInlines(bctx: BlockContext, inlines: seq[CSSBox]) =
  let ictx = bctx.newInlineContext()
  if inlines.len > 0:
    for child in inlines:
      case child.t
      of DISPLAY_INLINE:
        let child = InlineBox(child)
        child.ictx = ictx
        if child of MarkerBox:
          let child = MarkerBox(child)
          if child.outside:
            bctx.alignMarkerOutside(child)
          else:
            bctx.alignInline(child)
        else:
          bctx.alignInline(child)
      of DISPLAY_INLINE_BLOCK:
        let child = InlineBlockBox(child)
        child.ictx = ictx
        bctx.alignInlineBlock(child)
      else:
        assert false, "child.t is " & $child.t
    ictx.finish(bctx.specified, bctx.compwidth)

  bctx.height += ictx.height
  if bctx.compheight.issome:
    bctx.height = bctx.compheight.get
  bctx.width = max(bctx.width, ictx.maxwidth)

template flush_group() =
  if blockgroup.len > 0:
    let gctx = newBlockContext(bctx)
    gctx.alignInlines(blockgroup)
    blockgroup.setLen(0)
    bctx.nested.add(gctx)

proc alignBlocks(bctx: BlockContext, blocks: seq[CSSBox], blockgroup: var seq[CSSBox], node: Node) =
  # Box contains block boxes.
  # If present, group inline boxes together in anonymous block boxes. Place
  # block boxes inbetween these.
  for child in blocks:
    case child.t
    of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
      let child = BlockBox(child)
      flush_group()
      bctx.nested.add(child.bctx)
      alignBlock(child)
    of DISPLAY_INLINE:
      if child.inlinelayout:
        blockgroup.add(child)
      else:
        bctx.alignBlocks(child.children, blockgroup, child.node)
    of DISPLAY_INLINE_BLOCK:
      blockgroup.add(child)
    else: discard #TODO

proc alignBlock(box: BlockBox, selfcontained = false) =
  if box.bctx.done:
    return
  if box.inlinelayout:
    # Box only contains inline boxes.
    box.bctx.alignInlines(box.children)
    box.bctx.arrangeInlines(selfcontained)
  else:
    var blockgroup: seq[CSSBox]
    box.bctx.alignBlocks(box.children, blockgroup, box.node)
    let bctx = box.bctx
    flush_group()
    box.bctx.arrangeBlocks(selfcontained)
  box.bctx.done = true

proc getBox(specified: CSSSpecifiedValues): CSSBox =
  case specified{"display"}
  of DISPLAY_BLOCK:
    result = BlockBox()
  of DISPLAY_INLINE_BLOCK:
    result = InlineBlockBox()
  of DISPLAY_INLINE:
    result = InlineBox()
  of DISPLAY_LIST_ITEM:
    result = ListItemBox()
  of DISPLAY_NONE: return nil
  else: return nil
  result.t = specified{"display"}
  result.specified = specified

# Returns a block box, disregarding the specified value
proc getBlockBox(specified: CSSSpecifiedValues): BlockBox =
  new(result)
  result.t = DISPLAY_BLOCK
  result.specified = specified.copyProperties()
  result.specified{"display"} = DISPLAY_BLOCK

proc getTextBox(box: CSSBox): InlineBox =
  new(result)
  result.t = DISPLAY_INLINE
  result.inlinelayout = true
  result.specified = box.specified.inheritProperties()

proc getMarkerBox(box: CSSBox): MarkerBox =
  new(result)
  result.t = DISPLAY_INLINE
  result.inlinelayout = true
  result.specified = box.specified.inheritProperties()

proc getPseudoBox(bctx: BlockContext, specified: CSSSpecifiedValues): CSSBox =
  let box = getBox(specified)

  if box == nil:
    return nil

  case box.specified{"display"}
  of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
    let box = BlockBox(box)
    box.bctx = bctx.newBlockContext(box)
  of DISPLAY_INLINE_BLOCK:
    let box = InlineBlockBox(box)
    box.bctx = bctx.newInlineBlockContext(box)
  else:
    discard

  box.inlinelayout = true
  if specified{"content"}.len > 0:
    let content = getTextBox(box)
    content.text.add($specified{"content"})
    box.children.add(content)
  return box

func getInputBox(box: CSSBox, input: HTMLInputElement, viewport: Viewport): InlineBox =
  let textbox = box.getTextBox()
  textbox.node = input
  textbox.text.add(input.inputString())
  return textbox

proc generateBox(elem: Element, viewport: Viewport, bctx: BlockContext = nil): CSSBox =
  elem.rendered = true
  if viewport.map[elem.uid] != nil:
    let box = viewport.map[elem.uid]
    var bctx = bctx
    case box.specified{"display"}
    of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
      let box = BlockBox(box)
      if bctx == nil:
        box.bctx = viewport.newBlockContext()
      else:
        box.bctx = bctx.newBlockContext(box)
      bctx = box.bctx
    of DISPLAY_INLINE_BLOCK:
      let box = InlineBlockBox(box)
      if bctx == nil:
        assert false
        box.bctx = viewport.newBlockContext()
      else:
        box.bctx = bctx.newInlineBlockContext(box)
      bctx = box.bctx
    else:
      discard

    var i = 0
    while i < box.children.len:
      let child = box.children[i]
      if child.element != nil:
        box.children[i] = generateBox(child.element, viewport, bctx)
      inc i
    return viewport.map[elem.uid]

  let box = if bctx != nil:
    getBox(elem.css)
  else:
    getBlockBox(elem.css)

  if box == nil:
    return nil

  box.node = elem
  box.element = elem

  var bctx = bctx
  case box.specified{"display"}
  of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
    let box = BlockBox(box)
    if bctx == nil:
      box.bctx = viewport.newBlockContext()
    else:
      box.bctx = bctx.newBlockContext(box)
    bctx = box.bctx
  of DISPLAY_INLINE_BLOCK:
    let box = InlineBlockBox(box)
    box.bctx = bctx.newInlineBlockContext(box)
    bctx = box.bctx
  else: discard

  var ibox: InlineBox
  template add_ibox() =
    if ibox != nil:
      box.children.add(ibox)
      ibox = nil

  template add_box(child: CSSBox) =
    add_ibox()
    box.children.add(child)
    if child.t notin {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK} or not child.inlinelayout:
      box.inlinelayout = false

  box.inlinelayout = true

  if box.t == DISPLAY_LIST_ITEM:
    var ordinalvalue = 1
    if elem.tagType == TAG_LI:
      ordinalvalue = HTMLLIElement(elem).ordinalvalue
    let marker = box.getMarkerBox()
    marker.node = elem
    marker.text.add(elem.css{"list-style-type"}.listMarker(ordinalvalue))
    if elem.css{"list-style-position"} == LIST_STYLE_POSITION_OUTSIDE:
      marker.outside = true
    add_box(marker)

  let before = elem.pseudo[PSEUDO_BEFORE]
  if before != nil:
    let bbox = bctx.getPseudoBox(before)
    if bbox != nil:
      bbox.node = elem
      add_box(bbox)

  if elem.tagType == TAG_INPUT:
    let input = HTMLInputElement(elem)
    add_box(box.getInputBox(input, viewport))

  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      let elem = Element(child)
      if elem.tagType == TAG_BR:
        add_ibox()
        ibox = box.getTextBox()
        ibox.newline = true

      let cbox = elem.generateBox(viewport, bctx)
      if cbox != nil:
        add_box(cbox)
    of TEXT_NODE:
      let text = Text(child)
      # Don't generate empty anonymous inline blocks between block boxes
      if box.specified{"display"} == DISPLAY_INLINE or
          box.children.len > 0 and box.children[^1].specified{"display"} == DISPLAY_INLINE or
          box.specified{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
          not text.data.onlyWhitespace():
        if ibox == nil:
          ibox = box.getTextBox()
          ibox.node = elem
        ibox.text.add(text.data)
    else: discard
  add_ibox()

  let after = elem.pseudo[PSEUDO_AFTER]
  if after != nil:
    let abox = bctx.getPseudoBox(after)
    if abox != nil:
      abox.node = elem
      add_box(abox)

  viewport.map[elem.uid] = box

  return box

proc renderLayout*(viewport: var Viewport, document: Document) =
  if viewport.root == nil or document.all_elements.len != viewport.map.len:
    viewport.map = newSeq[CSSBox](document.all_elements.len)
  else:
    var i = 0
    while i < viewport.map.len:
      if not document.all_elements[i].rendered:
        viewport.map[i] = nil
      inc i
  viewport.root = BlockBox(document.root.generateBox(viewport))
  alignBlock(viewport.root)
