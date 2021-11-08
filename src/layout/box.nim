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
    x*: int
    y*: int
    fromx*: int
    width*: int
    height*: int
    children*: seq[CSSBox]

  CSSRowBox* = object
    x*: int
    y*: int
    width*: int
    height*: int
    runes*: seq[Rune]

  CSSInlineBox* = ref CSSInlineBoxObj
  CSSInlineBoxObj = object of CSSBox
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
