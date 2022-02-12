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

func formatFromWord(computed: ComputedFormat): Format =
  result.fgcolor = computed.color.cellColor()
  if computed.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if computed.fontweight > 500:
    result.bold = true
  if computed.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline = true
  if computed.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline = true
  if computed.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike = true
  if computed.textdecoration == TEXT_DECORATION_BLINK:
    result.blink = true

proc setRowWord(lines: var FlexibleGrid, word: InlineWord, x, y: int, term: TermAttributes) =
  var r: Rune

  var y = (y + word.rely) div term.ppl
  if y < 0: y = 0

  var x = (x + word.relx) div term.ppc
  var i = 0
  while x < 0 and i < word.str.len:
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

  var nx = cx
  if nx < x:
    lines.addFormat(y, i, newFormat())
    lines[y].str &= ' '.repeat(x - nx)
    i += x - nx
    nx = x

  lines.addFormat(y, i, word.format.formatFromWord(), word.format, word.format.node)

  lines[y].str &= linestr
  nx += linestr.width()

  i = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
    lines[y].add(oline)

proc setSpacing(lines: var FlexibleGrid, spacing: InlineSpacing, x, y: int, term: TermAttributes) =
  var r: Rune

  var y = (y + spacing.rely) div term.ppl
  if y < 0: y = 0

  var x = (x + spacing.relx) div term.ppc
  let width = spacing.width div term.ppc

  var i = 0
  if x < 0:
    i -= x
    x = 0

  let linestr = ' '.repeat(width - i)
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

  var nx = cx
  if nx < x:
    lines.addFormat(y, i, newFormat())
    lines[y].str &= ' '.repeat(x - nx)
    nx = x

  lines[y].str &= linestr
  nx += linestr.len
  if spacing.format != nil:
    lines.addFormat(y, i, spacing.format.formatFromWord(), spacing.format, spacing.format.node)

  i = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
    lines[y].add(oline)

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int, term: TermAttributes)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int, term: TermAttributes) =
  let x = x + ctx.relx
  let y = y + ctx.rely
  for row in ctx.rows:
    let x = x + row.relx
    let y = y + row.rely

    let r = y div term.ppl
    while grid.len <= r:
      grid.addLine()

    for atom in row.atoms:
      if atom of BlockContext:
        let ctx = BlockContext(atom)
        grid.renderBlockContext(ctx, x, y, term)
      elif atom of InlineWord:
        let word = InlineWord(atom)
        grid.setRowWord(word, x, y, term)
      elif atom of InlineSpacing:
        let spacing = InlineSpacing(atom)
        grid.setSpacing(spacing, x, y, term)

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int, term: TermAttributes) =
  var stack = newSeqOfCap[(BlockContext, int, int)](100)
  stack.add((ctx, x, y))

  while stack.len > 0:
    var (ctx, x, y) = stack.pop()
    x += ctx.relx
    y += ctx.rely
    if ctx.inline != nil:
      assert ctx.nested.len == 0
      grid.renderInlineContext(ctx.inline, x, y, term)
    else:
      for i in countdown(ctx.nested.high, 0):
        stack.add((ctx.nested[i], x, y))

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
proc renderDocument*(document: Document, term: TermAttributes, userstyle: CSSStylesheet, layout: var Viewport): FlexibleGrid =
  document.applyStylesheets(uastyle, userstyle)
  layout.renderLayout(document)
  result.setLen(0)
  result.renderBlockContext(layout.root.bctx, 0, 0, term)
  if result.len == 0:
    result.addLine()
