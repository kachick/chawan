import unicode

import layout/box
import types/enums
import html/dom
import css/style
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

#TODO there should be actual inline contexts to store these stuff
proc setup(rowbox: var CSSRowBox, cssvalues: CSSComputedValues, nodes: seq[Node]) =
  rowbox.color = cssvalues[PROPERTY_COLOR].color
  rowbox.fontstyle = cssvalues[PROPERTY_FONT_STYLE].fontstyle
  rowbox.fontweight = cssvalues[PROPERTY_FONT_WEIGHT].integer
  rowbox.textdecoration = cssvalues[PROPERTY_TEXT_DECORATION].textdecoration
  rowbox.nodes = nodes

proc inlineWrap(ibox: var CSSInlineBox, rowi: var int, fromx: var int, rowbox: var CSSRowBox) =
  ibox.content.add(rowbox)
  inc rowi
  fromx = ibox.x
  ibox.context.whitespace = true
  ibox.context.ws_initial = true
  ibox.context.conty = false
  rowbox = CSSRowBox(x: ibox.x, y: ibox.y + rowi)
  rowbox.setup(ibox.cssvalues, ibox.bcontext.nodes)

#TODO statify
proc processInlineBox(parent: CSSBox, str: string): CSSBox =
  var ibox: CSSInlineBox
  var use_parent = false
  if parent of CSSInlineBox:
    ibox = CSSInlineBox(parent)
    use_parent = true
  else:
    ibox = newInlineBox(parent, parent.cssvalues)

  if str.len == 0:
    return

  var i = 0
  var rowi = 0
  var fromx = ibox.context.fromx
  var rowbox = CSSRowBox(x: fromx, y: ibox.context.fromy)
  rowbox.setup(ibox.cssvalues, ibox.bcontext.nodes)
  var r: Rune
  while i < str.len:
    case str[i]
    of ' ', '\n', '\t':
      inc i
      let wsr = ibox.cssvalues[PROPERTY_WHITESPACE].whitespace
      if ibox.context.whitespace:
        if ibox.context.ws_initial:
          ibox.context.ws_initial = false
          if not (wsr in {WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP}):
            continue
        else:
          continue
      case wsr
      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
        r = Rune(' ')
      of WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP:
        if str[i - 1] == '\n':
          inlineWrap(ibox, rowi, fromx, rowbox)
          ibox.context.whitespace = false
          ibox.context.ws_initial = true
          continue
        r = Rune(' ')
      case wsr
      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE_LINE:
        ibox.context.whitespace = true
      else:
        ibox.context.whitespace = false
    else:
      ibox.context.whitespace = false
      fastRuneAt(str, i, r)
      if rowbox.width + r.width() > ibox.width:
        inlineWrap(ibox, rowi, fromx, rowbox)

    rowbox.width += r.width()
    rowbox.runes.add(r)
  if rowbox.runes.len > 0:
    ibox.content.add(rowbox)
    ibox.context.fromx = fromx + rowbox.width
    ibox.context.conty = true

  ibox.height += rowi
  #eprint "inc i", rowi, rowbox.runes
  if rowi > 0 or rowbox.width > 0:
    parent.bcontext.marginy = 0
  ibox.context.fromy += rowi
  if use_parent:
    return nil
  return ibox

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
  for child in document.root.childNodes:
    CSSBox(rootbox).add(processNode(rootbox, child))
  return rootbox
