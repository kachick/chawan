import std/strutils
import std/unicode

import css/stylednode
import css/values
import display/term
import layout/box
import layout/engine
import layout/layoutunit
import types/cell
import types/color
import utils/strwidth

type
  # A FormatCell *starts* a new terminal formatting context.
  # If no FormatCell exists before a given cell, the default formatting is used.
  FormatCell* = object
    format*: Format
    pos*: int
    node*: StyledNode

  # Following properties should hold for `formats':
  # * Position should be >= 0, <= str.width().
  # * The position of every FormatCell should be greater than the position
  #   of the previous FormatCell.
  FlexibleLine* = object
    str*: string
    formats*: seq[FormatCell]

  FlexibleGrid* = seq[FlexibleLine]

func findFormatN*(line: FlexibleLine, pos: int): int =
  var i = 0
  while i < line.formats.len:
    if line.formats[i].pos > pos:
      break
    inc i
  return i

func findFormat*(line: FlexibleLine, pos: int): FormatCell =
  let i = line.findFormatN(pos) - 1
  if i != -1:
    result = line.formats[i]
  else:
    result.pos = -1

func findNextFormat*(line: FlexibleLine, pos: int): FormatCell =
  let i = line.findFormatN(pos)
  if i < line.formats.len:
    result = line.formats[i]
  else:
    result.pos = -1

proc addLine*(grid: var FlexibleGrid) =
  grid.add(FlexibleLine())

proc addLines*(grid: var FlexibleGrid, n: int) =
  grid.setLen(grid.len + n)

proc insertFormat*(line: var FlexibleLine, i: int, cell: FormatCell) =
  line.formats.insert(cell, i)

proc insertFormat*(line: var FlexibleLine, pos, i: int, format: Format,
    node: StyledNode = nil) =
  line.insertFormat(i, FormatCell(format: format, node: node, pos: pos))

proc addFormat*(line: var FlexibleLine, pos: int, format: Format,
    node: StyledNode = nil) =
  line.formats.add(FormatCell(format: format, node: node, pos: pos))

func toFormat(computed: CSSComputedValues): Format =
  if computed == nil:
    return Format()
  var flags: set[FormatFlags]
  if computed{"font-style"} in {FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE}:
    flags.incl(FLAG_ITALIC)
  if computed{"font-weight"} > 500:
    flags.incl(FLAG_BOLD)
  if TEXT_DECORATION_UNDERLINE in computed{"text-decoration"}:
    flags.incl(FLAG_UNDERLINE)
  if TEXT_DECORATION_OVERLINE in computed{"text-decoration"}:
    flags.incl(FLAG_OVERLINE)
  if TEXT_DECORATION_LINE_THROUGH in computed{"text-decoration"}:
    flags.incl(FLAG_STRIKE)
  if TEXT_DECORATION_BLINK in computed{"text-decoration"}:
    flags.incl(FLAG_BLINK)
  return Format(
    fgcolor: computed{"color"},
    flags: flags
  )

