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

#proc calcConts(conts: var seq[RowContainer]) =
#  if conts.len == 0: return
#  var y = 0
#  var re = false
#  if conts[0].leaf:
#    y = conts[0].row.y
#  else:
#    y = conts[0].ctx.fromy
#  var i = 1
#  while i < conts.len:
#    let cont = conts[i]
#    if cont.leaf:
#      if y != cont.row.y:
#        re = true
#        if y < cont.row.y:
#          y = cont.row.y
#    else:
#      if y != cont.ctx.fromy:
#        re = true
#        if y < cont.ctx.fromy:
#          y = cont.ctx.fromy
#    inc i
#
#  if re:
#    i = 0
#    while i < conts.len:
#      if conts[i].leaf:
#        conts[i].row.y = y
#      else:
#        let diff = y - conts[i].ctx.fromy
#        #TODO
#        conts[i].row.y += diff
#      inc i
  
proc flushConty(box: CSSBox) =
  inc box.icontext.fromy
  inc box.bcontext.fromy
  box.icontext.conty = false
  box.icontext.whitespace = true
  box.icontext.ws_initial = true

proc flushMargins(box: CSSBox) =
  box.icontext.fromy += box.bcontext.margin_todo
  box.bcontext.margin_done += box.bcontext.margin_todo
  box.bcontext.margin_todo = 0

proc applyBlockStart(state: LayoutState, box, parent: CSSBox, vals: CSSComputedValues) =
  parent.flushMargins()
  box.bcontext = newBlockContext()
  box.x += vals[PROPERTY_MARGIN_LEFT].length.cells_w(state, parent.bcontext.width)

  let mtop = vals[PROPERTY_MARGIN_TOP].length.cells_h(state, parent.bcontext.width)
  if mtop > parent.bcontext.margin_done or mtop < 0:
    let diff = mtop - parent.bcontext.margin_done
    parent.icontext.fromy += diff
    parent.bcontext.margin_done += diff

  box.y = parent.icontext.fromy
  box.bcontext.margin_done = parent.bcontext.margin_done

  let pwidth = vals[PROPERTY_WIDTH].length
  if pwidth.auto:
    box.bcontext.width = parent.bcontext.width
  else:
    box.bcontext.width = pwidth.cells_w(state, parent.bcontext.width)

  let pheight = vals[PROPERTY_HEIGHT].length
  if not pheight.auto:
    if pheight.unit != UNIT_PERC or parent.bcontext.height.issome:
      box.bcontext.height = pheight.cells_h(state, parent.bcontext.height).some

  box.cssvalues = vals

