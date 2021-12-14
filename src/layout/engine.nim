import unicode
import options

import layout/box
import types/enums
import html/dom
import css/values
import utils/twtstr
import io/term

func cells_in(l: CSSLength, state: LayoutState, d: int, p: Option[int], o: bool): int =
  return cells(l, d, state.term.width, state.term.height, p, o)

func cells_w(l: CSSLength, state: LayoutState, p: int): int =
  return l.cells_in(state, state.term.ppc, p.some, true)

func cells_h(l: CSSLength, state: LayoutState, p: Option[int]): int =
  return l.cells_in(state, state.term.ppl, p, false)

func cells_h(l: CSSLength, state: LayoutState, p: int): int =
  return l.cells_in(state, state.term.ppl, p.some, false)

func newInlineContext*(box: CSSBox): InlineContext =
  new(result)
  result.whitespace = true
  result.ws_initial = true

func newBlockContext(): BlockContext =
  new(result)

proc flushLines(box: CSSBox) =
  if box.icontext.conty:
    inc box.icontext.fromy
    inc box.bcontext.fromy
    inc box.height
    box.icontext.conty = false
  box.icontext.fromy += box.bcontext.margin_todo
  box.bcontext.margin_done += box.bcontext.margin_todo
  box.bcontext.margin_todo = 0