proc setText(grid: var FlexibleGrid; linestr: string; x, y: int;
    format: Format; node: StyledNode) {.inline.} =
  assert linestr.len != 0
  var i = 0
  var r: Rune
  # make sure we have line y
  if grid.high < y:
    grid.addLines(y - grid.high)

  var cx = 0 # first x of new string (before padding)
  while cx < x and i < grid[y].str.len:
    let pi = i
    fastRuneAt(grid[y].str, i, r)
    let w = r.twidth(cx)
    # we must ensure x is max(cx, x), otherwise our assumption of cx <= x
    # breaks down
    if cx + w > x:
      i = pi
      break
    cx += w

  let ostr = grid[y].str.substr(i)
  grid[y].str.setLen(i)
  let padwidth = x - cx
  if padwidth > 0:
    grid[y].str &= ' '.repeat(padwidth)

  grid[y].str &= linestr
  let linestrwidth = linestr.twidth(x)

  i = 0
  var nx = x # last x of new string
  while nx < x + linestrwidth and i < ostr.len:
    fastRuneAt(ostr, i, r)
    nx += r.twidth(nx)

  if i < ostr.len:
    grid[y].str &= ostr.substr(i)

  # Negative x values make no sense from here on, as text with negative x
  # coordinates can not be formatted.
  let x = max(0, x)
  if cx < 0:
    cx = 0
  if nx < 0:
    nx = 0

  # Skip unchanged formats before the new string
  var fi = grid[y].findFormatN(cx) - 1

  if padwidth > 0:
    # Replace formats for padding
    var padformat = Format()
    if fi == -1:
      # No formats
      inc fi # insert after first format (meaning fi = 0)
      grid[y].insertFormat(cx, fi, padformat)
    else:
      # First format's pos may be == cx here.
      if grid[y].formats[fi].pos == cx:
        padformat.bgcolor = grid[y].formats[fi].format.bgcolor
        let node = grid[y].formats[fi].node
        grid[y].formats.delete(fi)
        grid[y].insertFormat(cx, fi, padformat, node)
      else:
        # First format < cx => split it up
        assert grid[y].formats[fi].pos < cx
        padformat.bgcolor = grid[y].formats[fi].format.bgcolor
        let node = grid[y].formats[fi].node
        inc fi # insert after first format
        grid[y].insertFormat(cx, fi, padformat, node)
    inc fi # skip last format
    while fi < grid[y].formats.len and grid[y].formats[fi].pos < x:
      # Other formats must be > cx => replace them
      padformat.bgcolor = grid[y].formats[fi].format.bgcolor
      let node = grid[y].formats[fi].node
      let px = grid[y].formats[fi].pos
      grid[y].formats.delete(fi)
      grid[y].insertFormat(px, fi, padformat, node)
      inc fi
    dec fi # go back to previous format, so that pos <= x
    assert grid[y].formats[fi].pos <= x

  # Now for the text's formats:
  var format = format
  var lformat: Format
  var lnode: StyledNode
  if fi == -1:
    # No formats => just insert a new format at 0
    inc fi
    grid[y].insertFormat(x, fi, format, node)
    lformat = Format()
  else:
    # First format's pos may be == x here.
    lformat = grid[y].formats[fi].format # save for later use
    lnode = grid[y].formats[fi].node
    if grid[y].formats[fi].pos == x:
      # Replace.
      # We must check if the old string's last x position is greater than
      # the new string's first x position. If not, we cannot inherit
      # its bgcolor (which is supposed to end before the new string started.)
      if nx > cx:
        format.bgcolor = grid[y].formats[fi].format.bgcolor
      grid[y].formats.delete(fi)
      grid[y].insertFormat(x, fi, format, node)
    else:
      # First format's pos < x => split it up.
      assert grid[y].formats[fi].pos < x
      if nx > cx: # see above
        format.bgcolor = grid[y].formats[fi].format.bgcolor
      inc fi # insert after first format
      grid[y].insertFormat(x, fi, format, node)
  inc fi # skip last format

  while fi < grid[y].formats.len and grid[y].formats[fi].pos < nx:
    # Other formats must be > x => replace them
    format.bgcolor = grid[y].formats[fi].format.bgcolor
    let px = grid[y].formats[fi].pos
    lformat = grid[y].formats[fi].format # save for later use
    lnode = grid[y].formats[fi].node
    grid[y].formats.delete(fi)
    grid[y].insertFormat(px, fi, format, node)
    inc fi

  if i < ostr.len and
      (fi >= grid[y].formats.len or grid[y].formats[fi].pos > nx):
    # nx < ostr.width, but we have removed all formatting in the range of our
    # string, and no formatting comes directly after it. So we insert the
    # continuation of the last format we replaced after our string.
    # (Default format when we haven't replaced anything.)
    grid[y].insertFormat(nx, fi, lformat, lnode)

  dec fi # go back to previous format, so that pos <= nx
  assert grid[y].formats[fi].pos <= nx
  # That's it!

proc setRowWord(grid: var FlexibleGrid; word: InlineAtom; offset: Offset;
    attrs: WindowAttributes; format: Format; node: StyledNode) =
  let y = toInt((offset.y + word.offset.y) div attrs.ppl) # y cell
  if y < 0:
    # y is outside the canvas, no need to draw
    return
  var x = toInt((offset.x + word.offset.x) div attrs.ppc) # x cell
  var i = 0
  var r: Rune
  while x < 0 and i < word.str.len:
    fastRuneAt(word.str, i, r)
    x += r.twidth(x)
  if x < 0:
    # highest x is outside the canvas, no need to draw
    return
  if i < word.str.len:
    let linestr = word.str.substr(i)
    grid.setText(linestr, x, y, format, node)

proc setSpacing(grid: var FlexibleGrid; spacing: InlineAtom; offset: Offset;
    attrs: WindowAttributes; format: Format; node: StyledNode) =
  let y = toInt((offset.y + spacing.offset.y) div attrs.ppl) # y cell
  if y < 0: return # y is outside the canvas, no need to draw
  var x = toInt((offset.x + spacing.offset.x) div attrs.ppc) # x cell
  let width = toInt(spacing.size.w div attrs.ppc) # cell width
  if x + width < 0:
    return # highest x is outside the canvas, no need to draw
  var i = 0
  if x < 0:
    i -= x
    x = 0
  if i < width:
    let linestr = ' '.repeat(width - i)
    grid.setText(linestr, x, y, format, node)

