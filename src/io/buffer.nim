import httpclient
import options
import os
import streams
import tables
import terminal
import unicode

import css/sheet
import css/stylednode
import html/dom
import html/tags
import html/htmlparser
import io/cell
import io/lineedit
import io/loader
import io/term
import js/regex
import layout/box
import render/renderdocument
import render/rendertext
import types/color
import types/url
import utils/twtstr

type
  CursorPosition* = object
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int

  BufferMatch* = object
    success*: bool
    x*: int
    y*: int
    str*: string

  Buffer* = ref object
    contenttype*: string
    title*: string
    lines*: FlexibleGrid
    display*: FixedGrid
    prevdisplay*: FixedGrid
    statusmsg*: FixedGrid
    hovertext*: string
    width*: int
    height*: int
    cpos*: CursorPosition
    attrs*: TermAttributes
    document*: Document
    viewport*: Viewport
    prevstyled*: StyledNode
    redraw*: bool
    reshape*: bool
    nostatus*: bool
    location*: Url
    ispipe*: bool
    istream*: Stream
    streamclosed*: bool
    source*: string
    prevnode*: StyledNode
    sourcepair*: Buffer
    prev*: Buffer
    next*: Buffer
    userstyle*: CSSStylesheet
    loader*: FileLoader

proc newBuffer*(): Buffer =
  new(result)
  result.attrs = getTermAttributes()
  result.width = result.attrs.width
  result.height = result.attrs.height - 1

  result.display = newFixedGrid(result.width, result.height)
  result.prevdisplay = newFixedGrid(result.width, result.height)
  result.statusmsg = newFixedGrid(result.width)

func cursorx*(buffer: Buffer): int {.inline.} = buffer.cpos.cursorx
func cursory*(buffer: Buffer): int {.inline.} = buffer.cpos.cursory
func fromx*(buffer: Buffer): int {.inline.} = buffer.cpos.fromx
func fromy*(buffer: Buffer): int {.inline.} = buffer.cpos.fromy
func xend*(buffer: Buffer): int {.inline.} = buffer.cpos.xend

func generateFullOutput(buffer: Buffer): string =
  var x = 0
  var w = 0
  var format = newFormat()
  result &= HVP(1, 1)

  for cell in buffer.display:
    if x >= buffer.width:
      result &= EL()
      result &= '\n'
      x = 0
      w = 0

    result &= format.processFormat(cell.format)
    result &= $cell.runes

    w += cell.width()
    inc x

  result &= EL()
  result &= '\n'

# generate a sequence of instructions to replace the previous frame with the
# current one. ideally should be used when small changes are made (e.g. hover
# changes underlining)
func generateSwapOutput(buffer: Buffer): string =
  var format = newFormat()
  let curr = buffer.display
  let prev = buffer.prevdisplay
  var i = 0
  var x = 0
  var y = 0
  var line = ""
  var lr = false
  while i < curr.len:
    if x >= buffer.width:
      if lr:
        result &= HVP(y + 1, 1)
        result &= EL()
        result &= line
        lr = false
      x = 0
      inc y
      line = ""
    lr = lr or (curr[i] != prev[i])
    line &= format.processFormat(curr[i].format)
    line &= $curr[i].runes
    inc i
    inc x
  if lr:
    result &= HVP(y + 1, 1)
    result &= EL()
    result &= line
    lr = false
  
  #TODO maybe fix this
  #var x = 0
  #var y = 0
  #var cx = -1
  #var cy = -1
  #var i = 0
  #var text = ""
  #while i < max:
  #  if x >= buffer.width:
  #    x = 0
  #    inc y

  #  if curr[i] != prev[i]:
  #    let currwidth = curr[i].runes.width()
  #    let prevwidth = prev[i].runes.width()
  #    if (curr[i].runes.len > 0 or currwidth < prevwidth) and (x != cx or y != cy):
  #      if text.len > 0:
  #        result &= text
  #        text = ""
  #      result &= HVP(y + 1, x + 1)
  #      cx = x
  #      cy = y

  #    text &= format.processFormat(curr[i].format)

  #    text &= $curr[i].runes
  #    if currwidth < prevwidth:
  #      var j = 0
  #      while j < prevwidth - currwidth:
  #        text &= ' '
  #        inc j
  #    if text.len > 0:
  #      inc cx

  #  inc x
  #  inc i
  #if text.len > 0:
  #  result &= $text

func generateStatusMessage*(buffer: Buffer): string =
  var format = newFormat()
  var w = 0
  for cell in buffer.statusmsg:
    result &= format.processFormat(cell.format)
    result &= $cell.runes
    w += cell.width()
  if w < buffer.width:
    result &= EL()

func numLines(buffer: Buffer): int = buffer.lines.len

