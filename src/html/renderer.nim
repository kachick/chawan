import unicode

import types/enums
import html/dom
import css/box
import css/style
import io/buffer
import io/cell
import utils/twtstr

# basically these are the "line boxes". though honestly this is an awful
# way to model them... but it's fine for now, I guess. TODO
# no it's actually not fine number one priority is making it work TODO TODO TODO
proc generateGrids(text: Text, maxwidth: int, maxheight: int, x: int, y: int, fromx: int = x): FlexibleGrid =
  var r: Rune
  var rowgrid: FlexibleLine
  var i = 0
  if fromx > x:
    let m = fromx - x + maxwidth
    var w = 0
    while i < text.data.len:
      let pi = i
      fastRuneAt(text.data, i, r)
      let rw = r.width()
      if rw + w > m:
        i = pi
        break
      else:
        rowgrid.add(FlexibleCell(rune: r))
        w += rw
    result.add(rowgrid)

  if i < text.data.len:
    rowgrid.setLen(0)
    var w = 0
    while i < text.data.len:
      let pi = i
      fastRuneAt(text.data, i, r)
      let rw = r.width()
      if rw + w > maxwidth:
        i = pi
        w = 0
        result.add(rowgrid)
        rowgrid.setLen(0)
      else:
        rowgrid.add(FlexibleCell(rune: r))
        w += rw

  if rowgrid.len > 0:
    result.add(rowgrid)

proc generateBox(text: Text, maxwidth: int, maxheight: int, x: int, y: int, fromx: int): CSSInlineBox =
  new(result)
  result.content = text.generateGrids(maxwidth, maxheight, x, y, fromx)
  result.fromx = fromx
  result.innerEdge.x1 = x
  result.innerEdge.y1 = y
  var height = 0
  var width = 0
  for grid in result.content:
    inc height
    width = max(width, grid.len)
  
  height = min(height, maxheight)
  width = min(width, maxwidth)
  result.innerEdge.x2 = x + width
  result.innerEdge.y2 = y + height

proc generateBox(elem: Element, maxwidth: int, maxheight: int, x: int = 0, y: int = 0, fromx: int = x): CSSBox

proc generateChildBoxes(elem: Element, maxwidth: int, maxheight: int, x: int, y: int, fromx: int = 0): seq[CSSBox] =
  var cx = fromx
  var cy = y
  for child in elem.childNodes:
    case child.nodeType
    of TEXT_NODE:
      let box = Text(child).generateBox(maxwidth, maxheight, x, cy, cx)
      if box != nil:
        result.add(box)
        cy += box.h
        if box.content.len > 0:
          cx = box.content[^1].width()
    of ELEMENT_NODE:
      let box = Element(child).generateBox(maxwidth, maxheight, x, cy, cx)
      if box != nil:
        result.add(box)
    else:
      discard

proc generateBox(elem: Element, maxwidth: int, maxheight: int, x: int = 0, y: int = 0, fromx: int = x): CSSBox =
  if elem.cssvalues[RULE_DISPLAY].display == DISPLAY_NONE:
    return nil

  result = CSSBlockBox()
  result.innerEdge.x1 = x
  result.innerEdge.y1 = y

  var width = 0
  var height = 0
  for box in elem.generateChildBoxes(maxwidth, maxheight, x, y, fromx):
    result.children.add(box)
    height += box.h
    height = min(height, maxheight)
    width = max(width, box.w)
    width = min(width, maxwidth)

  result.innerEdge.x2 = x + width
  result.innerEdge.y2 = y + height

proc alignBoxes*(buffer: Buffer) =
  buffer.rootbox = buffer.document.root.generateBox(buffer.width, buffer.height)
