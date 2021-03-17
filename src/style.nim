import streams
import unicode

import enums
import cssparser
import twtio

type
  CSS2Properties* = ref object
    rawtext*: string
    fmttext*: seq[string]
    x*: int
    y*: int
    ex*: int
    ey*: int
    width*: int
    height*: int
    hidden*: bool
    before*: CSS2Properties
    after*: CSS2Properties
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int
    centered*: bool
    display*: DisplayType
    bold*: bool
    italic*: bool
    underscore*: bool
    islink*: bool
    selected*: bool
    indent*: int

  CSSRect* = object
    x1*: int
    y1*: int
    x2*: int
    y2*: int

  CSSBox* = ref object
    display*: DisplayType
    x*: int
    y*: int
    innerEdge*: CSSRect
    paddingEdge*: CSSRect
    borderEdge*: CSSRect
    marginEdge*: CSSRect
    parent*: CSSBox
    color*: CSSColor
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int

proc applyProperties*(box: var CSSBox, props: string) =
  var decls = parseCSSListOfDeclarations(newStringStream(props))

  for item in decls:
    if item of CSSDeclaration:
      let d = CSSDeclaration(item)
      case $d.name
      of "color":
        if d.value.len > 0 and d.value[0] of CSSToken and
            CSSToken(d.value[0]).tokenType == CSS_HASH_TOKEN:
          box.color = toColor(CSSToken(d.value[0]).value)
      of "margin-top":
        if d.value.len > 0 and d.value[0] of CSSToken:
          if CSSToken(d.value[0]).tokenType == CSS_PERCENTAGE_TOKEN:
            discard
            #box.margintop = CSSToken(d.value[0]).nvalue #TODO represent percentages
      else:
        printc(d)