proc paintBackground(grid: var FlexibleGrid; color: CellColor; startx,
    starty, endx, endy: int; node: StyledNode; attrs: WindowAttributes) =
  var starty = starty div attrs.ppl
  var endy = endy div attrs.ppl

  if starty > endy:
    swap(starty, endy)

  if endy <= 0: return # highest y is outside canvas, no need to paint
  if starty < 0: starty = 0
  if starty == endy: return # height is 0, no need to paint

  var startx = startx div attrs.ppc

  var endx = endx div attrs.ppc
  if endy < 0: endy = 0

  if startx > endx:
    swap(startx, endx)

  if endx <= 0: return # highest x is outside the canvas, no need to paint
  if startx < 0: startx = 0
  if startx == endx: return # width is 0, no need to paint

  # make sure we have line y
  if grid.high < endy:
    grid.addLines(endy - grid.high)

  for y in starty..<endy:
    # Make sure line.width() >= endx
    let linewidth = grid[y].str.width()
    if linewidth < endx:
      grid[y].str &= ' '.repeat(endx - linewidth)

    # Process formatting around startx
    if grid[y].formats.len == 0:
      # No formats
      grid[y].addFormat(startx, Format())
    else:
      let fi = grid[y].findFormatN(startx) - 1
      if fi == -1:
        # No format <= startx
        grid[y].insertFormat(startx, 0, Format())
      elif grid[y].formats[fi].pos == startx:
        # Last format equals startx => next comes after, nothing to be done
        discard
      else:
        # Last format lower than startx => separate format from startx
        let copy = grid[y].formats[fi]
        grid[y].formats[fi].pos = startx
        grid[y].insertFormat(fi, copy)

    # Process formatting around endx
    assert grid[y].formats.len > 0
    let fi = grid[y].findFormatN(endx) - 1
    if fi == -1:
      # Last format > endx -> nothing to be done
      discard
    elif grid[y].formats[fi].pos != endx:
      let copy = grid[y].formats[fi]
      if linewidth != endx:
        grid[y].formats[fi].pos = endx
        grid[y].insertFormat(fi, copy)
      else:
        grid[y].formats.delete(fi)
        grid[y].insertFormat(fi, copy)

    # Paint format backgrounds between startx and endx
    for fi in 0..grid[y].formats.high:
      if grid[y].formats[fi].pos >= endx:
        break
      if grid[y].formats[fi].pos >= startx:
        grid[y].formats[fi].format.bgcolor = color
        grid[y].formats[fi].node = node

type RenderState = object
  # Position of the absolute positioning containing block:
  # https://drafts.csswg.org/css-position/#absolute-positioning-containing-block
  absolutePos: seq[Offset]
  bgcolor: CellColor

proc renderBlockBox(grid: var FlexibleGrid; state: var RenderState;
  box: BlockBox; offset: Offset; attrs: WindowAttributes)

proc paintInlineFragment(grid: var FlexibleGrid; fragment: InlineFragment;
    offset: Offset; bgcolor: CellColor; attrs: WindowAttributes) =
  let x = offset.x
  let y = offset.y
  let node = fragment.node
  if fragment.startOffset.y - fragment.size.h == fragment.endOffset.y:
    let x0 = toInt(x + fragment.startOffset.x)
    let y0 = toInt(y + fragment.endOffset.y)
    let x1 = toInt(x + fragment.endOffset.x)
    let y1 = toInt(y + fragment.startOffset.y)
    grid.paintBackground(bgcolor, x0, y0, x1, y1, node, attrs)
  else:
    let x0 = toInt(x + fragment.startOffset.x)
    let y0 = toInt(y)
    let x1 = toInt(x + fragment.size.w)
    let y1 = toInt(y + fragment.startOffset.y)
    grid.paintBackground(bgcolor, x0, y0, x1, y1, node, attrs)
    let x2 = toInt(x)
    let y2 = y1
    let x3 = x1
    let y3 = toInt(y + fragment.endOffset.y)
    grid.paintBackground(bgcolor, x2, y2, x3, y3, node, attrs)
    let x4 = x2
    let y4 = y3
    let x5 = toInt(x + fragment.endOffset.x)
    let y5 = toInt(y + fragment.size.h)
    grid.paintBackground(bgcolor, x4, y4, x5, y5, node, attrs)