func lastVisibleLine(buffer: Buffer): int = min(buffer.fromy + buffer.height, buffer.numLines)

func currentLineWidth(buffer: Buffer): int =
  return buffer.lines[buffer.cursory].width()

func maxfromy(buffer: Buffer): int = max(buffer.numLines - buffer.height, 0)

func maxfromx(buffer: Buffer): int = max(buffer.currentLineWidth() - buffer.width, 0)

func acursorx(buffer: Buffer): int =
  return max(0, buffer.cursorx - buffer.fromx)

func acursory(buffer: Buffer): int =
  return buffer.cursory - buffer.fromy

func cellOrigin(buffer: Buffer, x, y: int): int =
  let row = y * buffer.width
  var ox = x
  while ox > 0 and buffer.display[row + ox].runes.len == 0:
    dec ox
  return ox

func currentCellOrigin(buffer: Buffer): int =
  return buffer.cellOrigin(buffer.acursorx, buffer.acursory)

func currentDisplayCell(buffer: Buffer): FixedCell =
  let row = (buffer.cursory - buffer.fromy) * buffer.width
  return buffer.display[row + buffer.currentCellOrigin()]

func getLink(node: StyledNode): HTMLAnchorElement =
  if node == nil:
    return nil
  if node.t == STYLED_ELEMENT and node.node != nil and Element(node.node).tagType == TAG_A:
    return HTMLAnchorElement(node.node)
  if node.node != nil:
    return HTMLAnchorElement(node.node.findAncestor({TAG_A}))
  #TODO ::before links?

const ClickableElements = {
  TAG_A, TAG_INPUT
}

func getClickable(styledNode: StyledNode): Element =
  if styledNode == nil or styledNode.node == nil:
    return nil
  if styledNode.t == STYLED_ELEMENT:
    let element = Element(styledNode.node)
    if element.tagType in ClickableElements:
      return element
  styledNode.node.findAncestor(ClickableElements)

func getCursorClickable(buffer: Buffer): Element =
  return buffer.currentDisplayCell().node.getClickable()

func currentLine(buffer: Buffer): string =
  return buffer.lines[buffer.cursory].str

func cursorBytes(buffer: Buffer, y: int, cc = buffer.fromx + buffer.cursorx): int =
  assert y < buffer.lines.len
  let line = buffer.lines[y].str
  var w = 0
  var i = 0
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.width()
  return i

func currentCursorBytes(buffer: Buffer, cc = buffer.fromx + buffer.cursorx): int =
  return buffer.cursorBytes(buffer.cursory, cc)

func currentWidth(buffer: Buffer): int =
  let line = buffer.currentLine
  if line.len == 0: return 0
  var w = 0
  var i = 0
  let cc = buffer.fromx + buffer.cursorx
  var r: Rune
  fastRuneAt(line, i, r)
  while i < line.len and w < cc:
    fastRuneAt(line, i, r)
    w += r.width()
  return r.width()

func prevWidth(buffer: Buffer): int =
  let line = buffer.currentLine
  if line.len == 0: return 0
  var w = 0
  var i = 0
  let cc = buffer.fromx + buffer.cursorx
  var pr: Rune
  var r: Rune
  fastRuneAt(line, i, r)
  while i < line.len and w < cc:
    pr = r
    fastRuneAt(line, i, r)
    w += r.width()
  return pr.width()

func maxScreenWidth(buffer: Buffer): int =
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine - 1]:
    result = max(line.width(), result)

func atPercentOf(buffer: Buffer): int =
  if buffer.lines.len == 0: return 100
  return (100 * (buffer.cursory + 1)) div buffer.numLines

func hasAnchor*(buffer: Buffer, anchor: string): bool =
  return buffer.document.getElementById(anchor) != nil

func getTitle(buffer: Buffer): string =
  if buffer.document != nil:
    result = buffer.document.title
    if result != "": return result
  if buffer.ispipe:
    return "*pipe*"
  return $buffer.location

proc clearDisplay(buffer: Buffer) =
  buffer.prevdisplay = buffer.display
  buffer.display = newFixedGrid(buffer.width, buffer.height)

