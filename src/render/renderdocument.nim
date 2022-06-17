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
import types/color
import utils/twtstr

func formatFromWord(computed: ComputedFormat): Format =
  result.fgcolor = computed.color.cellColor()
  if computed.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if computed.fontweight > 500:
    result.bold = true
  case computed.textdecoration
  of TEXT_DECORATION_UNDERLINE:
    result.underline = true
  of TEXT_DECORATION_OVERLINE:
    result.overline = true
  of TEXT_DECORATION_LINE_THROUGH:
    result.strike = true
  of TEXT_DECORATION_BLINK:
    result.blink = true
  else: discard

proc setFormats(line: var FlexibleLine, ox, newwidth, oldwidth: int,
                newformat: Format, oformats: seq[FormatCell], computed: ComputedFormat = nil) {.inline.} =
  let obg = newformat.bgcolor
  var newformat = newformat
  for format in oformats:
    assert format.pos < ox + oldwidth
    if format.format.bgcolor != newformat.bgcolor:
      newformat.bgcolor = format.format.bgcolor

      if format.pos < ox:
        line.addFormat(ox, newformat, computed)
      else:
        line.addFormat(format.pos, newformat, computed)

  if ox + oldwidth < ox + newwidth:
    newformat.bgcolor = obg

    #TODO this is probably a workaround for a bug...
    if line.formats.len > 0 and line.formats[^1].pos == ox + oldwidth:
      line.formats[^1].format.bgcolor = obg
    else:
      line.addFormat(ox + oldwidth, newformat, computed)

proc setText(lines: var FlexibleGrid, linestr: string, format: ComputedFormat, x, y: int) {.inline.} =
  var r: Rune
  var x = x
  var y = y
  var i = 0

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
  let oldstrwidth = ostr.width()
  if nx < x:
    let spacelength = x - nx
    var spaceformat = newFormat()
    let str = ' '.repeat(spacelength)
    lines[y].setFormats(nx, spacelength, oldstrwidth, spaceformat, oformats)

    lines[y].str &= str
    i += spacelength
    nx = x

  var wordformat = format.formatFromWord()
  let newstrwidth = linestr.width()
  lines[y].setFormats(nx, newstrwidth, oldstrwidth, wordformat, oformats, format)
  nx += newstrwidth

  lines[y].str &= linestr

  i = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
    lines[y].add(oline)

proc setRowWord(lines: var FlexibleGrid, word: InlineWord, x, y: int, term: TermAttributes) =
  var r: Rune

  var y = (y + word.offset.y) div term.ppl
  if y < 0: y = 0

  var x = (x + word.offset.x) div term.ppc
  var i = 0
  while x < 0 and i < word.str.len:
    fastRuneAt(word.str, i, r)
    x += r.width()
  let linestr = word.str.substr(i)

  lines.setText(linestr, word.format, x, y)

proc setSpacing(lines: var FlexibleGrid, spacing: InlineSpacing, x, y: int, term: TermAttributes) =
  var y = (y + spacing.offset.y) div term.ppl
  if y < 0: y = 0

  var x = (x + spacing.offset.x) div term.ppc
  let width = spacing.width div term.ppc

  var i = 0
  if x < 0:
    i -= x
    x = 0
  let linestr = ' '.repeat(width - i)

  lines.setText(linestr, spacing.format, x, y)

proc paintBackground(lines: var FlexibleGrid, color: CSSColor, startx, starty, endx, endy: int, term: TermAttributes) =
  let color = color.cellColor()

  var starty = starty div term.ppl
  if starty < 0: starty = 0

  var endy = endy div term.ppl
  if endy < 0: endy = 0

  if starty > endy:
    let swap = endy
    endy = starty
    starty = swap

  var startx = startx div term.ppc
  if starty < 0: starty = 0

  var endx = endx div term.ppc
  if endy < 0: endy = 0

  if startx > endx:
    let swap = endx
    endx = startx
    startx = swap

  while lines.len <= endy:
    lines.addLine()

  var y = starty
  while y < endy:
    # Make sure line.width() >= endx
    let linewidth = lines[y].width()
    if linewidth < endx:
      lines[y].addFormat(linewidth, newFormat())
      lines[y].str &= ' '.repeat(endx - linewidth)

    # Process formatting around startx
    if lines[y].formats.len == 0:
      # No formats
      lines[y].addFormat(startx, newFormat())
    else:
      let fi = lines[y].findFormatN(startx) - 1
      if lines[y].formats[fi].pos == startx:
        # Last format equals startx => next comes after, nothing to be done
        discard
      else:
        # Last format lower than startx => separate format from startx
        let copy = lines[y].formats[fi]
        lines[y].formats[fi].pos = startx
        lines[y].formats.insert(copy, fi)

    # Process formatting around endx
    assert lines[y].formats.len > 0
    let fi = lines[y].findFormatN(endx) - 1
    if fi == lines[y].formats.len - 1:
      # Last format => nothing to be done
      discard
    else:
      # Format ends before endx => separate format from endx
      let copy = lines[y].formats[fi]
      lines[y].formats[fi].pos = endx
      lines[y].formats.insert(copy, fi + 1)

    # Paint format backgrounds between startx and endx
    for fi in 0..lines[y].formats.high:
      if lines[y].formats[fi].pos > endx:
        break
      if lines[y].formats[fi].pos >= startx:
        lines[y].formats[fi].format.bgcolor = color

    inc y

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockContext, x, y: int, term: TermAttributes)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int, term: TermAttributes) =
  let x = x + ctx.offset.x
  let y = y + ctx.offset.y
  for row in ctx.rows:
    let x = x + row.offset.x
    let y = y + row.offset.y

    let r = y div term.ppl
    while grid.len <= r:
      grid.addLine()

    for atom in row.atoms:
      if atom of InlineBlock:
        let iblock = InlineBlock(atom)
        grid.renderBlockContext(iblock.bctx, x + iblock.offset.x, y + iblock.offset.y, term)
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
    x += ctx.offset.x
    y += ctx.offset.y

    if ctx.specified{"background-color"}.rgba.a != 0: #TODO color blending
      grid.paintBackground(ctx.specified{"background-color"}, x, y, x + ctx.width, y + ctx.height, term)

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
