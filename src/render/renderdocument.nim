import strutils
import unicode

import buffer/cell
import css/cascade
import css/sheet
import css/stylednode
import css/values
import html/dom
import io/window
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

proc setText(lines: var FlexibleGrid, linestr: string, cformat: ComputedFormat, x, y: int) {.inline.} =
  var i = 0
  var r: Rune
  # make sure we have line y
  while lines.len <= y:
    lines.addLine()

  var cx = 0 # first x of new string (before padding)
  while cx < x and i < lines[y].str.len:
    fastRuneAt(lines[y].str, i, r)
    cx += r.width()

  let ostr = lines[y].str.substr(i)
  lines[y].str.setLen(i)
  var linestrwidth = 0
  let padwidth = x - cx
  if padwidth > 0:
    lines[y].str &= ' '.repeat(padwidth)
    linestrwidth += padwidth

  lines[y].str &= linestr
  linestrwidth += linestr.width()

  i = 0
  var nx = x # last x of new string
  while nx < x + linestrwidth and i < ostr.len:
    fastRuneAt(ostr, i, r)
    nx += r.width()

  if i < ostr.len:
    lines[y].str &= ostr.substr(i)

  # Skip unchanged formats before the new string
  var fi = lines[y].findFormatN(cx) - 1

  if padwidth > 0:
    # Replace formats for padding
    var padformat = newFormat()
    if fi == -1:
      # No formats
      inc fi # insert after first format (meaning fi = 0)
      lines[y].insertFormat(cx, fi, padformat)
    else:
      # First format's pos may be == cx here.
      if lines[y].formats[fi].pos == cx:
        padformat.bgcolor = lines[y].formats[fi].format.bgcolor
        lines[y].formats.delete(fi)
        lines[y].insertFormat(cx, fi, padformat)
      else:
        # First format < cx => split it up
        assert lines[y].formats[fi].pos < cx
        padformat.bgcolor = lines[y].formats[fi].format.bgcolor
        inc fi # insert after first format
        lines[y].insertFormat(cx, fi, padformat)
    inc fi # skip last format
    while fi < lines[y].formats.len and lines[y].formats[fi].pos < x:
      # Other formats must be > cx => replace them
      padformat.bgcolor = lines[y].formats[fi].format.bgcolor
      let px = lines[y].formats[fi].pos
      lines[y].formats.delete(fi)
      lines[y].insertFormat(px, fi, padformat)
      inc fi
    dec fi # go back to previous format, so that pos <= x
    assert lines[y].formats[fi].pos <= x

  # Now for the text's formats:
  var format = cformat.formatFromWord()
  if fi == -1:
    # No formats => just insert a new format at 0
    inc fi
    lines[y].insertFormat(x, fi, format, cformat)
  else:
    # First format's pos may be == x here.
    if lines[y].formats[fi].pos == x:
      # Replace.
      format.bgcolor = lines[y].formats[fi].format.bgcolor
      lines[y].formats.delete(fi)
      lines[y].insertFormat(x, fi, format, cformat)
    else:
      # First format's pos < x => split it up.
      assert lines[y].formats[fi].pos < x
      format.bgcolor = lines[y].formats[fi].format.bgcolor
      inc fi # insert after first format
      lines[y].insertFormat(x, fi, format, cformat)
  inc fi # skip last format

  while fi < lines[y].formats.len and lines[y].formats[fi].pos < nx:
    # Other formats must be > x => replace them
    format.bgcolor = lines[y].formats[fi].format.bgcolor
    let px = lines[y].formats[fi].pos
    lines[y].formats.delete(fi)
    lines[y].insertFormat(px, fi, format, cformat)
    inc fi

  dec fi # go back to previous format, so that pos <= nx
  assert lines[y].formats[fi].pos <= nx
  # That's it!

proc setRowWord(lines: var FlexibleGrid, word: InlineWord, x, y: int, window: WindowAttributes) =
  var r: Rune

  var y = (y + word.offset.y) div window.ppl # y cell
  if y < 0: return # y is outside the canvas, no need to draw

  var x = (x + word.offset.x) div window.ppc # x cell
  var i = 0
  while x < 0 and i < word.str.len:
    fastRuneAt(word.str, i, r)
    x += r.width()
  if x < 0: return # highest x is outside the canvas, no need to draw
  let linestr = word.str.substr(i)

  lines.setText(linestr, word.format, x, y)