proc refreshDisplay(buffer: Buffer) =
  var r: Rune
  var y = 0
  buffer.clearDisplay()

  for line in buffer.lines[buffer.fromy..
                           buffer.lastVisibleLine - 1]:
    var w = 0 # width of the row so far
    var i = 0 # byte in line.str

    # Skip cells till buffer.fromx.
    while w < buffer.fromx and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.width()

    let dls = y * buffer.width # starting position of row in display

    # Fill in the gap in case we skipped more cells than fromx mandates (i.e.
    # we encountered a double-width character.)
    var k = 0
    if w > buffer.fromx:
      while k < w - buffer.fromx:
        buffer.display[dls + k].runes.add(Rune(' '))
        inc k

    var cf = line.findFormat(w)
    var nf = line.findNextFormat(w)

    let startw = w # save this for later

    # Now fill in the visible part of the row.
    while i < line.str.len:
      let pw = w
      fastRuneAt(line.str, i, r)
      w += r.width()
      if w > buffer.fromx + buffer.width:
        break # die on exceeding the width limit
      if nf.pos != -1 and nf.pos <= pw:
        cf = nf
        nf = line.findNextFormat(pw)
      buffer.display[dls + k].runes.add(r)
      if cf.pos != -1:
        buffer.display[dls + k].format = cf.format
        buffer.display[dls + k].node = cf.node
      let tk = k + r.width()
      while k < tk and k < buffer.width - 1:
        inc k

    # Then, for each cell that has a mark, override its formatting with that
    # specified by the mark.
    let aw = buffer.width - (startw - buffer.fromx) # actual width
    for mark in line.marks:
      if mark.x >= startw + aw or mark.x + mark.width < startw: continue
      for i in max(mark.x, startw)..<min(mark.x + mark.width, startw + aw):
        buffer.display[dls + i].format = mark.format

    inc y

proc setCursorX(buffer: Buffer, x: int, refresh = true, save = true) =
  if (not refresh) or (buffer.fromx <= x and x < buffer.fromx + buffer.width):
    buffer.cpos.cursorx = x
  else:
    if refresh and buffer.fromx > buffer.cursorx:
      buffer.cpos.fromx = max(buffer.currentLineWidth() - 1, 0)
      buffer.cpos.cursorx = buffer.fromx
    elif x > buffer.cursorx:
      buffer.cpos.fromx = max(x - buffer.width + 1, 0)
      buffer.cpos.cursorx = x
    elif x < buffer.cursorx:
      buffer.cpos.fromx = x
      buffer.cpos.cursorx = x
    buffer.redraw = true
  if save:
    buffer.cpos.xend = buffer.cursorx

proc restoreCursorX(buffer: Buffer) =
  buffer.setCursorX(max(min(buffer.currentLineWidth() - 1, buffer.xend), 0), false, false)

proc setCursorY(buffer: Buffer, y: int) =
  if buffer.cursory == y:
    return
  if y - buffer.fromy >= 0 and y - buffer.height < buffer.fromy:
    buffer.cpos.cursory = y
  else:
    if y > buffer.cursory:
      buffer.cpos.fromy = max(y - buffer.height + 1, 0)
    else:
      buffer.cpos.fromy = min(y, buffer.maxfromy)
    buffer.cpos.cursory = y
    buffer.redraw = true
  buffer.restoreCursorX()

proc centerLine*(buffer: Buffer) =
  let ny = max(min(buffer.cursory - buffer.height div 2, buffer.numLines - buffer.height), 0)
  if ny != buffer.fromy:
    buffer.cpos.fromy = ny
    buffer.redraw = true

proc setCursorXY*(buffer: Buffer, x, y: int) =
  let fy = buffer.fromy
  buffer.setCursorY(max(min(y, buffer.numLines - 1), 0))
  buffer.setCursorX(max(min(buffer.currentLineWidth(), x), 0))
  if fy != buffer.fromy:
    buffer.centerLine()

proc setFromXY*(buffer: Buffer, x, y: int) =
  buffer.cpos.fromy = max(min(y, buffer.maxfromy), 0)
  buffer.cpos.fromx = max(min(x, buffer.maxfromx), 0)

proc cursorDown*(buffer: Buffer) =
  if buffer.cursory < buffer.numLines - 1:
    buffer.setCursorY(buffer.cursory + 1)

proc cursorUp*(buffer: Buffer) =
  if buffer.cursory > 0:
    buffer.setCursorY(buffer.cursory - 1)

proc cursorRight*(buffer: Buffer) =
  let cellwidth = buffer.currentWidth()
  if buffer.cursorx + cellwidth < buffer.currentLineWidth():
    buffer.setCursorX(buffer.cursorx + cellwidth)

proc cursorLeft*(buffer: Buffer) =
  buffer.setCursorX(max(buffer.cursorx - buffer.prevWidth(), 0))

proc cursorLineBegin*(buffer: Buffer) =
  buffer.setCursorX(0)

proc cursorLineEnd*(buffer: Buffer) =
  buffer.setCursorX(max(buffer.currentLineWidth() - 1, 0))

