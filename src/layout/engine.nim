import unicode
import options

import layout/box
import html/tags
import html/dom
import css/values
import utils/twtstr
import io/term

func cells_in(l: CSSLength, state: Viewport, d: int, p: Option[int], o: bool): int =
  return cells(l, d, state.term.width_px, state.term.height_px, p, o)

func cells_w(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppc, p.some, true)

func cells_h(l: CSSLength, state: Viewport, p: Option[int]): int =
  return l.cells_in(state, state.term.ppl, p, false)

func cells_h(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppl, p.some, false)

type InlineState = object
  ictx: InlineContext
  skip: bool
  nodes: seq[Node]
  word: InlineWord
  maxwidth: int
  specified: CSSSpecifiedValues

proc newWord(state: var InlineState) =
  let word = InlineWord()
  let specified = state.specified
  word.color = specified{"color"}
  word.fontstyle = specified{"font-style"}
  word.fontweight = specified{"font-weight"}
  word.textdecoration = specified{"text-decoration"}
  word.nodes = state.nodes
  state.word = word

proc finishRow(ictx: InlineContext) =
  if ictx.thisrow.height != 0:
    let oldrow = ictx.thisrow
    ictx.rows.add(oldrow)
    ictx.height += oldrow.height
    ictx.width = max(ictx.width, oldrow.width)
    ictx.thisrow = InlineRow(rely: oldrow.rely + oldrow.height)

