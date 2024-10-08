import std/strutils

import css/cssvalues
import css/stylednode
import img/bitmap
import layout/box
import layout/engine
import layout/layoutunit
import types/cell
import types/color
import types/winattrs
import utils/strwidth
import utils/twtuni

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

func findFormatN*(line: FlexibleLine; pos: int): int =
  var i = 0
  while i < line.formats.len:
    if line.formats[i].pos > pos:
      break
    inc i
  return i

proc addLines(grid: var FlexibleGrid; n: int) =
  grid.setLen(grid.len + n)

proc insertFormat(line: var FlexibleLine; i: int; cell: FormatCell) =
  line.formats.insert(cell, i)

proc insertFormat(line: var FlexibleLine; pos, i: int; format: Format;
    node: StyledNode = nil) =
  line.insertFormat(i, FormatCell(format: format, node: node, pos: pos))

proc addFormat(line: var FlexibleLine; pos: int; format: Format;
    node: StyledNode = nil) =
  line.formats.add(FormatCell(format: format, node: node, pos: pos))

func toFormat(computed: CSSComputedValues): Format =
  if computed == nil:
    return Format()
  var flags: set[FormatFlag] = {}
  if computed{"font-style"} in {FontStyleItalic, FontStyleOblique}:
    flags.incl(ffItalic)
  if computed{"font-weight"} > 500:
    flags.incl(ffBold)
  if TextDecorationUnderline in computed{"text-decoration"}:
    flags.incl(ffUnderline)
  if TextDecorationOverline in computed{"text-decoration"}:
    flags.incl(ffOverline)
  if TextDecorationLineThrough in computed{"text-decoration"}:
    flags.incl(ffStrike)
  if TextDecorationBlink in computed{"text-decoration"}:
    flags.incl(ffBlink)
  return Format(
    fgcolor: computed{"color"},
    flags: flags
  )

proc findFirstX(line: var FlexibleLine; x: int; outi: var int): int =
  var cx = 0
  var i = 0
  while cx < x and i < line.str.len:
    let pi = i
    let u = line.str.nextUTF8(i)
    let w = u.twidth(cx)
    # we must ensure x is max(cx, x), otherwise our assumption of cx <= x
    # breaks down
    if cx + w > x:
      i = pi
      break
    cx += w
  outi = i
  return cx

proc setTextStr(line: var FlexibleLine; linestr, ostr: string;
    i, x, cx, nx, targetX: int) =
  var i = i
  let padlen = i + x - cx
  var widthError = max(nx - targetX, 0)
  let linestrTargetI = padlen + linestr.len
  line.str.setLen(linestrTargetI + widthError + ostr.len)
  while i < padlen: # place before new string
    line.str[i] = ' '
    inc i
  copyMem(addr line.str[i], unsafeAddr linestr[0], linestr.len)
  i = linestrTargetI
  while widthError > 0:
    # we ate half of a double width char; pad it out with spaces.
    line.str[i] = ' '
    dec widthError
    inc i
  if ostr.len > 0:
    copyMem(addr line.str[i], unsafeAddr ostr[0], ostr.len)

proc setTextFormat(line: var FlexibleLine; x, cx, nx: int; ostr: string;
    format: Format; node: StyledNode) =
  var fi = line.findFormatN(cx) - 1 # Skip unchanged formats before new string
  if x > cx:
    # Replace formats for padding
    var padformat = Format()
    if fi == -1:
      # No formats
      inc fi # insert after first format (meaning fi = 0)
      line.insertFormat(cx, fi, padformat)
    else:
      # First format's pos may be == cx here.
      if line.formats[fi].pos == cx:
        padformat.bgcolor = line.formats[fi].format.bgcolor
        let node = line.formats[fi].node
        line.formats.delete(fi)
        line.insertFormat(cx, fi, padformat, node)
      else:
        # First format < cx => split it up
        assert line.formats[fi].pos < cx
        padformat.bgcolor = line.formats[fi].format.bgcolor
        let node = line.formats[fi].node
        inc fi # insert after first format
        line.insertFormat(cx, fi, padformat, node)
    inc fi # skip last format
    while fi < line.formats.len and line.formats[fi].pos < x:
      # Other formats must be > cx => replace them
      padformat.bgcolor = line.formats[fi].format.bgcolor
      let node = line.formats[fi].node
      let px = line.formats[fi].pos
      line.formats.delete(fi)
      line.insertFormat(px, fi, padformat, node)
      inc fi
    dec fi # go back to previous format, so that pos <= x
    assert line.formats[fi].pos <= x
  # Now for the text's formats:
  var format = format
  var lformat: Format
  var lnode: StyledNode
  if fi == -1:
    # No formats => just insert a new format at 0
    inc fi
    line.insertFormat(x, fi, format, node)
    lformat = Format()
  else:
    # First format's pos may be == x here.
    lformat = line.formats[fi].format # save for later use
    lnode = line.formats[fi].node
    if line.formats[fi].pos == x:
      # Replace.
      # We must check if the old string's last x position is greater than
      # the new string's first x position. If not, we cannot inherit
      # its bgcolor (which is supposed to end before the new string started.)
      if nx > cx:
        format.bgcolor = line.formats[fi].format.bgcolor
      line.formats.delete(fi)
      line.insertFormat(x, fi, format, node)
    else:
      # First format's pos < x => split it up.
      assert line.formats[fi].pos < x
      if nx > cx: # see above
        format.bgcolor = line.formats[fi].format.bgcolor
      inc fi # insert after first format
      line.insertFormat(x, fi, format, node)
  inc fi # skip last format
  while fi < line.formats.len and line.formats[fi].pos < nx:
    # Other formats must be > x => replace them
    format.bgcolor = line.formats[fi].format.bgcolor
    let px = line.formats[fi].pos
    lformat = line.formats[fi].format # save for later use
    lnode = line.formats[fi].node
    line.formats.delete(fi)
    line.insertFormat(px, fi, format, node)
    inc fi
  if ostr.len > 0 and (fi >= line.formats.len or line.formats[fi].pos > nx):
    # nx < ostr.width, but we have removed all formatting in the range of our
    # string, and no formatting comes directly after it. So we insert the
    # continuation of the last format we replaced after our string.
    # (Default format when we haven't replaced anything.)
    line.insertFormat(nx, fi, lformat, lnode)
  dec fi # go back to previous format, so that pos <= nx
  assert line.formats[fi].pos <= nx
  # That's it!