proc cursorNextWord*(buffer: Buffer) =
  var r: Rune
  var b = buffer.currentCursorBytes()
  var x = buffer.cursorx
  while b < buffer.currentLine.len:
    let pb = b
    fastRuneAt(buffer.currentLine, b, r)
    if r.breaksWord():
      b = pb
      break
    x += r.width()

  while b < buffer.currentLine.len:
    let pb = b
    fastRuneAt(buffer.currentLine, b, r)
    if not r.breaksWord():
      b = pb
      break
    x += r.width()

  if b < buffer.currentLine.len:
    buffer.setCursorX(x)
  else:
    if buffer.cursory < buffer.numLines - 1:
      buffer.cursorDown()
      buffer.cursorLineBegin()
    else:
      buffer.cursorLineEnd()

proc cursorPrevWord*(buffer: Buffer) =
  var b = buffer.currentCursorBytes()
  var x = buffer.cursorx
  if buffer.currentLine.len > 0:
    b = min(b, buffer.currentLine.len - 1)
    while b >= 0:
      let (r, o) = lastRune(buffer.currentLine, b)
      if r.breaksWord():
        break
      b -= o
      x -= r.width()

    while b >= 0:
      let (r, o) = lastRune(buffer.currentLine, b)
      if not r.breaksWord():
        break
      b -= o
      x -= r.width()
  else:
    b = -1

  if b >= 0:
    buffer.setCursorX(x)
  else:
    if buffer.cursory > 0:
      buffer.cursorUp()
      buffer.cursorLineEnd()
    else:
      buffer.cursorLineBegin()

proc cursorNextLink*(buffer: Buffer) =
  let line = buffer.lines[buffer.cursory]
  var i = line.findFormatN(buffer.cursorx) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getClickable()
  inc i

  while i < line.formats.len:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      buffer.setCursorX(format.pos)
      return
    inc i

  for y in (buffer.cursory + 1)..(buffer.numLines - 1):
    let line = buffer.lines[y]
    i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        buffer.setCursorXY(format.pos, y)
        return
      inc i

proc cursorPrevLink*(buffer: Buffer) =
  let line = buffer.lines[buffer.cursory]
  var i = line.findFormatN(buffer.cursorx) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getClickable()
  dec i

  var ly = 0 #last y
  var lx = 0 #last x
  template link_beginning() =
    #go to beginning of link
    ly = y #last y
    lx = format.pos #last x

    #on the current line
    let line = buffer.lines[y]
    while i >= 0:
      let format = line.formats[i]
      let nl = format.node.getClickable()
      if nl == fl:
        lx = format.pos
      dec i

    #on previous lines
    for iy in countdown(ly - 1, 0):
      let line = buffer.lines[iy]
      i = line.formats.len - 1
      while i >= 0:
        let format = line.formats[i]
        let nl = format.node.getClickable()
        if nl == fl:
          ly = iy
          lx = format.pos
        dec i

  while i >= 0:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      let y = buffer.cursory
      link_beginning
      buffer.setCursorXY(lx, ly)
      return
    dec i

  for y in countdown(buffer.cursory - 1, 0):
    let line = buffer.lines[y]
    i = line.formats.len - 1
    while i >= 0:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        link_beginning
        buffer.setCursorXY(lx, ly)
        return
      dec i

proc cursorFirstLine*(buffer: Buffer) =
  buffer.setCursorY(0)

proc cursorLastLine*(buffer: Buffer) =
  buffer.setCursorY(buffer.numLines - 1)

proc cursorTop*(buffer: Buffer) =
  buffer.setCursorY(buffer.fromy)

proc cursorMiddle*(buffer: Buffer) =
  buffer.setCursorY(min(buffer.fromy + (buffer.height - 2) div 2, buffer.numLines - 1))

proc cursorBottom*(buffer: Buffer) =
  buffer.setCursorY(min(buffer.fromy + buffer.height - 1, buffer.numLines - 1))

proc cursorLeftEdge*(buffer: Buffer) =
  buffer.setCursorX(buffer.fromx)

proc cursorVertMiddle*(buffer: Buffer) =
  buffer.setCursorX(min(buffer.fromx + (buffer.width - 2) div 2, buffer.currentLineWidth))

proc cursorRightEdge*(buffer: Buffer) =
  buffer.setCursorX(min(buffer.fromx + buffer.width - 1, buffer.currentLineWidth))