proc renderInlineFragment(grid: var FlexibleGrid; state: var RenderState,
    fragment: InlineFragment; offset: Offset; attrs: WindowAttributes) =
  assert fragment.atoms.len == 0 or fragment.children.len == 0
  let bgcolor = fragment.computed{"background-color"}
  if bgcolor.t == ctANSI or bgcolor.t == ctRGB and bgcolor.rgbacolor.a > 0:
    #TODO color blending
    grid.paintInlineFragment(fragment, offset, bgcolor, attrs)
  if fragment.atoms.len > 0:
    let format = fragment.computed.toFormat()
    for atom in fragment.atoms:
      case atom.t
      of INLINE_BLOCK:
        let offset = Offset(
          x: offset.x + atom.offset.x,
          y: offset.y + atom.offset.y
        )
        grid.renderBlockBox(state, atom.innerbox, offset, attrs)
      of INLINE_WORD:
        grid.setRowWord(atom, offset, attrs, format, fragment.node)
      of INLINE_SPACING:
        grid.setSpacing(atom, offset, attrs, format, fragment.node)
  if fragment.computed{"position"} != POSITION_STATIC:
    if fragment.splitType != {stSplitStart, stSplitEnd}:
      if stSplitStart in fragment.splitType:
        state.absolutePos.add(Offset(
          x: offset.x + fragment.startOffset.x,
          y: offset.y + fragment.endOffset.y
        ))
      if stSplitEnd in fragment.splitType:
        discard state.absolutePos.pop()
  for child in fragment.children:
    grid.renderInlineFragment(state, child, offset, attrs)

proc renderRootInlineFragment(grid: var FlexibleGrid; state: var RenderState;
    root: RootInlineFragment; offset: Offset; attrs: WindowAttributes) =
  let offset = Offset(
    x: offset.x + root.offset.x,
    y: offset.y + root.offset.y
  )
  grid.renderInlineFragment(state, root.fragment, offset, attrs)

proc renderBlockBox(grid: var FlexibleGrid; state: var RenderState;
    box: BlockBox; offset: Offset; attrs: WindowAttributes) =
  var stack = newSeqOfCap[tuple[
    box: BlockBox,
    offset: Offset
  ]](100)
  stack.add((box, offset))

  while stack.len > 0:
    var (box, offset) = stack.pop()
    if box == nil: # positioned marker
      discard state.absolutePos.pop()
      continue
    if not box.computed{"left"}.auto or not box.computed{"right"}.auto:
      offset.x = state.absolutePos[^1].x
    if not box.computed{"top"}.auto or not box.computed{"bottom"}.auto:
      offset.y = state.absolutePos[^1].y
    offset.x += box.offset.x
    offset.y += box.offset.y
    if box.computed{"position"} != POSITION_STATIC:
      state.absolutePos.add(offset)
      stack.add((nil, Offset(x: -1, y: -1)))

    if box.computed{"visibility"} == VISIBILITY_VISIBLE:
      let bgcolor = box.computed{"background-color"}
      if bgcolor.t == ctANSI or bgcolor.t == ctRGB and bgcolor.rgbacolor.a > 0:
        if box.computed{"-cha-bgcolor-is-canvas"} and
            state.bgcolor == defaultColor:
          #TODO bgimage
          state.bgcolor = bgcolor
        #TODO color blending
        let ix = toInt(offset.x)
        let iy = toInt(offset.y)
        let iex = toInt(offset.x + box.size.w)
        let iey = toInt(offset.y + box.size.h)
        grid.paintBackground(bgcolor, ix, iy, iex, iey, box.node, attrs)
      if box.computed{"background-image"}.t == CONTENT_IMAGE and
          box.computed{"background-image"}.s != "":
        # ugly hack for background-image display... TODO actually display images
        let s = "[img]"
        let w = s.len * attrs.ppc
        var ix = offset.x
        if box.size.w < w:
          # text is larger than image; center it to minimize error
          ix -= w div 2
          ix += box.size.w div 2
        let x = toInt(ix div attrs.ppc)
        let y = toInt(offset.y div attrs.ppl)
        if y >= 0 and x + w >= 0:
          grid.setText(s, x, y, box.computed.toFormat(), box.node)

      if box of ListItemBox:
        let box = ListItemBox(box)
        if box.marker != nil:
          let offset = Offset(
            x: offset.x - box.marker.size.w,
            y: offset.y
          )
          grid.renderRootInlineFragment(state, box.marker, offset, attrs)

    if box.inline != nil:
      assert box.nested.len == 0
      if box.computed{"visibility"} == VISIBILITY_VISIBLE:
        grid.renderRootInlineFragment(state, box.inline, offset, attrs)
    else:
      for i in countdown(box.nested.high, 0):
        stack.add((box.nested[i], offset))

proc renderDocument*(grid: var FlexibleGrid; bgcolor: var CellColor;
    styledRoot: StyledNode; attrs: WindowAttributes) =
  grid.setLen(0)
  var state = RenderState(
    absolutePos: @[Offset(x: 0, y: 0)]
  )
  let rootBox = renderLayout(styledRoot, attrs)
  grid.renderBlockBox(state, rootBox, Offset(x: 0, y: 0), attrs)
  if grid.len == 0:
    grid.addLine()
  bgcolor = state.bgcolor
