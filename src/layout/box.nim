import options

import css/values
import html/dom
import io/term

type
  BoxType* = enum
    BOX_INLINE, BOX_BLOCK, BOX_INLINE_BLOCK

  Rectangle* = object
    x1*: int
    x2*: int
    y1*: int
    y2*: int

  CSSBox* = ref object of RootObj
    t*: BoxType
    x*: int
    y*: int
    width*: int
    children*: seq[CSSBox]
    icontext*: InlineContext
    bcontext*: BlockContext
    cssvalues*: CSSSpecifiedValues
    node*: Node

  CSSInlineAtom* = ref object of CSSBox
    dimensions*: Rectangle

  CSSInlineRowPart* = ref object of CSSInlineAtom
    str*: string
    rwidth*: int

  CSSInlineRow* = ref object
    content*: seq[CSSInlineAtom]
    rely*: int
    width*: int

  InlineContext* = ref object
    fromx*: int
    fromy*: int
    xhigh*: int
    whitespace*: bool
    ws_initial*: bool
    rows*: seq[CSSRowBox]
    thisrow*: seq[CSSRowBox]

    dimensions*: Rectangle
    content*: seq[CSSInlineRow]
    rcontent*: CSSInlineRow
    color*: CSSColor
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    nodes*: seq[Node]

    maxwidth*: int

  BlockContext* = ref object
    fromy*: int
    dimensions*: Rectangle
    margin_done*: int
    margin_todo*: int
    width*: int
    height*: Option[int]
    content*: seq[CSSBox]

  LayoutState* = object
    nodes*: seq[Node]
    term*: TermAttributes
    fromy*: int
    fromx*: int

  CSSRowBox* = object
    x*: int
    y*: int
    width*: int
    height*: int
    color*: CSSColor
    fontstyle*: CSSFontStyle
    fontweight*: int
    textdecoration*: CSSTextDecoration
    str*: string
    nodes*: seq[Node]
    bottom*: int

  CSSInlineBox* = ref object of CSSBox
  CSSBlockBox* = ref object of CSSBox
  CSSInlineBlockBox* = ref object of CSSBlockBox

func width*(rectangle: Rectangle): int =
  return rectangle.x2 - rectangle.x1

func height*(rectangle: Rectangle): int =
  return rectangle.y2 - rectangle.y1