proc halfPageUp*(buffer: Buffer) =
  buffer.cpos.cursory = max(buffer.cursory - buffer.height div 2 + 1, 0)
  let nfy = max(0, buffer.fromy - buffer.height div 2 + 1)
  if nfy != buffer.fromy:
    buffer.cpos.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc halfPageDown*(buffer: Buffer) =
  buffer.cpos.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.numLines - 1)
  let nfy = min(max(buffer.numLines - buffer.height, 0), buffer.fromy + buffer.height div 2 - 1)
  if nfy != buffer.fromy:
    buffer.cpos.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageUp*(buffer: Buffer) =
  buffer.cpos.cursory = max(buffer.cursory - buffer.height, 0)
  let nfy = max(0, buffer.fromy - buffer.height)
  if nfy != buffer.fromy:
    buffer.cpos.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageDown*(buffer: Buffer) =
  buffer.cpos.cursory = min(buffer.cursory + buffer.height, buffer.numLines - 1)
  let nfy = min(buffer.fromy + buffer.height, max(buffer.numLines - buffer.height, 0))
  if nfy != buffer.fromy:
    buffer.cpos.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageLeft*(buffer: Buffer) =
  buffer.cpos.cursorx = max(buffer.cursorx - buffer.width, 0)
  let nfx = max(0, buffer.fromx - buffer.width)
  if nfx != buffer.fromx:
    buffer.cpos.fromx = nfx
    buffer.redraw = true

proc pageRight*(buffer: Buffer) =
  buffer.cpos.cursorx = min(buffer.fromx, buffer.currentLineWidth())
  let nfx = min(max(buffer.maxScreenWidth() - buffer.width, 0), buffer.fromx + buffer.width)
  if nfx != buffer.fromx:
    buffer.cpos.fromx = nfx
    buffer.redraw = true

proc scrollDown*(buffer: Buffer) =
  if buffer.fromy + buffer.height < buffer.numLines:
    inc buffer.cpos.fromy
    if buffer.fromy > buffer.cursory:
      buffer.cursorDown()
    buffer.redraw = true
  else:
    buffer.cursorDown()

proc scrollUp*(buffer: Buffer) =
  if buffer.fromy > 0:
    dec buffer.cpos.fromy
    if buffer.fromy + buffer.height <= buffer.cursory:
      buffer.cursorUp()
    buffer.redraw = true
  else:
    buffer.cursorUp()

proc scrollRight*(buffer: Buffer) =
  if buffer.fromx + buffer.width < buffer.maxScreenWidth():
    inc buffer.cpos.fromx
    buffer.redraw = true

proc scrollLeft*(buffer: Buffer) =
  if buffer.fromx > 0:
    dec buffer.cpos.fromx
    if buffer.cursorx < buffer.fromx:
      buffer.setCursorX(max(buffer.currentLineWidth() - 1, 0))
    buffer.redraw = true

proc gotoAnchor*(buffer: Buffer) =
  let anchor = buffer.document.getElementById(buffer.location.anchor)
  if anchor == nil: return
  for y in 0..(buffer.numLines - 1):
    let line = buffer.lines[y]
    var i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      if format.node != nil and anchor in format.node.node:
        buffer.setCursorY(y)
        buffer.centerLine()
        buffer.setCursorX(format.pos)
        return
      inc i

proc addMark*(buffer: Buffer, x, y, width: int): Mark =
  assert y < buffer.lines.len
  var format = newFormat()
  format.reverse = true
  result = Mark(x: x, width: width, format: format)
  buffer.lines[y].marks.add(result)

proc removeMark*(buffer: Buffer, y: int, mark: Mark) =
  let i = buffer.lines[y].marks.find(mark)
  if i != -1:
    buffer.lines[y].marks.delete(i)

proc cursorNextMatch(buffer: Buffer, regex: Regex, sy, ey: int, wrap = false): BufferMatch =
  for y in sy..ey:
    let s = if y == buffer.cursory and not wrap:
      buffer.currentCursorBytes(buffer.fromx + buffer.cursorx + 1)
    else:
      0
    let res = regex.exec(buffer.lines[y].str, s)
    if res.success and res.captures.len > 0:
      let cap = res.captures[0]
      let x = buffer.lines[y].str.width(cap.s)
      buffer.setCursorXY(x, y)
      result.success = true
      result.y = y
      result.x = x
      result.str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
      return

proc cursorNextMatch*(buffer: Buffer, regex: Regex, wrap = true): BufferMatch =
  let s = buffer.currentCursorBytes(buffer.fromx + buffer.cursorx + 1)
  var low = buffer.cursory
  if s == buffer.lines.len:
    low += 1
  if low > buffer.lines.high:
    low = 0
  let ret = buffer.cursorNextMatch(regex, low, buffer.lines.high)
  if ret.success:
    return ret
  if wrap:
    return buffer.cursorNextMatch(regex, 0, low, true)

proc cursorPrevMatch*(buffer: Buffer, regex: Regex, sy, ey: int, wrap = false): BufferMatch =
  for y in countdown(sy, ey):
    let e = if y == buffer.cursory and not wrap:
      buffer.currentCursorBytes()
    else:
      buffer.lines[y].str.len + 1
    let res = regex.exec(buffer.lines[y].str)
    if res.success:
      for i in countdown(res.captures.high, 0):
        let cap = res.captures[i]
        if cap.s < e:
          let x = buffer.lines[y].str.width(cap.s)
          buffer.setCursorXY(x, y)
          result.success = true
          result.y = y
          result.x = x
          result.str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
          return