proc setText(line: var FlexibleLine; linestr: string; x: int; format: Format;
    node: StyledNode) =
  assert x >= 0 and linestr.len != 0
  var targetX = x + linestr.twidth(x)
  var i = 0
  var cx = line.findFirstX(x, i) # first x of new string (before padding)
  var j = i
  var nx = x # last x of new string
  while nx < targetX and j < line.str.len:
    nx += line.str.nextUTF8(j).twidth(nx)
  let ostr = line.str.substr(j)
  line.setTextStr(linestr, ostr, i, x, cx, nx, targetX)
  line.setTextFormat(x, cx, nx, ostr, format, node)

proc setText(grid: var FlexibleGrid; linestr: string; x, y: int; format: Format;
    node: StyledNode) =
  var x = x
  var i = 0
  while x < 0 and i < linestr.len:
    x += linestr.nextUTF8(i).twidth(x)
  if x < 0:
    # highest x is outside the canvas, no need to draw
    return
  # make sure we have line y
  if grid.high < y:
    grid.addLines(y - grid.high)
  if i == 0:
    grid[y].setText(linestr, x, format, node)
  elif i < linestr.len:
    grid[y].setText(linestr.substr(i), x, format, node)

type
  PosBitmap* = ref object
    x*: int
    y*: int
    width*: int
    height*: int
    bmp*: NetworkBitmap

  AbsolutePos = object
    offset: Offset
    size: Size

  RenderState = object
    # Position of the absolute positioning containing block:
    # https://drafts.csswg.org/css-position/#absolute-positioning-containing-block
    absolutePos: seq[AbsolutePos]
    bgcolor: CellColor
    attrsp: ptr WindowAttributes
    images: seq[PosBitmap]

template attrs(state: RenderState): WindowAttributes =
  state.attrsp[]

proc setRowWord(grid: var FlexibleGrid; state: var RenderState;
    word: InlineAtom; offset: Offset; format: Format; node: StyledNode) =
  let y = toInt((offset.y + word.offset.y) div state.attrs.ppl) # y cell
  if y < 0:
    # y is outside the canvas, no need to draw
    return
  var x = toInt((offset.x + word.offset.x) div state.attrs.ppc) # x cell
  grid.setText(word.str, x, y, format, node)

proc paintBackground(grid: var FlexibleGrid; state: var RenderState;
    color: CellColor; startx, starty, endx, endy: int; node: StyledNode) =
  var starty = starty div state.attrs.ppl
  var endy = endy div state.attrs.ppl

  if starty > endy:
    swap(starty, endy)

  if endy <= 0: return # highest y is outside canvas, no need to paint
  if starty < 0: starty = 0
  if starty == endy: return # height is 0, no need to paint

  var startx = startx div state.attrs.ppc

  var endx = endx div state.attrs.ppc
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

proc renderBlockBox(grid: var FlexibleGrid; state: var RenderState;
  box: BlockBox; offset: Offset)

proc paintInlineFragment(grid: var FlexibleGrid; state: var RenderState;
    fragment: InlineFragment; offset: Offset; bgcolor: CellColor) =
  for area in fragment.state.areas:
    let x1 = toInt(offset.x + area.offset.x)
    let y1 = toInt(offset.y + area.offset.y)
    let x2 = toInt(offset.x + area.offset.x + area.size.w)
    let y2 = toInt(offset.y + area.offset.y + area.size.h)
    grid.paintBackground(state, bgcolor, x1, y1, x2, y2, fragment.node)

