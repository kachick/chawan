import unicode

import utils/twtstr
import io/cell

type
  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref CSSBoxObj
  CSSBoxObj = object of RootObj
    innerEdge*: CSSRect
    paddingEdge*: CSSRect
    borderEdge*: CSSRect
    marginEdge*: CSSRect
    children*: seq[CSSBox]

  CSSRowBox* = object
    width*: int
    height*: int
    runes*: seq[Rune]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
    fromx*: int
    content*: seq[CSSRowBox]

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

func w*(box: CSSBox): int =
  return box.innerEdge.x2 - box.innerEdge.x1

func h*(box: CSSBox): int =
  return box.innerEdge.y2 - box.innerEdge.y1