func newBlockBox(state: var LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSBlockBox =
  new(result)
  result.t = BLOCK
  if parent.icontext.conty:
    parent.flushConty()
  result.x = parent.x

  state.applyBlockStart(result, parent, vals)
  result.icontext = newInlineContext()
  result.icontext.fromy = result.y
  result.icontext.fromx = result.x

func newInlineBlockBox*(state: LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSInlineBlockBox =
  new(result)
  result.t = INLINE_BLOCK
  result.x = parent.icontext.fromx

  state.applyBlockStart(result, parent, vals)
  result.icontext = parent.icontext
  result.icontext.fromy = result.y
  result.icontext.fromx = result.x

func newInlineBox*(state: LayoutState, parent: CSSBox, vals: CSSComputedValues): CSSInlineBox =
  new(result)
  result.t = INLINE
  result.x = parent.x
  result.y = parent.icontext.fromy

  result.icontext = parent.icontext
  result.bcontext = parent.bcontext
  result.cssvalues = vals
  result.icontext.fromx += vals[PROPERTY_MARGIN_LEFT].length.cells_w(state, parent.bcontext.width)

type InlineState = object
  icontext: InlineContext
  bcontext: BlockContext
  rowi: int
  rowbox: CSSRowBox
  rowboxes: seq[CSSRowBox]
  word: seq[Rune]
  ww: int
  skip: bool
  nodes: seq[Node]
  cssvalues: CSSComputedValues
  x: int

func fromx(state: InlineState): int = state.icontext.fromx
func width(state: InlineState): int = state.rowbox.width

proc newRowBox(state: var InlineState) =
  state.rowbox = CSSRowBox()
  state.rowbox.x = state.fromx
  state.rowbox.y = state.icontext.fromy + state.rowi

  let cssvalues = state.cssvalues
  state.rowbox.color = cssvalues[PROPERTY_COLOR].color
  state.rowbox.fontstyle = cssvalues[PROPERTY_FONT_STYLE].fontstyle
  state.rowbox.fontweight = cssvalues[PROPERTY_FONT_WEIGHT].integer
  state.rowbox.textdecoration = cssvalues[PROPERTY_TEXT_DECORATION].textdecoration
  state.rowbox.nodes = state.nodes

proc addRowBox(state: var InlineState) =
  state.rowboxes.add(state.rowbox)

proc inlineWrap(state: var InlineState) =
  state.addRowBox()
  inc state.rowi
  state.icontext.fromx = state.x
  if state.word.len == 0:
    state.icontext.whitespace = true
    state.icontext.ws_initial = true
    state.icontext.conty = false
  else:
    if state.word[^1] == Rune(' '):
      state.icontext.whitespace = true
      state.icontext.ws_initial = false
    state.icontext.conty = true
  state.newRowBox()

proc addWord(state: var InlineState) =
  state.rowbox.str &= $state.word
  state.rowbox.width += state.ww
  state.word.setLen(0)
  state.ww = 0

proc wrapNormal(state: var InlineState, r: Rune) =
  if state.fromx + state.width + state.ww == state.bcontext.width and r == Rune(' '):
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
  if state.cssvalues[PROPERTY_WHITESPACE].whitespace in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.cssvalues[PROPERTY_WORD_BREAK].wordbreak
  of WORD_BREAK_NORMAL:
    if state.fromx + state.width > state.x and
        state.fromx + state.width + state.ww + r.width() > state.x + state.bcontext.width:
      state.wrapNormal(r)
  of WORD_BREAK_BREAK_ALL:
    if state.fromx + state.width + state.ww + r.width() > state.x + state.bcontext.width:
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
    if state.fromx + state.width > state.x and
        state.fromx + state.width + state.ww + r.width() > state.x + state.bcontext.width:
      state.wrapNormal(r)

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.icontext.whitespace = false
  state.icontext.ws_initial = true
  state.skip = true

proc processInlineText(str: string, icontext: InlineContext,
                       bcontext: BlockContext, cssvalues: CSSComputedValues,
                       x: int, nodes: seq[Node]): seq[CSSRowBox] =
  var state: InlineState
  state.icontext = icontext
  state.bcontext = bcontext
  state.cssvalues = cssvalues
  state.x = x
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

      case state.cssvalues[PROPERTY_WHITESPACE].whitespace
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
    if rw > 1 or state.cssvalues[PROPERTY_WORD_BREAK].wordbreak == WORD_BREAK_BREAK_ALL:
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
    state.icontext.conty = true

  if state.rowi > 0 or state.rowbox.width > 0:
    state.bcontext.margin_todo = 0
    state.bcontext.margin_done = 0
  state.icontext.fromy += state.rowi

  return state.rowboxes

proc processInlineContext(ibox: CSSInlineBox, str: string, nodes: seq[Node]) =
  let rows = processInlineText(str, ibox.icontext, ibox.bcontext, ibox.cssvalues, ibox.x, nodes)
  ibox.icontext.rows.add(rows)

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

  let mbot = box.cssvalues[PROPERTY_MARGIN_BOTTOM].length.cells_h(state, parent.bcontext.width)
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
  parent.icontext.fromx += box.cssvalues[PROPERTY_MARGIN_RIGHT].length.cells_w(state, parent.bcontext.width)
  parent.icontext.fromy = box.icontext.fromy

  parent.children.add(box)

proc add(state: var LayoutState, parent: CSSBox, box: CSSInlineBlockBox) =
  parent.icontext.fromx = box.icontext.fromx
  parent.icontext.fromx += box.cssvalues[PROPERTY_MARGIN_RIGHT].length.cells_w(state, parent.bcontext.width)
  parent.icontext.conty = box.icontext.conty

  state.applyBlockEnd(parent, box)
  parent.children.add(box)

proc add(state: var LayoutState, parent: CSSBox, box: CSSBox) =
  case box.t
  of BLOCK: state.add(parent, CSSBlockBox(box))
  of INLINE: state.add(parent, CSSInlineBox(box))
  of INLINE_BLOCK: state.add(parent, CSSInlineBlockBox(box))

proc processComputedValueBox(state: var LayoutState, parent: CSSBox, values: CSSComputedValues): CSSBox =
  case values[PROPERTY_DISPLAY].display
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

proc processBr(state: var LayoutState, parent: CSSBox, vals: CSSComputedValues) =
  if vals[PROPERTY_DISPLAY].display == DISPLAY_INLINE:
    if parent.icontext.conty:
      parent.flushConty()
    else:
      inc parent.bcontext.fromy
      inc parent.icontext.fromy
    parent.icontext.fromx = parent.x

proc processElemBox(state: var LayoutState, parent: CSSBox, elem: Element): CSSBox =
  if elem.tagType == TAG_BR:
    state.processBr(parent, elem.cssvalues)

  result = state.processComputedValueBox(parent, elem.cssvalues)
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
  if elem.cssvalues_before != nil:
    let box = state.processComputedValueBox(parent, elem.cssvalues_before)
    if box == nil: return
    box.node = elem

    let text = elem.cssvalues_before[PROPERTY_CONTENT].content
    var inline = state.processInlineBox(box, $text)
    if inline != nil:
      inline.node = elem
      state.add(box, inline)

    state.add(parent, box)

proc processAfterPseudoElem(state: var LayoutState, parent: CSSBox, elem: Element) =
  if elem.cssvalues_after != nil:
    let box = state.processComputedValueBox(parent, elem.cssvalues_after)
    if box == nil: return
    box.node = elem

    let text = elem.cssvalues_after[PROPERTY_CONTENT].content
    var inline = state.processInlineBox(box, $text)
    if inline != nil:
      inline.node = elem
      state.add(box, inline)

    state.add(parent, box)

proc processMarker(state: var LayoutState, parent: CSSBox, elem: Element) =
  if elem.cssvalues[PROPERTY_DISPLAY].display == DISPLAY_LIST_ITEM:
    var ordinalvalue = 1
    if elem.tagType == TAG_LI:
      ordinalvalue = HTMLLIElement(elem).ordinalvalue

    let text = elem.cssvalues[PROPERTY_LIST_STYLE_TYPE].liststyletype.listMarker(ordinalvalue)
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
