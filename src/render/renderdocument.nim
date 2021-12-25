import strutils
import unicode

import css/cascade
import css/sheet
import css/values
import html/dom
import io/cell
import io/term
import layout/box
import layout/engine
import utils/twtstr

func formatFromLine(line: CSSRowBox): Formatting =
  result.fgcolor = line.color.cellColor()
  if line.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if line.fontweight > 500:
    result.bold = true
  if line.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline = true
  if line.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline = true
  if line.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike = true

proc setRowBox(lines: var FlexibleGrid, line: CSSRowBox) =
  var r: Rune

  var x = line.x
  var i = 0
  while x < 0:
    fastRuneAt(line.str, i, r)
    x += r.width()
  let linestr = line.str.substr(i)
  i = 0

  let y = line.y

  while lines.len <= y:
    lines.addLine()

  var cx = 0
  while cx < x and i < lines[y].str.len:
    fastRuneAt(lines[y].str, i, r)
    cx += r.width()

  let ostr = lines[y].str.substr(i)
  let oformats = lines[y].formats.subformats(i)
  lines[y].setLen(i)

  lines.addFormat(y, i, line.formatFromLine(), line.nodes)

  var nx = cx
  if nx < x:
    lines[y].str &= ' '.repeat(x - nx)
    nx = x

  lines[y].str &= linestr
  nx += linestr.width()

  i = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
    lines[y].add(oline)

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
proc renderDocument*(document: Document, attrs: TermAttributes, userstyle: CSSStylesheet): FlexibleGrid =
  document.applyStylesheets(uastyle, userstyle)
  let rootbox = document.alignBoxes(attrs)
  var stack: seq[CSSBox]
  stack.add(rootbox)
  while stack.len > 0:
    let box = stack.pop()
    if box of CSSBlockBox:
      for line in box.icontext.rows:
        result.setRowBox(line)

    var i = box.children.len - 1
    while i >= 0:
      stack.add(box.children[i])
      dec i