func newBlockBox(state: var LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSBlockBox =
  new(result)
  result.x = parent.x
  result.x += vals[PROPERTY_MARGIN_LEFT].length.cells_w(state, parent.bcontext.width)
  result.bcontext = newBlockContext()

  parent.flushLines()

  let mtop = vals[PROPERTY_MARGIN_TOP].length.cells_h(state, parent.bcontext.width)
  if mtop > parent.bcontext.margin_done or mtop < 0:
    let diff = mtop - parent.bcontext.margin_done
    parent.icontext.fromy += diff
    parent.bcontext.margin_done += diff

  result.y = parent.icontext.fromy

  result.bcontext.margin_done = parent.bcontext.margin_done

  let pwidth = vals[PROPERTY_WIDTH].length
  if pwidth.auto:
    result.bcontext.width = parent.bcontext.width
  else:
    result.bcontext.width = pwidth.cells_w(state, parent.bcontext.width)

  let pheight = vals[PROPERTY_HEIGHT].length
  if not pheight.auto:
    if pheight.unit != UNIT_PERC or parent.bcontext.height.issome:
      result.bcontext.height = pheight.cells_h(state, parent.bcontext.height).some

  result.icontext = newInlineContext(parent)
  result.icontext.fromy = result.y
  result.icontext.fromx = result.x
  result.cssvalues = vals

func newInlineBox*(state: LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSInlineBox =
  assert parent != nil
  new(result)
  result.x = parent.x
  result.y = parent.icontext.fromy

  result.icontext = parent.icontext
  result.bcontext = parent.bcontext
  result.cssvalues = vals
  result.icontext.fromx += vals[PROPERTY_MARGIN_LEFT].length.cells_w(state, parent.bcontext.width)

type InlineState = object
  ibox: CSSInlineBox
  rowi: int
  rowbox: CSSRowBox
  word: seq[Rune]
  ww: int
  skip: bool
  nodes: seq[Node]

func fromx(state: InlineState): int = state.ibox.icontext.fromx
func fromy(state: InlineState): int = state.ibox.icontext.fromy
func width(state: InlineState): int = state.rowbox.width

proc newRowBox(state: var InlineState) =
  state.rowbox = CSSRowBox()
  state.rowbox.x = state.fromx
  state.rowbox.y = state.fromy + state.rowi

  let cssvalues = state.ibox.cssvalues
  state.rowbox.color = cssvalues[PROPERTY_COLOR].color
  state.rowbox.fontstyle = cssvalues[PROPERTY_FONT_STYLE].fontstyle
  state.rowbox.fontweight = cssvalues[PROPERTY_FONT_WEIGHT].integer
  state.rowbox.textdecoration = cssvalues[PROPERTY_TEXT_DECORATION].textdecoration
  state.rowbox.nodes = state.nodes

proc inlineWrap(state: var InlineState) =
  state.ibox.content.add(state.rowbox)
  inc state.rowi
  state.ibox.icontext.fromx = state.ibox.x
  if state.word.len == 0:
    state.ibox.icontext.whitespace = true
    state.ibox.icontext.ws_initial = true
    state.ibox.icontext.conty = false
  else:
    if state.word[^1] == Rune(' '):
      state.ibox.icontext.whitespace = true
      state.ibox.icontext.ws_initial = false
    state.ibox.icontext.conty = true
  #eprint "wrap", state.rowbox.y, state.rowbox.str
  state.newRowBox()

proc addWord(state: var InlineState) =
  state.rowbox.str &= $state.word
  state.rowbox.width += state.ww
  state.word.setLen(0)
  state.ww = 0

proc wrapNormal(state: var InlineState, r: Rune) =
  if state.fromx + state.width + state.ww == state.ibox.bcontext.width and r == Rune(' '):
    state.addWord()
  if state.word.len == 0:
    if r == Rune(' '):
      state.skip = true
  elif state.word[0] == Rune(' '):
    state.word = state.word.substr(1)
    dec state.ww
  state.inlineWrap()
  if not state.skip and r == Rune(' '):
    state.ibox.icontext.whitespace = true
    state.ibox.icontext.ws_initial = false

proc checkWrap(state: var InlineState, r: Rune) =
  if state.ibox.cssvalues[PROPERTY_WHITESPACE].whitespace in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak
  of WORD_BREAK_NORMAL:
    if state.fromx + state.width > state.ibox.x and
        state.fromx + state.width + state.ww + r.width() > state.ibox.bcontext.width:
      state.wrapNormal(r)
  of WORD_BREAK_BREAK_ALL:
    if state.fromx + state.width + state.ww + r.width() > state.ibox.bcontext.width:
      var pl: seq[Rune]
      var i = 0
      var w = 0
      while i < state.word.len and
          state.ibox.icontext.fromx + state.rowbox.width + w <
            state.ibox.bcontext.width:
        pl &= state.word[i]
        w += state.word[i].width()
        inc i

      if pl.len > 0:
        state.rowbox.str &= $pl
        state.rowbox.width += w
        state.word = state.word.substr(pl.len)
        state.ww = state.word.width()
      if r == Rune(' '):
        state.skip = true
      state.inlineWrap()
  of WORD_BREAK_KEEP_ALL:
    if state.fromx + state.width > state.ibox.x and
        state.fromx + state.width + state.ww + r.width() > state.ibox.bcontext.width:
      state.wrapNormal(r)

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.ibox.icontext.whitespace = false
  state.ibox.icontext.ws_initial = true
  state.skip = true

proc processInlineBox(lstate: var LayoutState, parent: CSSBox, str: string): CSSBox =
  if str.len > 0:
    parent.icontext.fromy += parent.bcontext.margin_todo
    parent.bcontext.margin_done += parent.bcontext.margin_todo
    parent.bcontext.margin_todo = 0

  var state: InlineState
  state.nodes = lstate.nodes
  var use_parent = false
  if parent of CSSInlineBox:
    state.ibox = CSSInlineBox(parent)
    use_parent = true
  else:
    # TODO TODO TODO I highly doubt this is correct but it's the only way it
    # makes sense...
    state.ibox = lstate.newInlineBox(parent, parent.cssvalues.inheritProperties())

  if str.len == 0:
    return

  var i = 0
  state.newRowBox()

  var r: Rune
  while i < str.len:
    var rw = 0
    case str[i]
    of ' ', '\n', '\t':
      rw = 1
      r = Rune(str[i])
      inc i
      state.addWord()

      case state.ibox.cssvalues[PROPERTY_WHITESPACE].whitespace
      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
        if state.ibox.icontext.whitespace:
          if state.ibox.icontext.ws_initial:
            state.ibox.icontext.ws_initial = false
            state.skip = true
          else:
            state.skip = true
        state.ibox.icontext.whitespace = true
      of WHITESPACE_PRE_LINE:
        if state.ibox.icontext.whitespace:
          state.skip = true
        state.ibox.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
        state.ibox.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      r = Rune(' ')
    else:
      state.ibox.icontext.whitespace = false
      fastRuneAt(str, i, r)
      rw = r.width()

    # TODO a better line wrapping algorithm would be nice... especially because
    # this one doesn't even work
    if rw > 1 or state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak == WORD_BREAK_BREAK_ALL:
      state.addWord()

    state.checkWrap(r)

    if state.skip:
      state.skip = false
      continue

    state.word &= r
    state.ww += rw

  state.addWord()
  #eprint "write", state.rowbox.y, state.rowbox.str

  if state.rowbox.str.len > 0:
    state.ibox.content.add(state.rowbox)
    state.ibox.icontext.fromx += state.rowbox.width
    state.ibox.icontext.conty = true

  state.ibox.height += state.rowi
  if state.rowi > 0 or state.rowbox.width > 0:
    state.ibox.bcontext.margin_todo = 0
    state.ibox.bcontext.margin_done = 0
  state.ibox.icontext.fromy += state.rowi
  if use_parent:
    return nil
  return state.ibox

proc add(state: var LayoutState, parent: CSSBox, box: CSSBox) =
  if box == nil:
    return
  if box of CSSBlockBox:
    parent.icontext.fromx = parent.x
    parent.icontext.whitespace = true
    parent.icontext.ws_initial = true

    box.flushLines()

    let mbot = box.cssvalues[PROPERTY_MARGIN_BOTTOM].length.cells_h(state, parent.bcontext.width)
    parent.bcontext.margin_todo += mbot

    parent.bcontext.margin_done = box.bcontext.margin_done
    parent.bcontext.margin_todo = max(parent.bcontext.margin_todo - box.bcontext.margin_done, 0)

    if box.bcontext.height.isnone:
      parent.icontext.fromy = box.icontext.fromy
    else:
      parent.icontext.fromy += box.bcontext.height.get
    #eprint "END", CSSBlockBox(box).tag, box.icontext.fromy
  elif box of CSSInlineBox:
    parent.icontext.fromx += box.cssvalues[PROPERTY_MARGIN_RIGHT].length.cells_w(state, parent.bcontext.width)
    parent.icontext.fromy = box.icontext.fromy

  parent.height += box.height

  parent.children.add(box)

func isBlock(node: Node): bool =
  if node.nodeType != ELEMENT_NODE:
    return false
  let elem = Element(node)
  return elem.cssvalues[PROPERTY_DISPLAY].display == DISPLAY_BLOCK or
          elem.cssvalues[PROPERTY_DISPLAY].display == DISPLAY_LIST_ITEM

proc processComputedValueBox(state: var LayoutState, parent: CSSBox, values: CSSComputedValues): CSSBox =
  case values[PROPERTY_DISPLAY].display
  of DISPLAY_BLOCK:
    #eprint "START", elem.tagType, parent.icontext.fromy
    result = state.newBlockBox(parent, values)
    #CSSBlockBox(result).tag = $elem.tagType
  of DISPLAY_INLINE:
    result = state.newInlineBox(parent, values)
  of DISPLAY_LIST_ITEM:
    result = state.newBlockBox(parent, values)
  of DISPLAY_NONE:
    return nil
  else:
    return nil

proc processBr(state: var LayoutState, parent: CSSBox, vals: CSSComputedValues) =
  if vals[PROPERTY_DISPLAY].display == DISPLAY_INLINE:
    if parent.icontext.conty:
      inc parent.height
      inc parent.icontext.fromy
      parent.icontext.conty = false
    else:
      inc parent.icontext.fromy
    parent.icontext.whitespace = true
    parent.icontext.ws_initial = true
    parent.icontext.fromx = parent.x

proc processElemBox(state: var LayoutState, parent: CSSBox, elem: Element): CSSBox =
  if elem.tagType == TAG_BR:
    state.processBr(parent, elem.cssvalues)

  result = state.processComputedValueBox(parent, elem.cssvalues)
  if result != nil:
    result.node = elem

proc processNodes(state: var LayoutState, parent: CSSBox, node: Node)

proc processNode(state: var LayoutState, parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    result = state.processElemBox(parent, Element(node))
    if result == nil:
      return

    state.processNodes(result, node)
  of TEXT_NODE:
    let text = Text(node)
    result = state.processInlineBox(parent, text.data)
    if result != nil:
      result.node = node
  else: discard

# ugh this is ugly, but it works...
# basically this
# * checks if there's a ::before pseudo element
# * checks if we need to wrap things in anonymous block boxes
# * in case we do, it adds the text to the anonymous box
# * in case we don't, it tries to add the text to a new parent box
# * but only if a new parent box is needed.
proc processBeforePseudoElem(state: var LayoutState, parent: CSSBox, node: Node) =
  if node.nodeType == ELEMENT_NODE:
    let elem = Element(node)

    if elem.cssvalues_before != nil:
      var box: CSSBox
      box = state.processComputedValueBox(parent, elem.cssvalues_before)
      if box != nil:
        box.node = node

      let text = elem.cssvalues_before[PROPERTY_CONTENT].content
      var inline = state.processInlineBox(box, $text)
      if inline != nil:
        inline.node = node
        state.add(box, inline)

      state.add(parent, box)

# same as before except it's after
proc processAfterPseudoElem(state: var LayoutState, parent: CSSBox, node: Node) =
  if node.nodeType == ELEMENT_NODE:
    let elem = Element(node)

    if elem.cssvalues_after != nil:
      let box = state.processComputedValueBox(parent, elem.cssvalues_after)
      if box != nil:
        box.node = node

      let text = elem.cssvalues_after[PROPERTY_CONTENT].content
      var inline = state.processInlineBox(box, $text)
      if inline != nil:
        inline.node = node
        state.add(box, inline)

      state.add(parent, box)

proc processMarker(state: var LayoutState, parent: CSSBox, node: Node) =
  if node.nodeType == ELEMENT_NODE:
    let elem = Element(node)
    if elem.cssvalues[PROPERTY_DISPLAY].display == DISPLAY_LIST_ITEM:
      var ordinalvalue = 1
      if elem.tagType == TAG_LI:
        ordinalvalue = HTMLLIElement(elem).ordinalvalue

      let text = elem.cssvalues[PROPERTY_LIST_STYLE_TYPE].liststyletype.listMarker(ordinalvalue)
      let tlen = text.width()
      parent.icontext.fromx -= tlen
      let marker = state.processInlineBox(parent, text)
      state.add(parent, marker)

proc processNodes(state: var LayoutState, parent: CSSBox, node: Node) =
  state.nodes.add(node)

  state.processBeforePseudoElem(parent, node)

  state.processMarker(parent, node)

  for c in node.childNodes:
    let box = state.processNode(parent, c)
    state.add(parent, box)

  state.processAfterPseudoElem(parent, node)

  discard state.nodes.pop()

proc alignBoxes*(document: Document, term: TermAttributes): CSSBox =
  var state: LayoutState
  state.term = term
  var rootbox = CSSBlockBox(x: 0, y: 0)
  rootbox.cssvalues = rootProperties()
  rootbox.icontext = newInlineContext(rootbox)
  rootbox.bcontext = newBlockContext()
  rootbox.bcontext.width = term.width
  state.nodes.add(document.root)
  state.processNodes(rootbox, document.root)
  return rootbox
