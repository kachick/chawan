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

proc setRowWord(lines: var FlexibleGrid, word: InlineWord, x, y: int, term: TermAttributes) =
  var r: Rune

  let y = y div term.ppl
  var x = x div term.ppc
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

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int, term: TermAttributes)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int, term: TermAttributes) =
  for row in ctx.rows:
    let x = x + row.relx
    let y = y + row.rely + row.height
    for atom in row.atoms:
      # This aligns atoms with the baseline.
      # (other alignment types in progress)
      let y = y - atom.height
      if atom of BlockContext:
        let ctx = BlockContext(atom)
        grid.renderBlockContext(ctx, x + ctx.relx, y + ctx.rely, term)
      elif atom of InlineWord:
        let word = InlineWord(atom)
        grid.setRowWord(word, x + word.relx, y, term)

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int, term: TermAttributes) =
  var x = x
  var y = y
  if ctx.inline != nil:
    assert ctx.nested.len == 0
    grid.renderInlineContext(ctx.inline, x + ctx.inline.relx, y, term)
  else:
    for ctx in ctx.nested:
      grid.renderBlockContext(ctx, x + ctx.relx, y + ctx.rely, term)

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
proc renderDocument*(document: Document, attrs: TermAttributes, userstyle: CSSStylesheet, layout: var Viewport): FlexibleGrid =
  document.applyStylesheets(uastyle, userstyle)
  layout.renderLayout(document)
  result.setLen(0)
  result.renderBlockContext(layout.root.bctx, 0, 0, layout.term)
  if result.len == 0:
    result.addLine()
