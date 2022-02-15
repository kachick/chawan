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
  if computed.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline = true
  if computed.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline = true
  if computed.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike = true
  if computed.textdecoration == TEXT_DECORATION_BLINK:
    result.blink = true

#TODO format.pos signifying byte instead of actual position was a huge
# mistake...
proc setFormats(lines: var FlexibleGrid, y, ox, i: int, nx, cx: var int,
                newformat: Format, oformats: seq[FormatCell],
                str, ostr: string, computed: ComputedFormat = nil) {.inline.} =
  let obg = newformat.bgcolor
  let newstrwidth = str.width()
  var newformat = newformat
  var osi = 0
  var nsi = 0
  for format in oformats:
    assert i + ostr.len > format.pos
    # move cx to format.pos
    while i + osi < format.pos:
      var r: Rune
      fastRuneAt(ostr, osi, r)
      cx += r.width()

    if cx > newstrwidth + ox:
      # last oformat starts after newformat ends
      nx = ox + newstrwidth
      eprint "ret"
      return

    if osi >= ostr.len:
      # I don't even know anymore
      break

    # move nx to cx
    while nsi < str.len and nx < cx:
      var r: Rune
      fastRuneAt(str, nsi, r)
      nx += r.width()

    if format.format.bgcolor != newformat.bgcolor:
      newformat.bgcolor = format.format.bgcolor
      eprint "odd", i + nsi, newformat.bgcolor, ox, nx
      if computed == nil:
        lines.addFormat(y, i + nsi, newformat)
      else:
        # have to pass nil to force new format... TODO?
        lines.addFormat(y, i + nsi, newformat, nil, computed.node)

  eprint "end", ostr, "->", str, obg, nsi
  # last oformat starts before newformat ends

  # move cx to last old char
  while osi < ostr.len:
    var r: Rune
    fastRuneAt(ostr, osi, r)
    cx += r.width()

  # move nx to cx
  while nsi < str.len and nx < cx:
    var r: Rune
    fastRuneAt(str, nsi, r)
    nx += r.width()

  if nsi < str.len:
    newformat.bgcolor = obg
    eprint "add", str, ":", i + nsi
    if computed == nil:
      lines.addFormat(y, i + nsi, newformat)
    else:
      lines.addFormat(y, i + nsi, newformat, computed, computed.node)
    nx = ox + newstrwidth

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
  let ox = cx
  if nx < x:
    let spacelength = x - nx
    var spaceformat = newFormat()
    let str = ' '.repeat(spacelength)
    lines.setFormats(y, ox, i, nx, cx, spaceformat, oformats, str, ostr)

    lines[y].str &= str
    i += spacelength
    assert nx == x

  var wordformat = format.formatFromWord()
  lines.setFormats(y, x, i, nx, cx, wordformat, oformats, linestr, ostr, format)

  lines[y].str &= linestr

  i = 0
  cx = ox
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
    lines[y].add(oline)

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

  lines.setText(linestr, word.format, x, y)

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
      lines.addFormat(y, lines[y].str.len, newFormat())
      lines[y].str &= ' '.repeat(endx - linewidth)

    # Find byte (i) of startx
    var i = 0
    var x = 0
    while x < startx:
      var r: Rune
      fastRuneAt(lines[y].str, i, r)
      x += r.width()

    # Process formatting around startx
    if lines[y].formats.len == 0:
      # No formats
      lines.addFormat(y, startx, newFormat())
    else:
      let fi = lines[y].findFormatN(i) - 1
      if lines[y].formats[fi].pos == i:
        # Previous format equals i => next comes after, nothing to be done
        discard
      else:
        # Previous format lower than i => separate format from startx
        let copy = lines[y].formats[fi]
        lines[y].formats[fi].pos = i
        lines[y].formats.insert(copy, fi)

    # Find byte (ei) of endx
    var ei = i
    while x < endx:
      var r: Rune
      fastRuneAt(lines[y].str, ei, r)
      x += r.width()

    # Process formatting around endx
    block:
      assert lines[y].formats.len > 0
      let fi = lines[y].findFormatN(ei) - 1
      if fi == lines[y].formats.len - 1:
        # Last format => nothing to be done
        discard
      else:
        # Format ends before endx => separate format from endx
        let copy = lines[y].formats[fi]
        lines[y].formats[fi].pos = ei
        lines[y].formats.insert(copy, fi + 1)

    # Paint format backgrounds between startx (byte i) and endx (byte ei)
    var fi = 0
    while fi < lines[y].formats.len:
      if lines[y].formats[fi].pos > ei:
        break
      if lines[y].formats[fi].pos >= i:
        lines[y].formats[fi].format.bgcolor = color
      inc fi

    inc y

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
      if atom of InlineBlock:
        let iblock = InlineBlock(atom)
        grid.renderBlockContext(iblock.bctx, x + iblock.relx, y + iblock.rely, term)
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

    if ctx.specified{"background-color"}.rgba.a != 0: #TODO color mixing
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