proc setSpacing(lines: var FlexibleGrid, spacing: InlineSpacing, x, y: int, window: WindowAttributes) =
  var y = (y + spacing.offset.y) div window.ppl # y cell
  if y < 0: return # y is outside the canvas, no need to draw

  var x = (x + spacing.offset.x) div window.ppc # x cell
  let width = spacing.width div window.ppc # cell width

  if x + width < 0: return # highest x is outside the canvas, no need to draw
  var i = 0
  if x < 0:
    i -= x
    x = 0
  let linestr = ' '.repeat(width - i)

  lines.setText(linestr, spacing.format, x, y)

proc paintBackground(lines: var FlexibleGrid, color: RGBAColor, startx, starty, endx, endy: int, window: WindowAttributes) =
  let color = color.cellColor()

  var starty = starty div window.ppl
  var endy = endy div window.ppl

  if starty > endy:
    swap(starty, endy)

  if endy <= 0: return # highest y is outside canvas, no need to paint
  if starty < 0: starty = 0
  if starty == endy: return # height is 0, no need to paint

  var startx = startx div window.ppc

  var endx = endx div window.ppc
  if endy < 0: endy = 0

  if startx > endx:
    swap(startx, endx)

  if endx <= 0: return # highest x is outside the canvas, no need to paint
  if startx < 0: startx = 0
  if startx == endx: return # width is 0, no need to paint

  # make sure we have line y
  while lines.len <= endy:
    lines.addLine()

  for y in starty..<endy:
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
      if fi == -1:
        # No format <= startx
        lines[y].insertFormat(startx, 0, newFormat())
      elif lines[y].formats[fi].pos == startx:
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
    if fi == -1:
      # Last format > endx -> nothing to be done
      discard
    else:
      if lines[y].formats[fi].pos != endx:
        let copy = lines[y].formats[fi]
        if linewidth != endx:
          lines[y].formats[fi].pos = endx
          lines[y].formats.insert(copy, fi)
        else:
          lines[y].formats.delete(fi)
          lines[y].formats.insert(copy, fi)

    # Paint format backgrounds between startx and endx
    for fi in 0..lines[y].formats.high:
      if lines[y].formats[fi].pos >= endx:
        break
      if lines[y].formats[fi].pos >= startx:
        lines[y].formats[fi].format.bgcolor = color

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockBox, x, y: int, window: WindowAttributes)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int, window: WindowAttributes) =
  let x = x + ctx.offset.x
  let y = y + ctx.offset.y
  for line in ctx.lines:
    let x = x + line.offset.x
    let y = y + line.offset.y

    let r = y div window.ppl
    while grid.len <= r:
      grid.addLine()

    for atom in line.atoms:
      if atom of InlineBlockBox:
        let iblock = InlineBlockBox(atom)
        grid.renderBlockContext(iblock.innerbox, x + iblock.offset.x, y + iblock.offset.y, window)
      elif atom of InlineWord:
        let word = InlineWord(atom)
        grid.setRowWord(word, x, y, window)
      elif atom of InlineSpacing:
        let spacing = InlineSpacing(atom)
        grid.setSpacing(spacing, x, y, window)

proc renderBlockContext(grid: var FlexibleGrid, ctx: BlockBox, x, y: int, window: WindowAttributes) =
  var stack = newSeqOfCap[(BlockBox, int, int)](100)
  stack.add((ctx, x, y))

  while stack.len > 0:
    var (ctx, x, y) = stack.pop()
    x += ctx.offset.x
    y += ctx.offset.y

    if ctx.computed{"background-color"}.a != 0: #TODO color blending
      grid.paintBackground(ctx.computed{"background-color"}, x, y, x + ctx.width, y + ctx.height, window)

    if ctx of ListItemBox:
      let ctx = ListItemBox(ctx)
      if ctx.marker != nil:
        grid.renderInlineContext(ctx.marker, x - ctx.marker.maxwidth, y, window)

    if ctx.inline != nil:
      assert ctx.nested.len == 0
      grid.renderInlineContext(ctx.inline, x, y, window)
    else:
      for i in countdown(ctx.nested.high, 0):
        stack.add((ctx.nested[i], x, y))

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
const quirk = css & staticRead"res/quirk.css"
let quirkstyle = quirk.parseStylesheet()
proc renderDocument*(document: Document, window: WindowAttributes, userstyle: CSSStylesheet, layout: var Viewport, previousStyled: StyledNode): (FlexibleGrid, StyledNode) =
  var uastyle = uastyle
  if document.mode == QUIRKS:
    uastyle = quirkstyle
  let styledNode = document.applyStylesheets(uastyle, userstyle, previousStyled)
  result[1] = styledNode
  layout.renderLayout(document, styledNode)
  result[0].setLen(0)
  for root in layout.root:
    result[0].renderBlockContext(root, 0, 0, window)
  if result[0].len == 0:
    result[0].addLine()