proc cursorPrevMatch*(buffer: Buffer, regex: Regex, wrap = true): BufferMatch =
  var high = buffer.cursory
  if buffer.fromx + buffer.cursorx - 1 < 0:
    high -= 1
  if high < 0:
    high = buffer.lines.high
  let ret = buffer.cursorPrevMatch(regex, high, 0)
  if ret.success:
    return ret
  if wrap:
    return buffer.cursorPrevMatch(regex, buffer.lines.high, high)

proc refreshTermAttrs*(buffer: Buffer): bool =
  let newAttrs = getTermAttributes()
  if newAttrs != buffer.attrs:
    buffer.attrs = newAttrs
    buffer.width = newAttrs.width
    buffer.height = newAttrs.height - 1
    return true
  return false

proc updateCursor(buffer: Buffer) =
  if buffer.fromy > buffer.lastVisibleLine - 1:
    buffer.cpos.fromy = 0
    buffer.cpos.cursory = buffer.lastVisibleLine - 1

  if buffer.lines.len == 0:
    buffer.cpos.cursory = 0

proc updateHover(buffer: Buffer) =
  let thisnode = buffer.currentDisplayCell().node
  let prevnode = buffer.prevnode

  if thisnode != prevnode and (thisnode == nil or prevnode == nil or thisnode.node != prevnode.node):
    for styledNode in thisnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if not elem.hover:
          elem.hover = true
          buffer.reshape = true

    let link = thisnode.getLink()
    if link != nil:
      buffer.hovertext = link.href
    else:
      buffer.hovertext = ""

    for styledNode in prevnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if elem.hover:
          elem.hover = false
          buffer.reshape = true

  buffer.prevnode = thisnode

proc loadResources(buffer: Buffer, document: Document) =
  var stack: seq[Element]
  if document.html != nil:
    stack.add(document.html)
  while stack.len > 0:
    let elem = stack.pop()

    if elem.tagType == TAG_LINK:
      let elem = HTMLLinkElement(elem)
      if elem.rel == "stylesheet":
        let url = parseUrl(elem.href, document.location.some)
        if url.issome:
          if url.get.scheme == buffer.location.scheme:
            let res = buffer.loader.getPage(url.get)
            if res.s != nil and res.contenttype == "text/css":
              let sheet = parseStylesheet(res.s)
              elem.sheet = sheet

    for child in elem.children_rev:
      stack.add(child)

