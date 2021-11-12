import unicode
import options

import layout/box
import types/enums
import html/dom
import css/style
import io/buffer
import io/cell
import utils/twtstr

func newContext*(box: CSSBox): InlineContext =
  new(result)
  result.fromx = box.x
  result.whitespace = true

func newBlockBox*(parent: CSSBox, vals: CSSComputedValues): CSSBlockBox =
  new(result)
  result.bcontext = parent.bcontext #TODO statify
  result.x = parent.x
  if parent.context.conty:
    inc parent.height
    eprint "inc n"
    inc parent.context.fromy
    parent.context.conty = false
  result.y = parent.context.fromy
  let mtop = vals[RULE_MARGIN_TOP].length.cells()
  if mtop > parent.bcontext.marginy:
    result.y += mtop - parent.bcontext.marginy
    eprint "my", mtop, parent.bcontext.marginy
    parent.bcontext.marginy = mtop

  result.width = parent.width
  result.context = newContext(parent)
  eprint "inc to", result.y
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
proc setup(rowbox: var CSSRowBox, cssvalues: CSSComputedValues) =
  rowbox.color = cssvalues[RULE_COLOR].color
  rowbox.fontstyle = cssvalues[RULE_FONT_STYLE].fontstyle
  rowbox.fontweight = cssvalues[RULE_FONT_WEIGHT].integer

proc inlineWrap(ibox: var CSSInlineBox, rowi: var int, fromx: var int, rowbox: var CSSRowBox) =
  ibox.content.add(rowbox)
  inc rowi
  fromx = ibox.x
  ibox.context.whitespace = true
  ibox.context.conty = true
  rowbox = CSSRowBox(x: ibox.x, y: ibox.y + rowi)
  rowbox.setup(ibox.cssvalues)

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
  rowbox.setup(ibox.cssvalues)
  var r: Rune
  while i < str.len:
    fastRuneAt(str, i, r)
    if rowbox.width + r.width() > ibox.width:
      inlineWrap(ibox, rowi, fromx, rowbox)
    if r.isWhitespace():
      if ibox.context.whitespace:
        continue
      else:
        let wsr = ibox.cssvalues[RULE_WHITESPACE].whitespace

        case wsr
        of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
          r = Rune(' ')
        of WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP:
          if r == Rune('\n'):
            inlineWrap(ibox, rowi, fromx, rowbox)
            ibox.context.whitespace = false
            continue

        case wsr
        of WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE_LINE:
          ibox.context.whitespace = true
        else:
          ibox.context.whitespace = false
    else:
      ibox.context.whitespace = false
    rowbox.width += r.width()
    rowbox.runes.add(r)
  if rowbox.runes.len > 0:
    ibox.content.add(rowbox)
    ibox.context.fromx = fromx + rowbox.width
    ibox.context.conty = true

  ibox.height += rowi
  eprint "inc i", rowi, rowbox.runes
  if rowi > 0 or rowbox.width > 0:
    parent.bcontext.marginy = 0
  ibox.context.fromy += rowi
  if use_parent:
    return nil
  return ibox

proc processElemBox(parent: CSSBox, elem: Element): CSSBox =
  case elem.cssvalues[RULE_DISPLAY].display
  of DISPLAY_BLOCK:
    eprint "START", elem.tagType
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
    if box.context.conty:
      inc box.height
      eprint "inc a"
      inc box.context.fromy
      box.context.conty = false
    let mbot = box.cssvalues[RULE_MARGIN_BOTTOM].length.cells()
    eprint "inc b", mbot
    box.context.fromy += mbot
    box.bcontext.marginy = mbot
    eprint "END", CSSBlockBox(box).tag
  parent.height += box.height
  eprint "parent to", box.context.fromy
  parent.context.fromy = box.context.fromy
  parent.children.add(box)

proc processPseudoBox(parent: CSSBox, cssvalues: CSSComputedValues): CSSBox =
  case cssvalues[RULE_DISPLAY].display
  of DISPLAY_BLOCK:
    result = newBlockBox(parent, cssvalues)
    result.add(processInlineBox(parent, $cssvalues[RULE_CONTENT].content)) 
  of DISPLAY_INLINE:
    result = processInlineBox(parent, $cssvalues[RULE_CONTENT].content)
  of DISPLAY_NONE:
    return nil
  else:
    return nil

proc processNode(parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    let elem = Element(node)

    result = processElemBox(parent, elem)
    if result == nil:
      return

    if elem.cssvalues_before.isSome:
      let bbox = processPseudoBox(parent, elem.cssvalues_before.get)
      if bbox != nil:
        result.add(bbox)

    for child in elem.childNodes:
      result.add(processNode(result, child))

    if elem.cssvalues_after.isSome:
      let abox = processPseudoBox(parent, elem.cssvalues_after.get)
      if abox != nil:
        result.add(abox)
  of TEXT_NODE:
    let text = Text(node)
    return processInlineBox(parent, text.data)
  else: discard

proc alignBoxes*(buffer: Buffer) =
  buffer.rootbox = CSSBlockBox(x: 0, y: 0, width: buffer.width, height: 0)
  buffer.rootbox.context = newContext(buffer.rootbox)
  buffer.rootbox.bcontext = new(BlockContext)
  for child in buffer.document.root.childNodes:
    buffer.rootbox.add(processNode(buffer.rootbox, child))
