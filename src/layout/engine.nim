import unicode
import options

import layout/box
import html/tags
import html/dom
import css/values
import utils/twtstr
import io/term

func cells_in(l: CSSLength, state: LayoutState, d: int, p: Option[int], o: bool): int =
  return cells(l, d, state.term.width_px, state.term.height_px, p, o)

func cells_w(l: CSSLength, state: LayoutState, p: int): int =
  return l.cells_in(state, state.term.ppc, p.some, true)

func cells_h(l: CSSLength, state: LayoutState, p: Option[int]): int =
  return l.cells_in(state, state.term.ppl, p, false)

func cells_h(l: CSSLength, state: LayoutState, p: int): int =
  return l.cells_in(state, state.term.ppl, p.some, false)

func newInlineContext*(): InlineContext =
  new(result)
  result.whitespace = true
  result.ws_initial = true

func newBlockContext(): BlockContext =
  new(result)

proc putRows(icontext: InlineContext) =
  var i = 0
  while i < icontext.rows.len:
    icontext.rows[i].bottom = icontext.fromy
    inc i

proc flushRows(icontext: InlineContext) =
  if icontext.thisrow.len == 0: return
  icontext.putRows()
  var y = 0
  var re = false
  y = icontext.thisrow[0].bottom
  var i = 1
  while i < icontext.thisrow.len:
    let ry = icontext.thisrow[i].bottom
    if y != ry:
      re = true
      if y < ry:
        y = ry
    inc i

  if re:
    i = 0
    while i < icontext.thisrow.len:
      icontext.thisrow[i].y = y + icontext.thisrow[i].y - icontext.thisrow[i].bottom
      inc i
  icontext.rows.add(icontext.thisrow)
  icontext.thisrow.setLen(0)

func conty(icontext: InlineContext): bool =
  icontext.thisrow.len > 0

proc flushConty(box: CSSBox) =
  box.icontext.flushRows()
  box.icontext.fromx = box.x
  inc box.icontext.fromy
  inc box.bcontext.fromy
  box.icontext.whitespace = true
  box.icontext.ws_initial = true

proc flushMargins(box: CSSBox) =
  box.icontext.fromy += box.bcontext.margin_todo
  box.bcontext.margin_done += box.bcontext.margin_todo
  box.bcontext.margin_todo = 0

proc applyBlockStart(state: LayoutState, box, parent: CSSBox, vals: CSSSpecifiedValues) =
  parent.flushMargins()
  box.bcontext = newBlockContext()
  box.x += vals{"margin-left"}.cells_w(state, parent.bcontext.width)

  let mtop = vals{"margin-top"}.cells_h(state, parent.bcontext.width)
  if mtop > parent.bcontext.margin_done or mtop < 0:
    let diff = mtop - parent.bcontext.margin_done
    parent.icontext.fromy += diff
    parent.bcontext.margin_done += diff

  box.y = parent.icontext.fromy
  box.bcontext.margin_done = parent.bcontext.margin_done

  let pwidth = vals{"width"}
  if pwidth.auto:
    box.bcontext.width = parent.bcontext.width
  else:
    box.bcontext.width = pwidth.cells_w(state, parent.bcontext.width)

  let pheight = vals{"height"}
  if not pheight.auto:
    if pheight.unit != UNIT_PERC or parent.bcontext.height.issome:
      box.bcontext.height = pheight.cells_h(state, parent.bcontext.height).some

  box.cssvalues = vals