proc load*(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if not buffer.streamclosed:
      buffer.source = buffer.istream.readAll()
      buffer.istream.close()
      buffer.istream = newStringStream(buffer.source)
      buffer.document = parseHTML5(buffer.istream)
      buffer.streamclosed = true
    else:
      buffer.document = parseHTML5(newStringStream(buffer.source))
    buffer.document.location = buffer.location
    buffer.loadResources(buffer.document)
  else:
    if not buffer.streamclosed:
      buffer.source = buffer.istream.readAll()
      buffer.istream.close()
      buffer.streamclosed = true
    buffer.lines = renderPlainText(buffer.source)

proc render*(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if buffer.viewport == nil:
      buffer.viewport = Viewport(term: buffer.attrs)
    let ret = renderDocument(buffer.document, buffer.attrs, buffer.userstyle, buffer.viewport, buffer.prevstyled)
    buffer.lines = ret[0]
    buffer.prevstyled = ret[1]
  else: discard
  buffer.updateCursor()

proc cursorBufferPos(buffer: Buffer) =
  let x = buffer.acursorx
  let y = buffer.acursory
  print(HVP(y + 1, x + 1))

proc clearStatusMessage(buffer: Buffer) =
  buffer.statusmsg = newFixedGrid(buffer.width)

proc writeStatusMessage(buffer: Buffer, str: string, format: Format = Format()) =
  buffer.clearStatusMessage()
  var i = 0
  for r in str.runes:
    i += r.width()
    if i >= buffer.statusmsg.len:
      buffer.statusmsg[^1].runes.setLen(0)
      buffer.statusmsg[^1].runes.add(Rune('$'))
      break
    buffer.statusmsg[i].runes.add(r)
    buffer.statusmsg[i].format = format

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = $(buffer.cursory + 1) & "/" & $buffer.numLines & " (" &
            $buffer.atPercentOf() & "%) " & "<" & buffer.title & ">"
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  var format: Format
  format.reverse = true
  buffer.writeStatusMessage(msg, format)

proc setStatusMessage*(buffer: Buffer, str: string) =
  buffer.writeStatusMessage(str)
  buffer.nostatus = true

proc lineInfo*(buffer: Buffer) =
    buffer.setStatusMessage("line " & $(buffer.cursory + 1) & "/" & $buffer.numLines & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth() & " x: " & $buffer.currentCursorBytes())

proc displayBufferSwapOutput(buffer: Buffer) =
  print(buffer.generateSwapOutput())

proc displayBuffer(buffer: Buffer) =
  print(buffer.generateFullOutput())

proc displayStatusMessage*(buffer: Buffer) =
  print(HVP(buffer.height + 1, 1))
  print(SGR())
  print(buffer.generateStatusMessage())
  print(SGR())

type
  ClickAction* = object
    url*: string
    httpmethod*: HttpMethod
    mimetype*: string
    body*: string
    multipart*: MultipartData

# https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set
proc constructEntryList(form: HTMLFormElement, submitter: Element = nil, encoding: string = ""): Table[string, string] =
  if form.constructingentrylist:
    return
  form.constructingentrylist = true

  var entrylist: Table[string, string]
  for field in form.controls:
    if field.findAncestor({TAG_DATALIST}) != nil or
        field.attrb("disabled") or
        field.isButton() and Element(field) != submitter:
      continue

    if field.tagType == TAG_INPUT:
      let field = HTMLInputElement(field)
      if field.inputType == INPUT_IMAGE:
        let name = if field.attr("name") != "":
          field.attr("name") & '.'
        else:
          ""
        entrylist[name & 'x'] = $field.xcoord
        entrylist[name & 'y'] = $field.ycoord
        continue

    #TODO custom elements

    let name = field.attr("name")

    if name == "":
      continue

    if field.tagType == TAG_SELECT:
      let field = HTMLSelectElement(field)
      for option in field.options:
        if option.selected or option.disabled:
          entrylist[name] = option.value
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_CHECKBOX, INPUT_RADIO}:
      let value = if field.attr("value") != "":
        field.attr("value")
      else:
        "on"
      entrylist[name] = value
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_FILE:
      #TODO file
      discard
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_HIDDEN and name.equalsIgnoreCase("_charset_"):
      let charset = if encoding != "":
        encoding
      else:
        "UTF-8"
      entrylist[name] = charset
    else:
      if field.tagType == TAG_INPUT:
        entrylist[name] = HTMLInputElement(field).value
      else:
        assert false
    if field.tagType == TAG_TEXTAREA or
        field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_TEXT, INPUT_SEARCH}:
      if field.attr("dirname") != "":
        let dirname = field.attr("dirname")
        let dir = "ltr" #TODO bidi
        entrylist[dirname] = dir

  form.constructingentrylist = false
  return entrylist

