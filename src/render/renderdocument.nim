import strutils
import unicode

import css/stylednode
import css/values
import display/winattrs
import layout/box
import layout/engine
import layout/layoutunit
import types/cell
import types/color
import utils/twtstr

func formatFromWord(computed: ComputedFormat): Format =
  result.fgcolor = computed.color.cellColor()
  if computed.bgcolor.a != 0:
    result.bgcolor = computed.bgcolor.cellColor()
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

proc setText(lines: var FlexibleGrid, linestr: string, cformat: ComputedFormat,
    x, y: int) {.inline.} =
  assert linestr.len != 0
  var i = 0
  var r: Rune
  # make sure we have line y
  if lines.high < y:
    lines.addLines(y - lines.high)

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
  let linestrwidth = linestr.twidth(x)

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

  # Note: following algorithm breaks if cx == nx or x == nx (I think).
  # So we do an early return in both cases, just in case.
  # This should result in correct behavior in all cases, since the formatting
  # inserted would be for a zero width text.
  if cx == nx:
    # cx is nx, early return.
    return

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
  if x == nx:
    # x is nx, early return.
    return

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
      if cformat.bgcolor.a == 0: #TODO alpha blending
        # We must check if the old string's last x position is greater than
        # the new string's first x position. If not, we cannot inherit
        # its bgcolor (which is supposed to end before the new string started.)
        if nx > cx:
          format.bgcolor = lines[y].formats[fi].format.bgcolor
      lines[y].formats.delete(fi)
      lines[y].insertFormat(x, fi, format, cformat.node)
    else:
      # First format's pos < x => split it up.
      assert lines[y].formats[fi].pos < x
      if cformat.bgcolor.a == 0: #TODO alpha blending
        if nx > cx: # see above
          format.bgcolor = lines[y].formats[fi].format.bgcolor
      inc fi # insert after first format
      lines[y].insertFormat(x, fi, format, cformat.node)
  inc fi # skip last format

  while fi < lines[y].formats.len and lines[y].formats[fi].pos < nx:
    # Other formats must be > x => replace them
    if cformat.bgcolor.a == 0: #TODO alpha blending
      format.bgcolor = lines[y].formats[fi].format.bgcolor
    let px = lines[y].formats[fi].pos
    lformat = lines[y].formats[fi].format # save for later use
    lnode = lines[y].formats[fi].node
    lines[y].formats.delete(fi)
    lines[y].insertFormat(px, fi, format, cformat.node)
    inc fi

  if i < ostr.len and
      (fi >= lines[y].formats.len or lines[y].formats[fi].pos > nx):
    # nx < ostr.width, but we have removed all formatting in the range of our
    # string, and no formatting comes directly after it. So we insert the
    # continuation of the last format we replaced after our string.
    # (Default format when we haven't replaced anything.)
    lines[y].insertFormat(nx, fi, lformat, lnode)

  dec fi # go back to previous format, so that pos <= nx
  assert lines[y].formats[fi].pos <= nx
  # That's it!

proc setRowWord(lines: var FlexibleGrid, word: InlineAtom, x, y: LayoutUnit,
    window: WindowAttributes) =
  var r: Rune

  let y = toInt((y + word.offset.y) div window.ppl) # y cell
  if y < 0: return # y is outside the canvas, no need to draw

  var x = toInt((x + word.offset.x) div window.ppc) # x cell
  var i = 0
  while x < 0 and i < word.str.len:
    fastRuneAt(word.str, i, r)
    x += r.twidth(x)
  if x < 0: return # highest x is outside the canvas, no need to draw
  let linestr = word.str.substr(i)
  lines.setText(linestr, word.wformat, x, y)

proc setSpacing(lines: var FlexibleGrid, spacing: InlineAtom, x, y: LayoutUnit,
    window: WindowAttributes) =
  let y = toInt((y + spacing.offset.y) div window.ppl) # y cell
  if y < 0: return # y is outside the canvas, no need to draw

  var x = toInt((x + spacing.offset.x) div window.ppc) # x cell
  let width = toInt(spacing.size.w div window.ppc) # cell width

  if x + width < 0: return # highest x is outside the canvas, no need to draw
  var i = 0
  if x < 0:
    i -= x
    x = 0
  if i < width:
    let linestr = ' '.repeat(width - i)
    lines.setText(linestr, spacing.sformat, x, y)

