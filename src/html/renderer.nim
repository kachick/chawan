import unicode

import types/enums
import html/dom
import css/box
import css/style
import io/buffer
import utils/twtstr

func boxesForText*(text: seq[Rune], width: int, height: int, lx: int, x: int, y: int): seq[CSSInlineBox] =
  result.add(CSSInlineBox())
  var w = x
  var sx = x
  var sy = y
  var i = 0
  while i < text.len and sy < height:
    let cw = text[i].width()
    if w + cw > width:
      result[^1].innerEdge.x2 = sx + w
      result[^1].innerEdge.y2 = sy + 1
      sx = lx
      inc sy
      w = 0

      result[^2].nextpart = result[^1]
      result.add(CSSInlineBox())
      result[^1].innerEdge.x1 = sx
      result[^1].innerEdge.y1 = sy

    result[^1].content &= text[i]
    w += cw
    inc i

    result[^1].innerEdge.y1 = sy
  if result.len > 1:
    result[^2].nextpart = result[^1]
  if w > 0:
    result[^1].innerEdge.x1 = sx
    result[^1].innerEdge.y1 = sy
    result[^1].innerEdge.x2 = sx + w
    result[^1].innerEdge.y2 = sy + 1

proc generateBox(elem: Element, x: int, y: int, w: int, h: int, fromx: int = x): CSSBox =
  let display = elem.cssvalues[RULE_DISPLAY]
  if display.t == RULE_DISPLAY:
    if display.display == DISPLAY_NONE:
      return nil
  new(result)
  result.innerEdge.x1 = x
  result.innerEdge.y1 = y

  var anonBoxes = false
  for child in elem.children:
    let rule = child.cssvalues[RULE_DISPLAY]
    if rule.t == RULE_DISPLAY and rule.display == DISPLAY_BLOCK:
      anonBoxes = true
      break
  var lx = fromx
  var rx = x
  var ry = y
  for child in elem.childNodes:
    if child.nodeType == ELEMENT_NODE:
      let elem = Element(child)
      let nbox = elem.generateBox(rx, ry, w, h)
      if nbox != nil:
        result.innerEdge.x2 = min(max(nbox.size().w, result.innerEdge.x2), w)
        result.innerEdge.y2 = min(result.innerEdge.y2 + nbox.size().h, w)
        rx = x
        ry += nbox.size().h
        result.children.add(nbox)
    elif child.nodeType == TEXT_NODE:
      let text = Text(child)
      let runes = text.data.toRunes()
      let boxes = boxesForText(runes, w, h, lx, rx, ry)
      for child in boxes:
        result.children.add(child)
        result.innerEdge.y2 += child.size().h
        ry += child.size().h
      lx = boxes[^1].innerEdge.x2

proc alignBoxes*(buffer: Buffer) =
  buffer.rootbox = buffer.document.root.generateBox(0, 0, buffer.width, buffer.height)