func newBlockBox(state: var LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSBlockBox =
  new(result)
  result.t = BOX_BLOCK
  if parent.icontext.conty:
    parent.flushConty()
  result.x = parent.x

  state.applyBlockStart(result, parent, vals)
  result.icontext = newInlineContext()
  result.icontext.fromy = result.y
  result.icontext.fromx = result.x

func newInlineBlockBox*(state: LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSInlineBlockBox =
  new(result)
  result.t = BOX_INLINE_BLOCK
  result.x = parent.icontext.fromx

  state.applyBlockStart(result, parent, vals)
  result.icontext = newInlineContext()
  result.icontext.fromy = result.y
  result.icontext.fromx = result.x

func newInlineBox*(state: LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSInlineBox =
  new(result)
  result.t = BOX_INLINE
  result.x = parent.x
  result.y = parent.icontext.fromy

  result.icontext = parent.icontext
  result.bcontext = parent.bcontext
  result.cssvalues = vals
  result.icontext.fromx += vals{"margin-left"}.cells_w(state, parent.bcontext.width)

type InlineState = object
  icontext: InlineContext
  bcontext: BlockContext
  ibox: CSSInlineBox
  rowbox: CSSRowBox
  word: seq[Rune]
  ww: int
  skip: bool
  nodes: seq[Node]
  cssvalues: CSSSpecifiedValues
  x: int

func maxwidth(state: InlineState): int = state.bcontext.width

proc newRowBox(state: var InlineState) =
  state.rowbox = CSSRowBox()
  state.rowbox.x = state.icontext.fromx
  state.rowbox.y = state.icontext.fromy
  state.rowbox.bottom = state.rowbox.y

  let cssvalues = state.cssvalues
  state.rowbox.color = cssvalues{"color"}
  state.rowbox.fontstyle = cssvalues{"font-style"}
  state.rowbox.fontweight = cssvalues{"font-weight"}
  state.rowbox.textdecoration = cssvalues{"text-decoration"}
  state.rowbox.nodes = state.nodes

proc addRowBox(state: var InlineState) =
  state.icontext.thisrow.add(state.rowbox)

proc inlineWrap(state: var InlineState) =
  state.addRowBox()
  state.icontext.flushRows()
  inc state.icontext.fromy
  state.icontext.fromx = state.x
  if state.word.len == 0:
    state.icontext.whitespace = true
    state.icontext.ws_initial = true
  else:
    if state.word[^1] == Rune(' '):
      state.icontext.whitespace = true
      state.icontext.ws_initial = false
  state.newRowBox()

proc addWord(state: var InlineState) =
  state.rowbox.str &= $state.word
  state.rowbox.width += state.ww
  state.ibox.width += state.ww
  state.ibox.width = min(state.maxwidth, state.ibox.width)
  state.word.setLen(0)
  state.ww = 0

proc wrapNormal(state: var InlineState, r: Rune) =
  if state.icontext.fromx + state.rowbox.width + state.ww == state.maxwidth and r == Rune(' '):
    state.addWord()
  if state.word.len == 0:
    if r == Rune(' '):
      state.skip = true
  elif state.word[0] == Rune(' '):
    state.word = state.word.substr(1)
    dec state.ww
  state.inlineWrap()
  if not state.skip and r == Rune(' '):
    state.icontext.whitespace = true
    state.icontext.ws_initial = false

proc checkWrap(state: var InlineState, r: Rune) =
  if state.cssvalues{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.cssvalues{"word-break"}
  of WORD_BREAK_NORMAL:
    if state.icontext.fromx + state.rowbox.width > state.x and
        state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
      state.wrapNormal(r)
  of WORD_BREAK_BREAK_ALL:
    if state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
      var pl: seq[Rune]
      var i = 0
      var w = 0
      while i < state.word.len and
          state.icontext.fromx + state.rowbox.width + w <
            state.bcontext.width:
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
    if state.icontext.fromx + state.rowbox.width > state.x and
        state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
      state.wrapNormal(r)

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.icontext.whitespace = false
  state.icontext.ws_initial = true
  state.skip = true

proc processInlineText(str: string, ibox: CSSInlineBox, nodes: seq[Node]) =
  var state: InlineState
  state.ibox = ibox
  state.icontext = ibox.icontext
  state.bcontext = ibox.bcontext
  state.cssvalues = ibox.cssvalues
  state.x = ibox.x
  state.nodes = nodes

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

      case state.cssvalues{"white-space"}
      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
        if state.icontext.whitespace:
          if state.icontext.ws_initial:
            state.icontext.ws_initial = false
            state.skip = true
          else:
            state.skip = true
        state.icontext.whitespace = true
      of WHITESPACE_PRE_LINE:
        if state.icontext.whitespace:
          state.skip = true
        state.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
        state.icontext.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      r = Rune(' ')
    else:
      state.icontext.whitespace = false
      fastRuneAt(str, i, r)
      rw = r.width()

    # TODO a better line wrapping algorithm would be nice... especially because
    # this one doesn't even work
    if rw > 1 or state.cssvalues{"word-break"} == WORD_BREAK_BREAK_ALL:
      state.addWord()

    state.checkWrap(r)

    if state.skip:
      state.skip = false
      continue

    state.word &= r
    state.ww += rw

  state.addWord()

  if state.rowbox.str.len > 0:
    state.addRowBox()
    state.icontext.fromx += state.rowbox.width

  state.bcontext.margin_todo = 0
  state.bcontext.margin_done = 0

proc processInlineContext(ibox: CSSInlineBox, str: string, nodes: seq[Node]) =
  processInlineText(str, ibox, nodes)

proc processInlineBox(state: var LayoutState, parent: CSSBox, str: string): CSSInlineBox =
  if str.len == 0:
    return nil

  #TODO this doesn't really belong in here
  parent.flushMargins()

  if parent of CSSInlineBox:
    let ibox = CSSInlineBox(parent)
    ibox.processInlineContext(str, state.nodes)
    return nil

  let ibox = state.newInlineBox(parent, parent.cssvalues.inheritProperties())
  ibox.processInlineContext(str, state.nodes)
  return ibox

proc applyBlockEnd(state: var LayoutState, parent, box: CSSBox) =
  box.flushMargins()

  let mbot = box.cssvalues{"margin-bottom"}.cells_h(state, parent.bcontext.width)
  parent.bcontext.margin_todo += mbot

  parent.bcontext.margin_done = box.bcontext.margin_done
  parent.bcontext.margin_todo = max(parent.bcontext.margin_todo - box.bcontext.margin_done, 0)

  if box.bcontext.height.isnone:
    parent.icontext.fromy = box.icontext.fromy
  else:
    parent.icontext.fromy += box.bcontext.height.get

proc add(state: var LayoutState, parent: CSSBox, box: CSSBlockBox) =
  parent.icontext.fromx = parent.x
  if box.icontext.conty:
    box.flushConty()

  state.applyBlockEnd(parent, box)
  parent.children.add(box)

proc add(state: var LayoutState, parent: CSSBox, box: CSSInlineBox) =
  parent.width = max(parent.width, box.width)
  parent.icontext.fromx += box.cssvalues{"margin-right"}.cells_w(state, parent.bcontext.width)
  parent.icontext.fromy = box.icontext.fromy

  parent.children.add(box)

proc add(state: var LayoutState, parent: CSSBox, box: CSSInlineBlockBox) =
  parent.width = max(parent.width, box.width)
  parent.icontext.fromx = max(box.icontext.fromx, box.x + box.width)
  parent.icontext.fromx += box.cssvalues{"margin-right"}.cells_w(state, parent.bcontext.width)
  parent.icontext.whitespace = box.icontext.whitespace
  parent.icontext.ws_initial = box.icontext.ws_initial

  box.icontext.putRows()
  parent.icontext.thisrow.add(box.icontext.rows)
  parent.icontext.thisrow.add(box.icontext.thisrow)
  box.icontext.rows.setLen(0)
  box.icontext.thisrow.setLen(0)

  state.applyBlockEnd(parent, box)
  parent.children.add(box)

proc add(state: var LayoutState, parent: CSSBox, box: CSSBox) =
  case box.t
  of BOX_BLOCK: state.add(parent, CSSBlockBox(box))
  of BOX_INLINE: state.add(parent, CSSInlineBox(box))
  of BOX_INLINE_BLOCK: state.add(parent, CSSInlineBlockBox(box))

proc processComputedValueBox(state: var LayoutState, parent: CSSBox, values: CSSSpecifiedValues): CSSBox =
  case values{"display"}
  of DISPLAY_BLOCK:
    result = state.newBlockBox(parent, values)
  of DISPLAY_INLINE_BLOCK:
    result = state.newInlineBlockBox(parent, values)
  of DISPLAY_INLINE:
    result = state.newInlineBox(parent, values)
  of DISPLAY_LIST_ITEM:
    result = state.newBlockBox(parent, values)
  of DISPLAY_NONE:
    return nil
  else:
    return nil

proc processBr(state: var LayoutState, parent: CSSBox, vals: CSSSpecifiedValues) =
  if vals{"display"} == DISPLAY_INLINE:
    if parent.icontext.conty:
      parent.flushConty()
    else:
      inc parent.bcontext.fromy
      inc parent.icontext.fromy
    parent.icontext.fromx = parent.x

proc processElemBox(state: var LayoutState, parent: CSSBox, elem: Element): CSSBox =
  if elem.tagType == TAG_BR:
    state.processBr(parent, elem.css)

  result = state.processComputedValueBox(parent, elem.css)
  if result != nil:
    result.node = elem

proc processElemChildren(state: var LayoutState, parent: CSSBox, elem: Element)

proc processNode(state: var LayoutState, parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    let elem = Element(node)
    result = state.processElemBox(parent, Element(node))
    if result == nil:
      return

    state.processElemChildren(result, elem)
  of TEXT_NODE:
    let text = Text(node)
    result = state.processInlineBox(parent, text.data)
    if result != nil:
      result.node = node
  else: discard

proc processBeforePseudoElem(state: var LayoutState, parent: CSSBox, elem: Element) =
  if elem.pseudo[PSEUDO_BEFORE] != nil:
    let box = state.processComputedValueBox(parent, elem.pseudo[PSEUDO_BEFORE])
    if box == nil: return
    box.node = elem

    let text = elem.pseudo[PSEUDO_BEFORE]{"content"}
    var inline = state.processInlineBox(box, $text)
    if inline != nil:
      inline.node = elem
      state.add(box, inline)

    state.add(parent, box)

proc processAfterPseudoElem(state: var LayoutState, parent: CSSBox, elem: Element) =
  if elem.pseudo[PSEUDO_AFTER] != nil:
    let box = state.processComputedValueBox(parent, elem.pseudo[PSEUDO_AFTER])
    if box == nil: return
    box.node = elem

    let text = elem.pseudo[PSEUDO_AFTER]{"content"}
    var inline = state.processInlineBox(box, $text)
    if inline != nil:
      inline.node = elem
      state.add(box, inline)

    state.add(parent, box)

proc processMarker(state: var LayoutState, parent: CSSBox, elem: Element) =
  if elem.css{"display"} == DISPLAY_LIST_ITEM:
    var ordinalvalue = 1
    if elem.tagType == TAG_LI:
      ordinalvalue = HTMLLIElement(elem).ordinalvalue

    let text = elem.css{"list-style-type"}.listMarker(ordinalvalue)
    let tlen = text.width()
    parent.icontext.fromx -= tlen
    let marker = state.processInlineBox(parent, text)
    if marker != nil:
      state.add(parent, marker)

proc processNodes(state: var LayoutState, parent: CSSBox, nodes: seq[Node]) =
  for node in nodes:
    let box = state.processNode(parent, node)
    if box != nil:
      state.add(parent, box)

proc processElemChildren(state: var LayoutState, parent: CSSBox, elem: Element) =
  state.nodes.add(elem)

  state.processBeforePseudoElem(parent, elem)
  state.processMarker(parent, elem)
  state.processNodes(parent, elem.childNodes)
  state.processAfterPseudoElem(parent, elem)

  discard state.nodes.pop()

proc alignBoxes*(document: Document, term: TermAttributes): CSSBox =
  var state: LayoutState
  state.term = term
  var rootbox = CSSBlockBox(x: 0, y: 0)
  rootbox.cssvalues = rootProperties()
  rootbox.bcontext = newBlockContext()
  rootbox.icontext = newInlineContext()
  rootbox.bcontext.width = term.width
  state.nodes.add(document.root)
  state.processElemChildren(rootbox, document.root)
  return rootbox

proc alignBoxes2*(document: Document, term: TermAttributes): CSSBlockBox =
  result = CSSBlockBox()
  result.bcontext = BlockContext()
  result.bcontext.content.add(CSSInlineBox())
