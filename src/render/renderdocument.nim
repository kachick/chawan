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
  result.fgcolor = cellColor(computed.color)
  if computed.bgcolor.a != 0:
    result.bgcolor = cellColor(computed.bgcolor)
  if computed.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if computed.fontweight > 500:
    result.bold = true
  if TEXT_DECORATION_UNDERLINE in computed.textdecoration:
    result.underline = true
  if TEXT_DECORATION_OVERLINE in computed.textdecoration:
    result.overline = true
  if TEXT_DECORATION_LINE_THROUGH in computed.textdecoration:
    result.strike = true
  if TEXT_DECORATION_BLINK in computed.textdecoration:
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
    let pi = i
    fastRuneAt(lines[y].str, i, r)
    let w = r.twidth(cx)
    # we must ensure x is max(cx, x), otherwise our assumption of cx <= x
    # breaks down
    if cx + w > x:
      i = pi
      break
    cx += w

  let ostr = lines[y].str.substr(i)
  lines[y].str.setLen(i)
  let padwidth = x - cx
  if padwidth > 0:
    lines[y].str &= ' '.repeat(padwidth)

  lines[y].str &= linestr
  let linestrwidth = linestr.twidth(x) - x

  i = 0
  var nx = x # last x of new string
  while nx < x + linestrwidth and i < ostr.len:
    fastRuneAt(ostr, i, r)
    nx += r.twidth(nx)

  if i < ostr.len:
    lines[y].str &= ostr.substr(i)

  # Negative x values make no sense from here on, as text with negative x
  # coordinates can not be formatted.
  let x = max(0, x)
  if cx < 0:
    cx = 0
  if nx < 0:
    nx = 0

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
        let node = lines[y].formats[fi].node
        lines[y].formats.delete(fi)
        lines[y].insertFormat(cx, fi, padformat, node)
      else:
        # First format < cx => split it up
        assert lines[y].formats[fi].pos < cx
        padformat.bgcolor = lines[y].formats[fi].format.bgcolor
        let node = lines[y].formats[fi].node
        inc fi # insert after first format
        lines[y].insertFormat(cx, fi, padformat, node)
    inc fi # skip last format
    while fi < lines[y].formats.len and lines[y].formats[fi].pos < x:
      # Other formats must be > cx => replace them
      padformat.bgcolor = lines[y].formats[fi].format.bgcolor
      let node = lines[y].formats[fi].node
      let px = lines[y].formats[fi].pos
      lines[y].formats.delete(fi)
      lines[y].insertFormat(px, fi, padformat, node)
      inc fi
    dec fi # go back to previous format, so that pos <= x
    assert lines[y].formats[fi].pos <= x

  # Now for the text's formats:
  var format = cformat.formatFromWord()
  var lformat: Format
  var lnode: StyledNode
  if fi == -1:
    # No formats => just insert a new format at 0
    inc fi
    lines[y].insertFormat(x, fi, format, cformat.node)
    lformat = newFormat()
  else:
    # First format's pos may be == x here.
    lformat = lines[y].formats[fi].format # save for later use
    lnode = lines[y].formats[fi].node
    if lines[y].formats[fi].pos == x:
      # Replace.
      # We must check if the old string's last x position is greater than
      # the new string's first x position. If not, we cannot inherit
      # its bgcolor (which is supposed to end before the new string started.)
      if nx > cx:
        format.bgcolor = lines[y].formats[fi].format.bgcolor.blend(format.bgcolor)
      lines[y].formats.delete(fi)
      lines[y].insertFormat(x, fi, format, cformat.node)
    else:
      # First format's pos < x => split it up.
      assert lines[y].formats[fi].pos < x
      if nx > cx: # see above
        format.bgcolor = format.bgcolor.blend(lines[y].formats[fi].format.bgcolor)
      inc fi # insert after first format
      lines[y].insertFormat(x, fi, format, cformat.node)
  inc fi # skip last format

  while fi < lines[y].formats.len and lines[y].formats[fi].pos < nx:
    # Other formats must be > x => replace them
    format.bgcolor = lines[y].formats[fi].format.bgcolor
    let px = lines[y].formats[fi].pos
    lformat = lines[y].formats[fi].format # save for later use
    lnode = lines[y].formats[fi].node
    lines[y].formats.delete(fi)
    lines[y].insertFormat(px, fi, format, cformat.node)
    inc fi

  if i < ostr.len and (fi >= lines[y].formats.len or lines[y].formats[fi].pos > nx):
    # nx < ostr.width, but we have removed all formatting in the range of our
    # string, and no formatting comes directly after it. So we insert the
    # continuation of the last format we replaced after our string.
    # (Default format when we haven't replaced anything.)
    lines[y].insertFormat(nx, fi, lformat, lnode)

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
    x += r.twidth(x)
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