proc paintBackground(lines: var FlexibleGrid, color: RGBAColor, startx,
    starty, endx, endy: int, node: StyledNode, window: WindowAttributes) =
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
  if lines.high < endy:
    lines.addLines(endy - lines.high)

  for y in starty..<endy:
    # Make sure line.width() >= endx
    let linewidth = lines[y].width()
    if linewidth < endx:
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
        lines[y].insertFormat(fi, copy)

    # Process formatting around endx
    assert lines[y].formats.len > 0
    let fi = lines[y].findFormatN(endx) - 1
    if fi == -1:
      # Last format > endx -> nothing to be done
      discard
    elif lines[y].formats[fi].pos != endx:
      let copy = lines[y].formats[fi]
      if linewidth != endx:
        lines[y].formats[fi].pos = endx
        lines[y].insertFormat(fi, copy)
      else:
        lines[y].formats.delete(fi)
        lines[y].insertFormat(fi, copy)

    # Paint format backgrounds between startx and endx
    for fi in 0..lines[y].formats.high:
      if lines[y].formats[fi].pos >= endx:
        break
      if lines[y].formats[fi].pos >= startx:
        lines[y].formats[fi].format.bgcolor = color
        lines[y].formats[fi].node = node

func calculateErrorY(ctx: InlineContext, window: WindowAttributes):
    LayoutUnit =
  if ctx.lines.len <= 1: return 0
  var error = 0
  for i in 0 ..< ctx.lines.len:
    if i < ctx.lines.high:
      let dy = toInt(ctx.lines[i + 1].offsety - ctx.lines[i].offsety)
      error += dy - (dy div window.ppl) * window.ppl
  return error div (ctx.lines.len - 1)

proc renderBlockBox(grid: var FlexibleGrid, box: BlockBox, x, y: LayoutUnit,
  window: WindowAttributes, posx: LayoutUnit = 0, posy: LayoutUnit = 0)

proc renderInlineContext(grid: var FlexibleGrid, ctx: InlineContext,
    x, y: LayoutUnit, window: WindowAttributes, posx: LayoutUnit = 0,
    posy: LayoutUnit = 0) =
  let x = x + ctx.offset.x
  let y = y + ctx.offset.y
  let erry = ctx.calculateErrorY(window)
  var i = 0
  for line in ctx.lines:
    let y0 = y + line.offsety
    let y = y0 - erry * i
    let r = (y div window.ppl).toInt()
    if grid.high < r:
      grid.addLines(r - grid.high)
    for atom in line.atoms:
      case atom.t
      of INLINE_BLOCK:
        let x = x + atom.offset.x
        let y = y + atom.offset.y
        grid.renderBlockBox(atom.innerbox, x, y, window, posx, posy)
      of INLINE_WORD:
        grid.setRowWord(atom, x, y, window)
      of INLINE_SPACING, INLINE_PADDING:
        grid.setSpacing(atom, x, y, window)
    inc i

proc renderBlockBox(grid: var FlexibleGrid, box: BlockBox, x, y: LayoutUnit,
    window: WindowAttributes, posx: LayoutUnit = 0, posy: LayoutUnit = 0) =
  var stack = newSeqOfCap[tuple[
    box: BlockBox,
    x, y, posx, posy: LayoutUnit
  ]](100)
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
      if box.computed{"background-color"}.a != 0: #TODO color blending
        let ix = toInt(x)
        let iy = toInt(y)
        let iex = toInt(x + box.size.w)
        let iey = toInt(y + box.size.h)
        grid.paintBackground(box.computed{"background-color"}, ix, iy, iex,
          iey, box.node, window)
      if box.computed{"background-image"}.t == CONTENT_IMAGE and
          box.computed{"background-image"}.s != "":
        # ugly hack for background-image display... TODO actually display images
        let s = "[img]"
        let w = s.len * window.ppc
        var ix = x
        if box.size.w < w:
          # text is larger than image; center it to minimize error
          ix -= w div 2
          ix += box.size.w div 2
        let x = toInt(ix div window.ppc)
        let y = toInt(y div window.ppl)
        if y >= 0 and x + w >= 0:
          grid.setText(s, ComputedFormat(node: box.node), x, y)

      if box of ListItemBox:
        let box = ListItemBox(box)
        if box.marker != nil:
          grid.renderInlineContext(box.marker, x - box.marker.size.w, y, window)

    if box.inline != nil:
      assert box.nested.len == 0
      if box.computed{"visibility"} == VISIBILITY_VISIBLE:
        grid.renderInlineContext(box.inline, x, y, window)
    else:
      for i in countdown(box.nested.high, 0):
        stack.add((box.nested[i], x, y, posx, posy))

proc renderDocument*(styledRoot: StyledNode, attrs: WindowAttributes):
    FlexibleGrid =
  var grid: FlexibleGrid
  let rootBox = renderLayout(styledRoot, attrs)
  grid.renderBlockBox(rootBox, 0, 0, attrs)
  if grid.len == 0:
    grid.addLine()
  return grid
