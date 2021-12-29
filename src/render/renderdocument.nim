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

func formatFromLine(line: RowBox): Formatting =
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

proc setRowBox(lines: var FlexibleGrid, line: RowBox) =
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

func formatFromWord(word: InlineWord): Formatting =
  result.fgcolor = word.color.cellColor()
  if word.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if word.fontweight > 500:
    result.bold = true
  if word.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline = true
  if word.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline = true
  if word.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike = true

proc setRowWord(lines: var FlexibleGrid, word: InlineWord, x, y: int) =
  var r: Rune

  var x = x
  var i = 0
  while x < 0:
    fastRuneAt(word.str, i, r)
    x += r.width()
  let linestr = word.str.substr(i)
  i = 0

  while lines.len <= y:
    lines.addLine()

  var cx = 0
  while cx < x and i < lines[y].str.len:
    fastRuneAt(lines[y].str, i, r)
    cx += r.width()

  let ostr = lines[y].str.substr(i)
  let oformats = lines[y].formats.subformats(i)
  lines[y].setLen(i)

  lines.addFormat(y, i, word.formatFromWord(), word.nodes)

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

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int) =
  for row in ctx.rows:
    let x = x + row.relx
    let y = y + row.rely
    for atom in row.atoms:
      if atom of BlockContext:
        let ctx = BlockContext(atom)
        grid.renderBlockContext(ctx, x + ctx.relx, y)
      elif atom of InlineWord:
        let word = InlineWord(atom)
        grid.setRowWord(word, x + word.relx, y)

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int) =
  var x = x
  var y = y
  if ctx.nested.len == 0:
    for ictx in ctx.inlines:
      grid.renderInlineContext(ictx, x + ictx.relx, y)
  else:
    for ctx in ctx.nested:
      grid.renderBlockContext(ctx, x + ctx.relx, y)

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
proc renderDocument*(document: Document, attrs: TermAttributes, userstyle: CSSStylesheet): FlexibleGrid =
  document.applyStylesheets(uastyle, userstyle)
  let rootbox = document.alignBoxes(attrs)
  var stack: seq[BlockContext]
  stack.add(rootbox.bctx)
  var x = 0
  var y = 0
  while stack.len > 0:
    let ctx = stack.pop()
    if ctx.nested.len == 0:
      for ictx in ctx.inlines:
        result.renderInlineContext(ictx, x, y)
        y += ictx.height
    else:
      for i in countdown(ctx.nested.high, 0):
        stack.add(ctx.nested[i])
  if result.len == 0:
    result.addLine()
