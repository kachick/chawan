import unicode
import options

import layout/box
import types/enums
import html/dom
import css/style
import io/buffer
import io/cell
import utils/twtstr

func newContext*(box: CSSBox): FormatContext =
  new(result)
  result.fromx = box.x
  result.whitespace = true

func newBlockBox*(parent: CSSBox): CSSBlockBox =
  new(result)
  result.x = parent.x
  if parent.context.conty:
    inc parent.height
    parent.context.conty = false
  result.y = parent.y + parent.height

  result.width = parent.width
  result.context = newContext(parent)

func newInlineBox*(parent: CSSBox): CSSInlineBox =
  assert parent != nil
  new(result)
  result.x = parent.x
  result.y = parent.y + parent.height

  result.width = parent.width
  result.context = parent.context
  if result.context == nil:
    result.context = newContext(parent)

proc processInlineBox(parent: CSSBox, str: string): CSSBox =
  var ibox: CSSInlineBox
  var use_parent = false
  if parent of CSSInlineBox:
    ibox = CSSInlineBox(parent)
    use_parent = true
  else:
    ibox = newInlineBox(parent)

  if str.len == 0:
    return

  var i = 0
  var rowi = 0
  var fromx = ibox.context.fromx
  var rowbox = CSSRowBox(x: fromx, y: ibox.y + rowi)
  var r: Rune
  while i < str.len:
    fastRuneAt(str, i, r)
    if rowbox.width + r.width() > ibox.width:
      ibox.content.add(rowbox)
      inc rowi
      fromx = ibox.x
      ibox.context.whitespace = true
      ibox.context.conty = false
      rowbox = CSSRowBox(x: ibox.x, y: ibox.y + rowi)
    if r.isWhitespace():
      if ibox.context.whitespace:
        continue
      else:
        ibox.context.whitespace = true
    else:
      ibox.context.whitespace = false
    rowbox.width += r.width()
    rowbox.runes.add(r)
  if rowbox.runes.len > 0:
    ibox.content.add(rowbox)
    ibox.context.fromx = fromx + rowbox.width
    ibox.context.conty = true

  ibox.height += rowi
  if use_parent:
    return nil
  return ibox

proc processElemBox(parent: CSSBox, elem: Element): CSSBox =
  case elem.cssvalues[RULE_DISPLAY].display
  of DISPLAY_BLOCK:
    result = newBlockBox(parent)
    result.context.cssvalues = elem.cssvalues
  of DISPLAY_INLINE:
    result = newInlineBox(parent)
    result.context.cssvalues = elem.cssvalues
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
  parent.height += box.height
  parent.children.add(box)

proc processPseudoBox(parent: CSSBox, cssvalues: CSSComputedValues): CSSBox =
  case cssvalues[RULE_DISPLAY].display
  of DISPLAY_BLOCK:
    result = newBlockBox(parent)
    result.context.cssvalues = cssvalues
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
  for child in buffer.document.root.childNodes:
    buffer.rootbox.add(processNode(buffer.rootbox, child))