proc addAtom(ictx: InlineContext, atom: InlineAtom, maxwidth: int, specified: CSSSpecifiedValues) =
  # Whitespace between words
  var shift = 0
  let whitespacepre = specified{"white-space"} in {WHITESPACE_PRE, WHITESPACE_PRE_WRAP}
  if ictx.whitespace:
    if ictx.thisrow.atoms.len > 0 or whitespacepre:
      shift = 1
    ictx.whitespace = false

  # Line wrapping
  if specified{"white-space"} notin {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    if specified{"word-break"} == WORD_BREAK_NORMAL and ictx.thisrow.width + atom.width + shift > maxwidth:
      ictx.finishRow()
      if not whitespacepre:
        # No whitespace on newline
        shift = 0

  ictx.thisrow.width += shift

  if atom.width > 0:
    atom.relx += ictx.thisrow.width
    ictx.thisrow.width += atom.width
    ictx.thisrow.height = max(ictx.thisrow.height, atom.height)
    ictx.thisrow.atoms.add(atom)

proc addWord(state: var InlineState) =
  if state.word.str != "":
    let row = state.ictx.thisrow
    var word = state.word
    word.height = 1
    state.ictx.addAtom(word, state.maxwidth, state.specified)
    state.newWord()

# Start a new line, even if the previous one is empty
proc flushLine(ictx: InlineContext) =
  ictx.thisrow.height = max(ictx.thisrow.height, 1)
  ictx.finishRow()

proc checkWrap(state: var InlineState, r: Rune) =
  if state.specified{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.specified{"word-break"}
  of WORD_BREAK_BREAK_ALL:
    if state.ictx.thisrow.width + state.word.width + r.width() > state.maxwidth:
      state.addWord()
      state.ictx.finishRow()
  of WORD_BREAK_KEEP_ALL:
    if state.ictx.thisrow.width + state.word.width + r.width() > state.maxwidth:
      state.ictx.finishRow()
  else: discard

proc processWhitespace(state: var InlineState, c: char) =
  state.addWord()
  case state.specified{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    state.ictx.whitespace = true
  of WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    if c == '\n':
      state.ictx.flushLine()
    else:
      state.ictx.whitespace = true

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, specified: CSSSpecifiedValues, nodes: seq[Node]) =
  var state: InlineState
  state.specified = specified
  state.ictx = ictx
  state.maxwidth = maxwidth
  state.nodes = nodes
  state.newWord()

  #if str.strip().len > 0:
    #eprint "start", str.strip()
  var i = 0
  while i < str.len:
    var rw = 0
    case str[i]
    of ' ', '\n', '\t':
      state.processWhitespace(str[i])
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      rw = r.width()
      state.checkWrap(r)
      state.word.str &= r
      state.word.width += rw

  state.addWord()

proc finish(ictx: InlineContext) =
  ictx.finishRow()

proc computeWidth(bctx: BlockContext, width: int) =
  let pwidth = bctx.specified{"width"}
  if pwidth.auto:
    bctx.compwidth = width
  else:
    bctx.compwidth = pwidth.cells_w(bctx.viewport, width)

  let mlef = bctx.specified{"margin-left"}.cells_w(bctx.viewport, width)
  let mrig = bctx.specified{"margin-right"}.cells_w(bctx.viewport, width)
  bctx.relx = mlef
  bctx.compwidth -= mlef
  bctx.compwidth -= mrig

proc newBlockContext_common(parent: BlockContext, box: CSSBox): BlockContext {.inline.} =
  new(result)

  result.viewport = parent.viewport
  result.specified = box.specified
  result.computeWidth(parent.compwidth)

proc newBlockContext(parent: BlockContext, box: BlockBox): BlockContext =
  result = newBlockContext_common(parent, box)
  parent.nested.add(result)

proc newInlineBlockContext(parent: BlockContext, box: InlineBlockBox): BlockContext =
  newBlockContext_common(parent, box)

# Anonymous block box.
proc newBlockContext(parent: BlockContext): BlockContext =
  new(result)
  result.specified = parent.specified.inheritProperties()
  result.viewport = parent.viewport
  result.computeWidth(parent.compwidth)
  parent.nested.add(result)

# Anonymous block box (root).
proc newBlockContext(viewport: Viewport): BlockContext =
  new(result)
  result.specified = rootProperties()
  result.viewport = viewport
  result.computeWidth(viewport.term.width)

proc newInlineContext(bctx: BlockContext): InlineContext =
  new(result)
  result.thisrow = InlineRow()
  bctx.inline = result

# Blocks' positions do not have to be arranged if alignBlocks is called with
# children, whence the separate procedure.
proc arrangeBlocks(bctx: BlockContext) =
  var y = 0
  var margin_todo = 0

  template apply_child(child: BlockContext) =
    child.rely = y
    y += child.height
    bctx.height += child.height
    bctx.width = max(bctx.width, child.width)
    margin_todo = child.margin_bottom

  var i = 0
  if i < bctx.nested.len:
    let child = bctx.nested[i]

    bctx.margin_top = child.margin_top
    let mtop = bctx.specified{"margin-top"}.cells_h(bctx.viewport, bctx.compwidth)
    if mtop > bctx.margin_top or mtop < 0:
      bctx.margin_top = mtop - bctx.margin_top

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
  let mbot = bctx.specified{"margin-bottom"}.cells_h(bctx.viewport, bctx.compwidth)
  if mbot > bctx.margin_bottom or mbot < 0:
    bctx.margin_bottom = mbot - bctx.margin_bottom

proc alignBlock(box: BlockBox)

proc alignInlineBlock(bctx: BlockContext, box: InlineBlockBox, parentcss: CSSSpecifiedValues) =
  box.bctx = bctx.newInlineBlockContext(box)
  alignBlock(box)
  box.bctx.rely += box.bctx.margin_top
  box.bctx.height += box.bctx.margin_top
  box.bctx.height += box.bctx.margin_bottom
  box.ictx.addAtom(box.bctx, bctx.compwidth, parentcss)
  box.ictx.whitespace = false

proc alignInline(bctx: BlockContext, box: InlineBox) =
  if box.node != nil:
    bctx.viewport.nodes.add(box.node)

  let box = InlineBox(box)
  assert box.ictx != nil
  if box.newline:
    box.ictx.flushLine()
  for text in box.text:
    assert box.children.len == 0
    box.ictx.renderText(text, bctx.compwidth, box.specified, bctx.viewport.nodes)

  for child in box.children:
    case child.t
    of DISPLAY_INLINE:
      let child = InlineBox(child)
      child.ictx = box.ictx
      bctx.alignInline(child)
    of DISPLAY_INLINE_BLOCK:
      let child = InlineBlockBox(child)
      child.ictx = box.ictx
      bctx.alignInlineBlock(child, box.specified)
    else:
      assert false, "child.t is " & $child.t
  if box.node != nil:
    discard bctx.viewport.nodes.pop()

proc alignInlines(bctx: BlockContext, inlines: seq[CSSBox]) =
  let ictx = bctx.newInlineContext()
  for child in inlines:
    case child.t
    of DISPLAY_INLINE:
      let child = InlineBox(child)
      child.ictx = ictx
      bctx.alignInline(child)
    of DISPLAY_INLINE_BLOCK:
      let child = InlineBlockBox(child)
      child.ictx = ictx
      bctx.alignInlineBlock(child, bctx.specified)
    else:
      assert false, "child.t is " & $child.t
  ictx.finish()
  bctx.height += ictx.height
  bctx.width = max(ictx.width, ictx.width)
  bctx.margin_top = bctx.specified{"margin-top"}.cells_h(bctx.viewport, bctx.compwidth)
  bctx.margin_bottom = bctx.specified{"margin-bottom"}.cells_h(bctx.viewport, bctx.compwidth)

proc alignBlocks(bctx: BlockContext, blocks: seq[CSSBox]) =
  # Box contains block boxes.
  # If present, group inline boxes together in anonymous block boxes. Place
  # block boxes inbetween these.
  var blockgroup: seq[CSSBox]
  var has_noinline = false

  template flush_group() =
    if blockgroup.len > 0:
      let gctx = newBlockContext(bctx)
      gctx.alignInlines(blockgroup)
      blockgroup.setLen(0)

  for child in blocks:
    case child.t
    of DISPLAY_BLOCK, DISPLAY_LIST_ITEM:
      let child = BlockBox(child)
      flush_group()
      child.bctx = newBlockContext(bctx, child)
      alignBlock(child)
    of DISPLAY_INLINE:
      if child.inlinelayout:
        blockgroup.add(child)
      else:
        flush_group()
        bctx.alignBlocks(child.children)
        #eprint "put"
    of DISPLAY_INLINE_BLOCK:
      blockgroup.add(child)
    else: discard #TODO
  flush_group()

proc alignBlock(box: BlockBox) =
  if box.node != nil:
    box.bctx.viewport.nodes.add(box.node)
  if box.inlinelayout:
    # Box only contains inline boxes.
    box.bctx.alignInlines(box.children)
  else:
    box.bctx.alignBlocks(box.children)
    box.bctx.arrangeBlocks()
  if box.node != nil:
    discard box.bctx.viewport.nodes.pop()

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

proc getPseudoBox(specified: CSSSpecifiedValues): CSSBox =
  let box = getBox(specified)

  if box == nil:
    return nil
  box.inlinelayout = true
  if specified{"content"}.len > 0:
    let content = getTextBox(box)
    content.text.add($specified{"content"})
    box.children.add(content)
  return box

proc generateBox(elem: Element, viewport: Viewport, first = false): CSSBox =
  if viewport.map[elem.uid] != nil:
    return viewport.map[elem.uid]

  let box = if not first:
    getBox(elem.css)
  else:
    getBlockBox(elem.css)

  if box == nil:
    return nil

  box.node = elem

  var ibox: InlineBox
  template add_ibox() =
    if ibox != nil:
      box.children.add(ibox)
      ibox = nil

  template add_box(child: CSSBox) =
    box.children.add(child)
    if child.t notin {DISPLAY_INLINE, DISPLAY_INLINE_BLOCK} or not child.inlinelayout:
      box.inlinelayout = false

  box.inlinelayout = true

  if box.t == DISPLAY_LIST_ITEM:
    var ordinalvalue = 1
    if elem.tagType == TAG_LI:
      ordinalvalue = HTMLLIElement(elem).ordinalvalue
    let marker = box.getTextBox()
    marker.text.add(elem.css{"list-style-type"}.listMarker(ordinalvalue))
    add_box(marker)

  let before = elem.pseudo[PSEUDO_BEFORE]
  if before != nil:
    let bbox = getPseudoBox(before)
    bbox.node = elem
    if bbox != nil:
      add_box(bbox)

  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      let elem = Element(child)
      if elem.tagType == TAG_BR:
        add_ibox()
        ibox = box.getTextBox()
        ibox.newline = true

      let cbox = elem.generateBox(viewport)
      if cbox != nil:
        add_ibox()
        add_box(cbox)
    of TEXT_NODE:
      let text = Text(child)
      # Don't generate empty anonymous inline blocks.
      if box.specified{"display"} == DISPLAY_INLINE or
          box.children.len > 0 and box.children[^1].specified{"display"} == DISPLAY_INLINE or
          box.specified{"white-space"} in {WHITESPACE_PRE_LINE, WHITESPACE_PRE, WHITESPACE_PRE_WRAP} or
          not text.data.onlyWhitespace():
        if ibox == nil:
          ibox = box.getTextBox()
        ibox.text.add(text.data)
    else: discard
  add_ibox()

  let after = elem.pseudo[PSEUDO_AFTER]
  if after != nil:
    let abox = getPseudoBox(after)
    if abox != nil:
      add_box(abox)

  viewport.map[elem.uid] = box

  return box

proc renderLayout*(viewport: var Viewport, document: Document) =
  if viewport.root == nil or document.all_elements.len != viewport.map.len:
    viewport.map = newSeq[CSSBox](document.all_elements.len)
    viewport.root = BlockBox(document.root.generateBox(viewport, true))
  else:
    for uid in 0..viewport.map.high:
      if not document.all_elements[uid].rendered:
        viewport.map[uid] = nil
    viewport.root = BlockBox(document.root.generateBox(viewport))

  viewport.root.bctx = viewport.newBlockContext()
  alignBlock(viewport.root)