#https://url.spec.whatwg.org/#concept-urlencoded-serializer
proc serializeApplicationXWWFormUrlEncoded(kvs: Table[string, string]): string =
  for name, value in kvs:
    if result != "":
      result &= '&'
    result.percentEncode(name, ApplicationXWWWFormUrlEncodedSet, true)
    result &= '='
    result.percentEncode(value, ApplicationXWWWFormUrlEncodedSet, true)

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc makeCRLF(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len - 1:
    if s[i] == '\r' and s[i + 1] != '\n':
      result &= '\r'
      result &= '\n'
    elif s[i] != '\r' and s[i + 1] == '\n':
      result &= s[i]
      result &= '\r'
      result &= '\n'
      inc i
    else:
      result &= s[i]
    inc i

proc serializeMultipartFormData(kvs: Table[string, string]): MultipartData =
  new(result)
  for name, value in kvs:
    let name = makeCRLF(name)
    let value = makeCRLF(value)
    result[name] = value

proc serializePlainTextFormData(kvs: Table[string, string]): string =
  for name, value in kvs:
    result &= name
    result &= '='
    result &= value
    result &= '\r'
    result &= '\n'

proc submitForm(form: HTMLFormElement, submitter: Element): Option[ClickAction] =
  let entrylist = form.constructEntryList(submitter)

  let action = if submitter.action() == "":
    $form.document.location
  else:
    submitter.action()

  let url = parseUrl(action, submitter.document.baseUrl.some)
  if url.isnone:
    return none(ClickAction)

  var parsedaction = url.get
  let scheme = parsedaction.scheme
  let enctype = submitter.enctype()
  let formmethod = submitter.formmethod()
  if formmethod == FORM_METHOD_DIALOG:
    #TODO
    return none(ClickAction)
  let httpmethod = if formmethod == FORM_METHOD_GET:
    HttpGet
  else:
    assert formmethod == FORM_METHOD_POST
    HttpPost

  #let target = if submitter.isSubmitButton() and submitter.attrb("formtarget"):
  #  submitter.attr("formtarget")
  #else:
  #  submitter.target()
  #let noopener = true #TODO

  template mutateActionUrl() =
    let query = serializeApplicationXWWFormUrlEncoded(entrylist)
    parsedaction.query = query.some
    return ClickAction(url: $parsedaction, httpmethod: httpmethod).some

  template submitAsEntityBody() =
    var body: string
    var mimetype: string
    var multipart: MultipartData
    case enctype
    of FORM_ENCODING_TYPE_URLENCODED:
      body = serializeApplicationXWWFormUrlEncoded(entrylist)
      mimeType = $enctype
    of FORM_ENCODING_TYPE_MULTIPART:
      multipart = serializeMultipartFormData(entrylist) 
      mimetype = $enctype
    of FORM_ENCODING_TYPE_TEXT_PLAIN:
      body = serializePlainTextFormData(entrylist)
      mimetype = $enctype
    return ClickAction(url: $parsedaction, httpmethod: httpmethod, body: body, mimetype: mimetype, multipart: multipart).some

  template getActionUrl() =
    return ClickAction(url: $parsedaction).some

  case scheme
  of "http", "https":
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      submitAsEntityBody
  of "ftp":
    getActionUrl
  of "data":
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      getActionUrl

proc click*(buffer: Buffer): Option[ClickAction] =
  let clickable = buffer.getCursorClickable()
  if clickable != nil:
    case clickable.tagType
    of TAG_A:
      return ClickAction(url: HTMLAnchorElement(clickable).href, httpmethod: HttpGet).some
    of TAG_INPUT:
      let input = HTMLInputElement(clickable)
      case input.inputType
      of INPUT_SEARCH:
        var value = input.value
        print(HVP(buffer.height + 1, 1))
        print(EL())
        let status = readLine("SEARCH: ", value, buffer.width, {'\r', '\n'})
        if status:
          input.value = value
          input.invalid = true
          buffer.reshape = true
        if input.form != nil:
          let submitaction = submitForm(input.form, input)
          return submitaction
      of INPUT_TEXT, INPUT_PASSWORD:
        var value = input.value
        print(HVP(buffer.height + 1, 1))
        print(EL())
        let status = readLine("TEXT: ", value, buffer.width, {'\r', '\n'})
        if status:
          input.value = value
          input.invalid = true
          buffer.reshape = true
      of INPUT_FILE:
        var path = if input.file.issome:
          input.file.get.path.serialize_unicode()
        else:
          ""
        print(HVP(buffer.height + 1, 1))
        print(EL())
        let status = readLine("Filename: ", path, buffer.width, {'\r', '\n'})
        if status:
          let cdir = parseUrl("file://" & getCurrentDir() & DirSep)
          let path = parseUrl(path, cdir)
          if path.issome:
            input.file = path
            input.invalid = true
            buffer.reshape = true
      of INPUT_CHECKBOX:
        input.checked = not input.checked
        input.invalid = true
        buffer.reshape = true
      of INPUT_RADIO:
        for radio in input.radiogroup:
          radio.checked = false
          radio.invalid = true
        input.checked = true
        input.invalid = true
        buffer.reshape = true
      of INPUT_RESET:
        if input.form != nil:
          input.form.reset()
          buffer.reshape = true
      of INPUT_SUBMIT, INPUT_BUTTON:
        if input.form != nil:
          let submitaction = submitForm(input.form, input)
          return submitaction
      else:
        discard
    else:
      discard

proc drawBuffer*(buffer: Buffer) =
  var format = newFormat()
  for line in buffer.lines:
    if line.formats.len == 0:
      print(line.str & '\n')
    else:
      var x = 0
      var i = 0
      for f in line.formats:
        var outstr = ""
        assert f.pos < line.str.width(), "fpos " & $f.pos & "\nstr" & line.str & "\n"
        while x < f.pos:
          var r: Rune
          fastRuneAt(line.str, i, r)
          outstr &= r
          x += r.width()
        print(outstr)
        print(format.processFormat(f.format))
      print(line.str.substr(i))
      print(format.processFormat(newFormat()))
      print('\n')

proc refreshBuffer*(buffer: Buffer, peek = false) =
  buffer.title = buffer.getTitle()
  stdout.hideCursor()

  if buffer.refreshTermAttrs():
    buffer.redraw = true
    buffer.reshape = true

  if buffer.redraw:
    buffer.refreshDisplay()
    buffer.displayBuffer()
    buffer.redraw = false

  buffer.updateHover()
  if buffer.reshape:
    buffer.render()
    buffer.reshape = false
    buffer.refreshDisplay()
    buffer.displayBufferSwapOutput()

  if not peek:
    if not buffer.nostatus:
      buffer.statusMsgForBuffer()
    else:
      buffer.nostatus = false
    buffer.displayStatusMessage()
    buffer.cursorBufferPos()
  stdout.showCursor()