proc paintBackground(lines: var FlexibleGrid, color: RGBAColor, startx, starty, endx, endy: int, node: StyledNode, window: WindowAttributes) =
  let color = cellColor(color)

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
        lines[y].formats[fi].node = node

func calculateErrorY(ctx: InlineContext, window: WindowAttributes): int =
  if ctx.lines.len <= 1: return 0
  var error = 0
  for i in 0 ..< ctx.lines.len:
    if i < ctx.lines.high:
      let dy = ctx.lines[i + 1].offset.y - ctx.lines[i].offset.y
      error += dy - (dy div window.ppl) * window.ppl
  return error div (ctx.lines.len - 1)

proc renderBlockBox(grid: var FlexibleGrid, box: BlockBox, x, y: int, window: WindowAttributes, posx = 0, posy = 0)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext, x, y: int, window: WindowAttributes, posx = 0, posy = 0) =
  let x = x + ctx.offset.x
  let y = y + ctx.offset.y
  let erry = ctx.calculateErrorY(window)
  var i = 0
  for line in ctx.lines:
    let x = x + line.offset.x
    let y0 = y + line.offset.y
    let y = y0 - erry * i

    let r = y div window.ppl
    while grid.len <= r:
      grid.addLine()

    for atom in line.atoms:
      if atom of InlineBlockBox:
        let iblock = InlineBlockBox(atom)
        let x = x + iblock.offset.x
        let y = y + iblock.offset.y
        grid.renderBlockBox(iblock.innerbox, x, y, window, posx, posy)
      elif atom of InlineWord:
        let word = InlineWord(atom)
        grid.setRowWord(word, x, y, window)
      elif atom of InlineSpacing:
        let spacing = InlineSpacing(atom)
        grid.setSpacing(spacing, x, y, window)
    inc i

proc renderBlockBox(grid: var FlexibleGrid, box: BlockBox, x, y: int, window: WindowAttributes, posx = 0, posy = 0) =
  var stack = newSeqOfCap[(BlockBox, int, int, int, int)](100)
  stack.add((box, x, y, posx, posy))

  while stack.len > 0:
    var (box, x, y, posx, posy) = stack.pop()
    if box.x_positioned:
      x = posx
    if box.y_positioned:
      y = posy
    x += box.offset.x
    y += box.offset.y
    if box.positioned:
      posx = x
      posy = y

    if box.computed{"visibility"} == VISIBILITY_VISIBLE:
      grid.paintBackground(box.computed{"background-color"}, x, y,
        x + box.width, y + box.height, box.node, window)
      if box.computed{"background-image"}.t == CONTENT_IMAGE and box.computed{"background-image"}.s != "":
        # ugly hack for background-image display... TODO actually display images
        let s = "[img]"
        let w = s.len * window.ppc
        var ix = x
        if box.width < w:
          # text is larger than image; center it to minimize error
          ix -= w div 2
          ix += box.width div 2
        let x = ix div window.ppc
        let y = y div window.ppl
        if y >= 0 and x + w >= 0:
          grid.setText(s, ComputedFormat(node: box.node), x, y)

      if box of ListItemBox:
        let box = ListItemBox(box)
        if box.marker != nil:
          grid.renderInlineContext(box.marker, x - box.marker.width, y, window)

    if box.inline != nil:
      assert box.nested.len == 0
      if box.computed{"visibility"} == VISIBILITY_VISIBLE:
        grid.renderInlineContext(box.inline, x, y, window)
    else:
      for i in countdown(box.nested.high, 0):
        stack.add((box.nested[i], x, y, posx, posy))

const css = staticRead"res/ua.css"
let uastyle = css.parseStylesheet()
const quirk = css & staticRead"res/quirk.css"
let quirkstyle = quirk.parseStylesheet()
type RenderedDocument* = object
  grid*: FlexibleGrid
  styledRoot*: StyledNode
  images*: seq[StyledNode]

proc renderDocument*(document: Document, userstyle: CSSStylesheet,
    layout: var Viewport, previousStyled: StyledNode): RenderedDocument =
  var grid: FlexibleGrid
  var uastyle = uastyle
  if document.mode == QUIRKS:
    uastyle = quirkstyle
  let styledRoot = document.applyStylesheets(uastyle, userstyle, previousStyled)
  let rootBox = layout.renderLayout(styledRoot)
  grid.renderBlockBox(rootBox, 0, 0, document.window.attrs)
  if grid.len == 0:
    grid.addLine()
  return RenderedDocument(
    grid: grid,
    styledRoot: styledRoot
  )
