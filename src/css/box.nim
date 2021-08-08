import unicode

import utils/twtstr

type
  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref CSSBoxObj
  CSSBoxObj = object of RootObj
    content*: seq[Rune]
    innerEdge*: CSSRect
    paddingEdge*: CSSRect
    borderEdge*: CSSRect
    marginEdge*: CSSRect
    children*: seq[CSSBox]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
    nextpart: CSSInlineBox

  CSSBlockBox* = ref CSSBlockBoxObj
  CSSBlockBoxObj = object of CSSBox

func `+`(a: CSSRect, b: CSSRect): CSSRect =
  result.x1 = a.x1 + b.x1
  result.y1 = a.y1 + b.y1
  result.x2 = a.x2 + b.x2
  result.y2 = a.y2 + b.y2

proc `+=`(a: var CSSRect, b: CSSRect) =
  a = a + b

func size*(box: CSSBox): tuple[w: int, h: int] =
  return (box.innerEdge.x2 - box.innerEdge.x1, box.innerEdge.y2 - box.innerEdge.x1)

func boxesForText*(text: seq[Rune], width: int, height: int, lx: int, x: int, y: int): seq[CSSInlineBox] =
  result.add(CSSInlineBox())
  var w = x
  var sx = x
  var sy = y
  var i = 0
  while i < text.len and sy < height:
    let cw = text[i].width()
    if w + cw > width:
      result[^1].innerEdge.x1 = sx
      result[^1].innerEdge.x2 = sx + w
      result[^1].innerEdge.y1 = sy
      result[^1].innerEdge.y2 = sy + 1
      sx = lx
      inc sy
      w = 0

      result[^2].nextpart = result[^1]
      result.add(CSSInlineBox())

    result[^1].content &= text[i]
    w += cw
    inc i

  if result.len > 1:
    result[^2].nextpart = result[^1]
  if w > 0:
    result[^1].innerEdge.x1 = sx
    result[^1].innerEdge.x2 = sx + w
    result[^1].innerEdge.y1 = sy
    result[^1].innerEdge.y2 = sy + 1
