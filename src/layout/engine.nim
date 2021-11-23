import unicode

import layout/box
import types/enums
import html/dom
import css/values
import utils/twtstr

func newContext*(box: CSSBox): Context =
  new(result)
  result.fromx = box.x
  result.whitespace = true
  result.ws_initial = true

func newBlockBox*(parent: CSSBox, vals: CSSComputedValues): CSSBlockBox =
  new(result)
  result.bcontext = parent.bcontext #TODO statify
  result.x = parent.x
  if parent.context.conty:
    inc parent.height
    #eprint "CONTY N"
    inc parent.context.fromy
    parent.context.conty = false
  result.y = parent.context.fromy
  let mtop = vals[PROPERTY_MARGIN_TOP].length.cells()
  if mtop > parent.bcontext.marginy:
    result.y += mtop - parent.bcontext.marginy
    parent.bcontext.marginy = mtop
    #eprint "M-TOP", mtop - parent.bcontext.marginy

  result.width = parent.width
  result.context = newContext(parent)
  result.context.fromy = result.y
  result.cssvalues = vals

func newInlineBox*(parent: CSSBox, vals: CSSComputedValues): CSSInlineBox =
  assert parent != nil
  new(result)
  result.x = parent.x
  result.y = parent.context.fromy

  result.width = parent.width
  result.context = parent.context
  result.bcontext = parent.bcontext
  result.cssvalues = vals
  if result.context == nil:
    result.context = newContext(parent)

type InlineState = object
  ibox: CSSInlineBox
  rowi: int
  rowbox: CSSRowBox
  word: seq[Rune]
  ww: int
  skip: bool

func fromx(state: InlineState): int = state.ibox.context.fromx

func width(state: InlineState): int = state.rowbox.width

proc newRowBox(state: var InlineState) =
  state.rowbox = CSSRowBox()
  state.rowbox.x = state.ibox.context.fromx
  state.rowbox.y = state.ibox.context.fromy + state.rowi

  let cssvalues = state.ibox.cssvalues
  state.rowbox.color = cssvalues[PROPERTY_COLOR].color
  state.rowbox.fontstyle = cssvalues[PROPERTY_FONT_STYLE].fontstyle
  state.rowbox.fontweight = cssvalues[PROPERTY_FONT_WEIGHT].integer
  state.rowbox.textdecoration = cssvalues[PROPERTY_TEXT_DECORATION].textdecoration
  state.rowbox.nodes = state.ibox.bcontext.nodes

proc inlineWrap(state: var InlineState) =
  state.ibox.content.add(state.rowbox)
  inc state.rowi
  state.ibox.context.fromx = state.ibox.x
  if state.word.len == 0:
    state.ibox.context.whitespace = true
    state.ibox.context.ws_initial = true
    state.ibox.context.conty = false
  else:
    if state.word[^1] == Rune(' '):
      state.ibox.context.whitespace = true
      state.ibox.context.ws_initial = false
    state.ibox.context.conty = true
  state.newRowBox()

proc addWord(state: var InlineState) =
  state.rowbox.str &= $state.word
  state.rowbox.width += state.ww
  state.word.setLen(0)
  state.ww = 0

proc wrapNormal(state: var InlineState, r: Rune) =
  if state.fromx + state.width + state.ww == state.ibox.width and r == Rune(' '):
    state.addWord()
  if state.word.len == 0:
    if r == Rune(' '):
      state.skip = true
  elif state.word[0] == Rune(' '):
    state.word = state.word.substr(1)
    dec state.ww
  state.inlineWrap()
  if not state.skip and r == Rune(' '):
    state.ibox.context.whitespace = true
    state.ibox.context.ws_initial = false

proc checkWrap(state: var InlineState, r: Rune) =
  if state.ibox.cssvalues[PROPERTY_WHITESPACE].whitespace in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  case state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak
  of WORD_BREAK_NORMAL:
    if state.fromx + state.width > state.ibox.x and
        state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      state.wrapNormal(r)
  of WORD_BREAK_BREAK_ALL:
    if state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      var pl: seq[Rune]
      var i = 0
      var w = 0
      while i < state.word.len and
          state.ibox.context.fromx + state.rowbox.width + w <
            state.ibox.width:
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
        state.fromx + state.width + state.ww + r.width() > state.ibox.width:
      state.wrapNormal(r)

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.ibox.context.whitespace = false
  state.ibox.context.ws_initial = true
  state.skip = true