proc renderInlineFragment(grid: var FlexibleGrid; state: var RenderState;
    fragment: InlineFragment; offset: Offset; bgcolor0: ARGBColor) =
  let bgcolor = fragment.computed{"background-color"}
  var bgcolor0 = bgcolor0
  case bgcolor.t
  of ctNone: discard
  of ctANSI: grid.paintInlineFragment(state, fragment, offset, bgcolor)
  of ctRGB:
    bgcolor0 = bgcolor0.blend(bgcolor.argbcolor)
    if bgcolor0.a > 0:
      grid.paintInlineFragment(state, fragment, offset, cellColor(bgcolor0))
  if fragment.t == iftParent:
    for child in fragment.children:
      grid.renderInlineFragment(state, child, offset, bgcolor0)
  else:
    let format = fragment.computed.toFormat()
    for atom in fragment.state.atoms:
      case atom.t
      of iatInlineBlock:
        grid.renderBlockBox(state, atom.innerbox, offset + atom.offset)
      of iatWord:
        grid.setRowWord(state, atom, offset, format, fragment.node)
      of iatImage:
        let x1 = offset.x.toInt
        let y1 = offset.y.toInt
        let x2 = (offset.x + atom.size.w).toInt
        let y2 = (offset.y + atom.size.h).toInt
        grid.paintBackground(state, bgcolor, x1, y1, x2, y2, fragment.node)
        state.images.add(PosBitmap(
          x: (offset.x div state.attrs.ppc).toInt,
          y: (offset.y div state.attrs.ppl).toInt,
          width: atom.size.w.toInt,
          height: atom.size.h.toInt,
          bmp: atom.bmp
        ))
  if fragment.computed{"position"} != PositionStatic:
    if fragment.splitType != {stSplitStart, stSplitEnd}:
      if stSplitStart in fragment.splitType:
        state.absolutePos.add(AbsolutePos(
          offset: offset + fragment.state.startOffset,
          # looks like it's OK to set size to 0 here
        ))
      if stSplitEnd in fragment.splitType:
        discard state.absolutePos.pop()

proc renderRootInlineFragment(grid: var FlexibleGrid; state: var RenderState;
    root: RootInlineFragment; offset: Offset) =
  grid.renderInlineFragment(state, root.fragment, root.state.offset + offset,
    rgba(0, 0, 0, 0))

proc renderBlockBox(grid: var FlexibleGrid; state: var RenderState;
    box: BlockBox; offset: Offset) =
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
    if box.computed{"position"} == PositionAbsolute:
      if not box.computed{"left"}.auto:
        offset.x = state.absolutePos[^1].offset.x
      elif not box.computed{"right"}.auto:
        offset.x = state.absolutePos[^1].offset.x + state.absolutePos[^1].size.w
      if not box.computed{"top"}.auto:
        offset.y = state.absolutePos[^1].offset.y
      elif not box.computed{"bottom"}.auto:
        offset.y = state.absolutePos[^1].offset.y + state.absolutePos[^1].size.h
    offset += box.state.offset
    if box.computed{"position"} != PositionStatic:
      state.absolutePos.add(AbsolutePos(
        offset: offset,
        size: box.state.size
      ))
      stack.add((nil, offset(-1, -1)))
    if box.computed{"visibility"} == VisibilityVisible:
      let bgcolor = box.computed{"background-color"}
      if bgcolor.t == ctANSI or bgcolor.t == ctRGB and bgcolor.argbcolor.a > 0:
        if box.computed{"-cha-bgcolor-is-canvas"} and
            state.bgcolor == defaultColor:
          #TODO bgimage
          state.bgcolor = bgcolor
        #TODO color blending
        let ix = toInt(offset.x)
        let iy = toInt(offset.y)
        let e = offset + box.state.size
        let iex = toInt(e.x)
        let iey = toInt(e.y)
        grid.paintBackground(state, bgcolor, ix, iy, iex, iey, box.node)
      if box.computed{"background-image"}.t == ContentImage and
          box.computed{"background-image"}.s != "":
        # ugly hack for background-image display... TODO actually display images
        let s = "[img]"
        let w = s.len * state.attrs.ppc
        var ix = offset.x
        if box.state.size.w < w:
          # text is larger than image; center it to minimize error
          ix -= w div 2
          ix += box.state.size.w div 2
        let x = toInt(ix div state.attrs.ppc)
        let y = toInt(offset.y div state.attrs.ppl)
        if y >= 0 and x + w >= 0:
          grid.setText(s, x, y, box.computed.toFormat(), box.node)
    if box.inline != nil:
      assert box.nested.len == 0
      if box.computed{"visibility"} == VisibilityVisible:
        grid.renderRootInlineFragment(state, box.inline, offset)
    else:
      for i in countdown(box.nested.high, 0):
        stack.add((box.nested[i], offset))

proc renderDocument*(grid: var FlexibleGrid; bgcolor: var CellColor;
    styledRoot: StyledNode; attrsp: ptr WindowAttributes;
    images: var seq[PosBitmap]) =
  grid.setLen(0)
  if styledRoot == nil:
    # no HTML element when we run cascade; just clear all lines.
    return
  var state = RenderState(absolutePos: @[AbsolutePos()], attrsp: attrsp)
  let rootBox = styledRoot.layout(attrsp)
  grid.renderBlockBox(state, rootBox, offset(0, 0))
  if grid.len == 0:
    grid.addLines(1)
  bgcolor = state.bgcolor
  images = state.images