proc processInlineBox(parent: CSSBox, str: string): CSSBox =
  var state: InlineState
  var use_parent = false
  if parent of CSSInlineBox:
    state.ibox = CSSInlineBox(parent)
    use_parent = true
  else:
    state.ibox = newInlineBox(parent, parent.cssvalues)

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
        if state.ibox.context.whitespace:
          if state.ibox.context.ws_initial:
            state.ibox.context.ws_initial = false
            state.skip = true
          else:
            state.skip = true
        state.ibox.context.whitespace = true
      of WHITESPACE_PRE_LINE:
        if state.ibox.context.whitespace:
          state.skip = true
        state.ibox.context.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
        state.ibox.context.ws_initial = false
        if r == Rune('\n'):
          state.preWrap()
      r = Rune(' ')
    else:
      state.ibox.context.whitespace = false
      fastRuneAt(str, i, r)
      rw = r.width()

    #TODO a better line wrapping algorithm would be nice
    if rw > 1 and state.ibox.cssvalues[PROPERTY_WORD_BREAK].wordbreak != WORD_BREAK_KEEP_ALL:
      state.addWord()

    state.checkWrap(r)

    if state.skip:
      state.skip = false
      continue

    state.word &= r
    state.ww += rw

  state.addWord()

  if state.rowbox.str.len > 0:
    state.ibox.content.add(state.rowbox)
    state.ibox.context.fromx += state.rowbox.width
    state.ibox.context.conty = true

  state.ibox.height += state.rowi
  if state.rowi > 0 or state.rowbox.width > 0:
    parent.bcontext.marginy = 0
  state.ibox.context.fromy += state.rowi
  if use_parent:
    return nil
  return state.ibox

proc processElemBox(parent: CSSBox, elem: Element): CSSBox =
  case elem.cssvalues[PROPERTY_DISPLAY].display
  of DISPLAY_BLOCK:
    #eprint "START", elem.tagType, parent.context.fromy
    result = newBlockBox(parent, elem.cssvalues)
    CSSBlockBox(result).tag = $elem.tagType
  of DISPLAY_INLINE:
    result = newInlineBox(parent, elem.cssvalues)
  of DISPLAY_NONE:
    return nil
  else:
    return nil

proc add(parent: var CSSBox, box: CSSBox) =
  if box == nil:
    return
  if box of CSSBlockBox:
    parent.context.fromx = 0
    parent.context.whitespace = true
    parent.context.ws_initial = true
    if box.context.conty:
      #eprint "CONTY A"
      inc box.height
      inc box.context.fromy
      box.context.conty = false
    let mbot = box.cssvalues[PROPERTY_MARGIN_BOTTOM].length.cells()
    box.context.fromy += mbot
    box.bcontext.marginy = mbot
    #eprint "M-BOT", mbot
    #eprint "END", CSSBlockBox(box).tag, box.context.fromy
  parent.height += box.height
  parent.context.fromy = box.context.fromy
  parent.children.add(box)

#proc processPseudoBox(parent: CSSBox, cssvalues: CSSComputedValues): CSSBox =
#  case cssvalues[PROPERTY_DISPLAY].display
#  of DISPLAY_BLOCK:
#    result = newBlockBox(parent, cssvalues)
#    result.add(processInlineBox(parent, $cssvalues[PROPERTY_CONTENT].content)) 
#  of DISPLAY_INLINE:
#    result = processInlineBox(parent, $cssvalues[PROPERTY_CONTENT].content)
#  of DISPLAY_NONE:
#    return nil
#  else:
#    return nil

proc processNode(parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    let elem = Element(node)
    parent.bcontext.nodes.add(node)

    result = processElemBox(parent, elem)
    if result == nil:
      return

    #TODO pseudo
    #if elem.cssvalues_before.isSome:
    #  let bbox = processPseudoBox(parent, elem.cssvalues_before.get)
    #  if bbox != nil:
    #    result.add(bbox)

    for child in elem.childNodes:
      result.add(processNode(result, child))

    #if elem.cssvalues_after.isSome:
    #  let abox = processPseudoBox(parent, elem.cssvalues_after.get)
    #  if abox != nil:
    #    result.add(abox)
    discard parent.bcontext.nodes.pop()
  of TEXT_NODE:
    let text = Text(node)
    result = processInlineBox(parent, text.data)
  else: discard

proc alignBoxes*(document: Document, width: int, height: int): CSSBox =
  var rootbox = CSSBlockBox(x: 0, y: 0, width: width, height: 0)
  rootbox.context = newContext(rootbox)
  rootbox.bcontext = new(BlockContext)
  rootbox.bcontext.nodes.add(document.root)
  for child in document.root.childNodes:
    CSSBox(rootbox).add(processNode(rootbox, child))
  return rootbox
