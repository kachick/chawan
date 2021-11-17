import terminal
import uri
import strutils
import unicode

import types/enums
import css/style
import utils/twtstr
import html/dom
import layout/box
import config/config
import io/term
import io/lineedit
import io/cell
import layout/engine

type
  Buffer* = ref BufferObj
  BufferObj = object
    title*: string
    lines*: FlexibleGrid
    display*: FixedGrid
    prevdisplay*: FixedGrid
    statusmsg*: FixedGrid
    hovertext*: string
    width*: int
    height*: int
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    attrs*: TermAttributes
    document*: Document
    displaycontrols*: bool
    redraw*: bool
    reshape*: bool
    location*: Uri
    source*: string
    showsource*: bool
    rootbox*: CSSBox
    prevnodes*: seq[Node]

func newBuffer*(attrs: TermAttributes): Buffer =
  new(result)
  result.width = attrs.width
  result.height = attrs.height - 1
  result.attrs = attrs

  result.display = newFixedGrid(result.width, result.height)
  result.prevdisplay = newFixedGrid(result.width, result.height)
  result.statusmsg = newFixedGrid(result.width)

func generateFullOutput*(buffer: Buffer): seq[string] =
  var x = 0
  var y = 0
  var s = ""
  var formatting = newFormatting()

  for cell in buffer.display:
    if x >= buffer.width:
      inc y
      result.add(s)
      x = 0
      s = ""

    s &= formatting.processFormatting(cell.formatting)

    s &= $cell.runes
    inc x

  result.add(s)

# generate a sequence of instructions to replace the previous frame with the
# current one. ideally should be used when small changes are made (e.g. hover
# changes underlining)
func generateSwapOutput*(buffer: Buffer): string =
  var formatting = newFormatting()

  let max = buffer.width * buffer.height
  let curr = buffer.display
  let prev = buffer.prevdisplay
  var x = 0
  var y = 0
  var cx = -1
  var cy = -1
  var i = 0
  var text = ""
  while i < max:
    if x >= buffer.width:
      x = 0
      inc y

    if curr[i] != prev[i]:
      let currwidth = curr[i].runes.width()
      let prevwidth = prev[i].runes.width()
      if (curr[i].runes.len > 0 or currwidth < prevwidth) and (x != cx or y != cy):
        if text.len > 0:
          result &= text
          text = ""
        result &= HVP(y + 1, x + 1)
        cx = x
        cy = y

      text &= formatting.processFormatting(curr[i].formatting)

      text &= $curr[i].runes
      if currwidth < prevwidth:
        var j = 0
        while j < prevwidth - currwidth:
          text &= ' '
          inc j
      if text.len > 0:
        inc cx

    inc x
    inc i
  if text.len > 0:
    result &= $text

func generateStatusMessage*(buffer: Buffer): string =
  for cell in buffer.statusmsg:
    for r in cell.runes:
      if r != Rune(0):
        result &= $r

func numLines*(buffer: Buffer): int = buffer.lines.len

func lastVisibleLine*(buffer: Buffer): int = min(buffer.fromy + buffer.height, buffer.numLines)

func acursorx(buffer: Buffer): int =
  return max(0, buffer.cursorx - buffer.fromx)

func acursory(buffer: Buffer): int =
  return buffer.cursory - buffer.fromy

func cellOrigin(buffer: Buffer, x: int, y: int): int =
  let row = y * buffer.width
  var ox = x
  while buffer.display[row + ox].runes.len == 0 and ox > 0:
    dec ox
  return ox

func currentCellOrigin(buffer: Buffer): int =
  return buffer.cellOrigin(buffer.acursorx, buffer.acursory)

#TODO counter-intuitive naming?
func currentCell(buffer: Buffer): FixedCell =
  let row = (buffer.cursory - buffer.fromy) * buffer.width
  return buffer.display[row + buffer.currentCellOrigin()]

func currentRune(buffer: Buffer): Rune =
  let cell = buffer.currentCell()
  if cell.runes.len == 0:
    return Rune(' ')
  return cell.runes[0]

func getCursorLink(buffer: Buffer): Element =
  let nodes = buffer.currentCell().nodes
  for node in nodes:
    if node.nodeType == ELEMENT_NODE:
      let elem = Element(node)
      if elem.tagType == TAG_A:
        return elem
  return nil

func currentLineWidth*(buffer: Buffer): int =
  if buffer.cursory > buffer.lines.len:
    return 0
  return buffer.lines[buffer.cursory].width()

func maxScreenWidth*(buffer: Buffer): int =
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine - 1]:
    result = max(line.width(), result)

func atPercentOf*(buffer: Buffer): int =
  if buffer.lines.len == 0: return 100
  return (100 * (buffer.cursory + 1)) div buffer.numLines

func canScroll*(buffer: Buffer): bool =
  return buffer.numLines >= buffer.height

proc addLine(buffer: Buffer) =
  buffer.lines.addLine()

proc clearText*(buffer: Buffer) =
  buffer.lines.setLen(0)
  buffer.addLine()

proc clearBuffer*(buffer: Buffer) =
  buffer.clearText()
  buffer.cursorx = 0
  buffer.cursory = 0
  buffer.fromx = 0
  buffer.fromy = 0
  buffer.hovertext = ""

proc clearDisplay*(buffer: Buffer) =
  buffer.prevdisplay = buffer.display
  buffer.display = newFixedGrid(buffer.width, buffer.height)

proc refreshDisplay*(buffer: Buffer) =
  var r: Rune
  var y = 0
  buffer.clearDisplay()

  for line in buffer.lines[buffer.fromy..
                           buffer.lastVisibleLine - 1]:
    var w = 0
    var i = 0
    var j = 0
    while w < buffer.fromx and i < line.len:
      fastRuneAt(line.str, i, r)
      w += r.width()
      inc j

    let dls = y * buffer.width
    var k = 0
    var n = 0
    var cf = line.findFormat(j)
    var nf = line.findNextFormat(j)
    while w < buffer.fromx + buffer.width and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.width()
      if nf.pos != -1 and nf.pos <= j:
        cf = nf
        nf = line.findNextFormat(j)
      if r.width() == 0 and k != 0:
        inc n
      buffer.display[dls + k - n].runes.add(r)
      if cf.pos != -1:
        buffer.display[dls + k - n].formatting = cf.formatting
        buffer.display[dls + k - n].nodes = cf.nodes
      k += r.width()
      inc j

    inc y


proc restoreCursorX(buffer: Buffer) =
  buffer.cursorx = max(min(buffer.currentLineWidth() - 1, buffer.xend), 0)

proc scrollTo*(buffer: Buffer, y: int) =
  if y == buffer.fromy:
    return
  buffer.fromy = min(max(buffer.numLines - buffer.height, 0), y)
  buffer.cursory = min(max(buffer.fromy, buffer.cursory), buffer.fromy + buffer.height)
  buffer.redraw = true
  buffer.restoreCursorX()

proc cursorTo*(buffer: Buffer, x: int, y: int) =
  buffer.redraw = false
  buffer.cursory = min(max(y, 0), buffer.numLines - 1)
  if buffer.fromy > buffer.cursory:
    buffer.fromy = max(buffer.cursory, 0)
    buffer.redraw = true
  elif buffer.fromy + buffer.height - 1 <= buffer.cursory:
    buffer.fromy = max(buffer.cursory - buffer.height + 1, 0)
    buffer.redraw = true

  buffer.cursorx = min(max(x, 0), buffer.currentLineWidth())
  if buffer.fromx < buffer.cursorx - buffer.width:
    buffer.fromx = max(0, buffer.cursorx - buffer.width)
    buffer.redraw = true
  elif buffer.fromx > buffer.cursorx:
    buffer.fromx = buffer.cursorx
    buffer.redraw = true

proc cursorDown*(buffer: Buffer) =
  if buffer.cursory < buffer.numLines - 1:
    inc buffer.cursory
    buffer.restoreCursorX()
    if buffer.cursory - buffer.height >= buffer.fromy:
      inc buffer.fromy
      buffer.redraw = true

proc cursorUp*(buffer: Buffer) =
  if buffer.cursory > 0:
    dec buffer.cursory
    buffer.restoreCursorX()
    if buffer.cursory < buffer.fromy:
      dec buffer.fromy
      buffer.redraw = true

proc cursorRight*(buffer: Buffer) =
  let cellwidth = max(buffer.currentCell().width(), 1)
  let cellorigin = buffer.fromx + buffer.currentCellOrigin()
  let lw = buffer.currentLineWidth()
  if buffer.cursorx < lw - 1:
    buffer.cursorx = min(lw - 1, cellorigin + cellwidth)
    assert buffer.cursorx >= 0
    buffer.xend = buffer.cursorx
    if buffer.cursorx - buffer.width >= buffer.fromx:
      inc buffer.fromx
      buffer.redraw = true
    if buffer.cursorx == buffer.fromx:
      inc buffer.cursorx

proc cursorLeft*(buffer: Buffer) =
  let cellorigin = buffer.fromx + buffer.currentCellOrigin()
  let lw = buffer.currentLineWidth()
  if buffer.fromx > buffer.cursorx:
    buffer.cursorx = min(max(lw - 1, 0), cellorigin - 1)
    buffer.fromx = buffer.cursorx
    buffer.redraw = true
  elif buffer.cursorx > 0:
    buffer.cursorx = max(0, cellorigin - 1)
    if buffer.fromx > buffer.cursorx:
      buffer.fromx = buffer.cursorx
      buffer.redraw = true

  buffer.xend = buffer.cursorx

proc cursorLineBegin*(buffer: Buffer) =
  buffer.cursorx = 0
  buffer.xend = 0
  if buffer.fromx > 0:
    buffer.fromx = 0
    buffer.redraw = true

proc cursorLineEnd*(buffer: Buffer) =
  buffer.cursorx = max(buffer.currentLineWidth() - 1, 0)
  buffer.xend = buffer.cursorx
  buffer.fromx = max(buffer.cursorx - buffer.width + 1, 0)
  buffer.redraw = buffer.fromx > 0

proc cursorNextWord*(buffer: Buffer) =
  let llen = buffer.currentLineWidth() - 1
  if llen >= 0:
    while not buffer.currentRune().breaksWord():
      if buffer.cursorx >= llen:
        break
      buffer.cursorRight()

    while buffer.currentRune().breaksWord():
      if buffer.cursorx >= llen:
        break
      buffer.cursorRight()

  if buffer.cursorx >= buffer.currentLineWidth() - 1:
    if buffer.cursory < buffer.numLines - 1:
      buffer.cursorDown()
      buffer.cursorLineBegin()

proc cursorPrevWord*(buffer: Buffer) =
  if buffer.currentLineWidth() > 0:
    while not buffer.currentRune().breaksWord():
      if buffer.cursorx == 0:
        break
      buffer.cursorLeft()

    while buffer.currentRune().breaksWord():
      if buffer.cursorx == 0:
        break
      buffer.cursorLeft()

  if buffer.cursorx == 0:
    if buffer.cursory > 0:
      buffer.cursorUp()
      buffer.cursorLineEnd()

#TODO this is sloooooow
#proc cursorRightOverflow(buffer: Buffer) =
#  buffer.cursorRight()
#  if buffer.cursorx >= buffer.currentLineWidth() - 1 and buffer.cursory < buffer.numLines - 1:
#    buffer.cursorDown()
#    buffer.cursorLineBegin()
#  buffer.refreshDisplay()
#
#proc cursorLeftOverflow(buffer: Buffer) =
#  buffer.cursorLeft()
#  if buffer.cursorx <= 0 and buffer.cursory > 0:
#    buffer.cursorUp()
#    buffer.cursorLineEnd()
#  buffer.refreshDisplay()

proc cursorNextLink*(buffer: Buffer) =
  #TODO
  #let ocx = buffer.cursorx
  #let ocy = buffer.cursory
  #let ofx = buffer.fromx
  #let ofy = buffer.fromy
  #let elem = buffer.getCursorLink()
  #if elem != nil:
  #  while buffer.getCursorLink() == elem:
  #    buffer.cursorRightOverflow()
  #    if buffer.cursorx >= buffer.currentLineWidth() - 1 and
  #        buffer.cursory >= buffer.numLines - 1:
  #      buffer.cursorx = ocx
  #      buffer.cursory = ocy
  #      buffer.fromx = ofx
  #      buffer.fromy = ofy
  #      break

  #while buffer.getCursorLink() == nil:
  #  buffer.cursorRightOverflow()
  #  if buffer.cursorx >= buffer.currentLineWidth() - 1 and
  #      buffer.cursory >= buffer.numLines - 1:
  #    buffer.cursorx = ocx
  #    buffer.cursory = ocy
  #    buffer.fromx = ofx
  #    buffer.fromy = ofy
  #    break
  discard

proc cursorPrevLink*(buffer: Buffer) =
  #TODO
  return

proc cursorFirstLine*(buffer: Buffer) =
  if buffer.fromy > 0:
    buffer.fromy = 0
    buffer.redraw = true
  else:
    buffer.redraw = false

  buffer.cursory = 0
  buffer.restoreCursorX()

proc cursorLastLine*(buffer: Buffer) =
  if buffer.fromy < buffer.numLines - buffer.height:
    buffer.fromy = buffer.numLines - buffer.height
    buffer.redraw = true
  buffer.cursory = buffer.numLines - 1
  buffer.restoreCursorX()

proc cursorTop*(buffer: Buffer) =
  buffer.cursory = buffer.fromy
  buffer.restoreCursorX()

proc cursorMiddle*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + (buffer.height - 2) div 2, buffer.numLines - 1)
  buffer.restoreCursorX()

proc cursorBottom*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + buffer.height - 1, buffer.numLines - 1)
  buffer.restoreCursorX()

proc centerLine*(buffer: Buffer) =
  let ny = max(min(buffer.cursory - buffer.height div 2, buffer.numLines - buffer.height), 0)
  if ny != buffer.fromy:
    buffer.fromy = ny
    buffer.redraw = true

proc halfPageUp*(buffer: Buffer) =
  buffer.cursory = max(buffer.cursory - buffer.height div 2 + 1, 0)
  let nfy = max(0, buffer.fromy - buffer.height div 2 + 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc halfPageDown*(buffer: Buffer) =
  buffer.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.numLines - 1)
  let nfy = min(max(buffer.numLines - buffer.height, 0), buffer.fromy + buffer.height div 2 - 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageUp*(buffer: Buffer) =
  buffer.cursory = max(buffer.cursory - buffer.height, 0)
  let nfy = max(0, buffer.fromy - buffer.height)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageDown*(buffer: Buffer) =
  buffer.cursory = min(buffer.cursory + buffer.height, buffer.numLines - 1)
  let nfy = min(buffer.fromy + buffer.height, max(buffer.numLines - buffer.height, 0))
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageLeft*(buffer: Buffer) =
  buffer.cursorx = max(buffer.cursorx - buffer.width, 0)
  let nfx = max(0, buffer.fromx - buffer.width)
  if nfx != buffer.fromx:
    buffer.fromx = nfx
    buffer.redraw = true

proc pageRight*(buffer: Buffer) =
  buffer.cursorx = min(buffer.fromx, buffer.currentLineWidth())
  let nfx = min(max(buffer.maxScreenWidth() - buffer.width, 0), buffer.fromx + buffer.width)
  if nfx != buffer.fromx:
    buffer.fromx = nfx
    buffer.redraw = true

proc scrollDown*(buffer: Buffer) =
  if buffer.fromy + buffer.height < buffer.numLines:
    inc buffer.fromy
    if buffer.fromy > buffer.cursory:
      buffer.cursorDown()
    buffer.redraw = true
  else:
    buffer.cursorDown()

proc scrollUp*(buffer: Buffer) =
  if buffer.fromy > 0:
    dec buffer.fromy
    if buffer.fromy + buffer.height <= buffer.cursory:
      buffer.cursorUp()
    buffer.redraw = true
  else:
    buffer.cursorUp()

proc scrollRight*(buffer: Buffer) =
  if buffer.fromx + buffer.width < buffer.maxScreenWidth():
    inc buffer.fromx
    if buffer.fromx >= buffer.cursorx:
      buffer.cursorRight()
    buffer.redraw = true

proc scrollLeft*(buffer: Buffer) =
  if buffer.fromx > 0:
    dec buffer.fromx
    if buffer.fromx + buffer.height <= buffer.cursorx:
      buffer.cursorLeft()
    buffer.redraw = true

proc gotoAnchor*(buffer: Buffer): bool =
  discard
  #TODO
  #if buffer.location.anchor != "":
  #  let node =  buffer.getElementById(buffer.location.anchor)
  #  if node != nil:
  #    buffer.scrollTo(max(node.y - buffer.height div 2, 0))

proc setLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = uri

proc gotoLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = buffer.location.combine(uri)

proc refreshTermAttrs*(buffer: Buffer): bool =
  let newAttrs = getTermAttributes()
  if newAttrs != buffer.attrs:
    buffer.attrs = newAttrs
    buffer.width = newAttrs.width
    buffer.height = newAttrs.height - 1
    return true
  return false

func formatFromLine(line: CSSRowBox): Formatting =
  result.fgcolor = line.color.cellColor()
  if line.fontstyle in { FONT_STYLE_ITALIC, FONT_STYLE_OBLIQUE }:
    result.italic = true
  if line.fontweight > 500:
    result.bold = true
  if line.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline = true
  if line.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline = true
  if line.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike = true

proc setRowBox(buffer: Buffer, line: CSSRowBox) =
  var r: Rune

  let x = line.x
  let y = line.y

  while buffer.lines.len <= y:
    buffer.addLine()

  var i = 0
  var j = 0
  var cx = 0
  while cx < x and i < buffer.lines[y].str.len:
    fastRuneAt(buffer.lines[y].str, i, r)
    cx += r.width()
    inc j

  let ostr = buffer.lines[y].str.substr(i)
  let oformats = buffer.lines[y].formats.subformats(j)
  buffer.lines[y].str.setLen(i)
  buffer.lines[y].setLen(j)

  buffer.lines.addFormat(y, j, line.formatFromLine(), line.nodes)

  var nx = cx
  if nx < x:
    buffer.lines[y].str &= ' '.repeat(x - nx)
    nx = x

  buffer.lines[y].str &= line.str
  nx += line.str.width()

  i = 0
  j = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()
    inc j

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(j))
    buffer.lines[y].add(oline)

proc updateCursor(buffer: Buffer) =
  if buffer.fromy > buffer.lastVisibleLine - 1:
    buffer.fromy = 0
    buffer.cursory = buffer.lastVisibleLine - 1

  if buffer.cursorx >= buffer.currentLineWidth() - 1:
    buffer.cursorx = max(buffer.currentLineWidth() - 1, 0)
    buffer.fromx = max(buffer.cursorx - buffer.width + 1, 0)

  if buffer.lines.len == 0:
    buffer.cursory = 0

#TODO this works, but needs rethinking:
#* reshape is called every time the cursor moves onto or off a line box, which
#  practically means we're re-interpreting all style-sheets AND re-applying all
#  rules way too often
#* reshape also calls redraw so the entire window gets re-painted too which
#  looks pretty bad (tick)
#* and finally it re-arranges all CSS boxes too, which is a rather
#  resource-intensive operation
#overall the second point is the easiest to solve, then the first and finally
#the last (there's only so much you can do in a flow layout, especially with
#the current layout engine)
proc updateHover(buffer: Buffer) =
  let nodes = buffer.currentCell().nodes
  if nodes != buffer.prevnodes:
    for node in nodes:
      if not node.hover:
        node.hover = true
        buffer.reshape = true
    for node in buffer.prevnodes:
      if node.hover and not (node in nodes):
        node.hover = false
        buffer.reshape = true
  buffer.prevnodes = nodes

proc renderPlainText*(buffer: Buffer, text: string) =
  buffer.clearText()
  var i = 0
  var x = 0
  var y = 0
  var r: Rune
  var format = newFormatting()
  while i < text.len:
    if text[i] == '\n':
      if i != text.len - 1:
        buffer.addLine()
        buffer.lines.addFormat(buffer.lines.len - 1, format)
        inc y
        x = 0
      inc i
    elif text[i] == '\r':
      inc i
    elif text[i] == '\t':
      for i in 0..8:
        buffer.lines[^1].str &= ' '
      inc i
    elif text[i] == '\e':
      i = format.parseAnsiCode(text, i)
    elif text[i].isControlChar():
      buffer.lines.addCell(Rune('^'))
      buffer.lines.addCell(Rune(text[i].getControlLetter()))
      inc i
    else:
      fastRuneAt(text, i, r)
      buffer.lines.addCell(r)
  buffer.updateCursor()

proc renderDocument*(buffer: Buffer) =
  buffer.clearText()
  buffer.document.applyStylesheets()
  buffer.rootbox = buffer.document.alignBoxes(buffer.width, buffer.height)
  if buffer.rootbox == nil:
    return
  var stack: seq[CSSBox]
  stack.add(buffer.rootbox)
  while stack.len > 0:
    let box = stack.pop()
    if box of CSSInlineBox:
      let inline = CSSInlineBox(box)
      #eprint "NEW BOX", inline.context.conty
      for line in inline.content:
        #eprint line
        buffer.setRowBox(line)

    var i = box.children.len - 1
    while i >= 0:
      stack.add(box.children[i])
      dec i
  buffer.updateCursor()

proc reshapeBuffer*(buffer: Buffer) =
  #TODO
  #buffer.statusmsg = newFixedGrid(buffer.width)
  if buffer.showsource:
    buffer.renderPlainText(buffer.source)
  else:
    buffer.renderDocument()

proc cursorBufferPos(buffer: Buffer) =
  let x = max(buffer.cursorx - buffer.fromx, 0)
  let y = buffer.cursory - buffer.fromy
  termGoto(x, y)

proc clearStatusMessage(buffer: Buffer) =
  buffer.statusmsg = newFixedGrid(buffer.width)

proc setStatusMessage*(buffer: Buffer, str: string) =
  buffer.clearStatusMessage()
  let text = str.toRunes()
  var i = 0
  var n = 0
  while i < text.len:
    if text[i].width() == 0:
      inc n
    buffer.statusmsg[i - n].runes.add(text[i])
    inc i

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = ($(buffer.cursory + 1) & "/" & $buffer.numLines & " (" &
            $buffer.atPercentOf() & "%) " &
            "<" & buffer.title & ">").ansiStyle(styleReverse).ansiReset().join()
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  buffer.setStatusMessage(msg)

proc displayBufferSwapOutput(buffer: Buffer) =
  print(buffer.generateSwapOutput())

proc displayBuffer(buffer: Buffer) =
  termGoto(0, 0)
  let full = buffer.generateFullOutput()
  for line in full:
    print(line)
    print(EL())
    print('\n')

proc displayStatusMessage(buffer: Buffer) =
  termGoto(0, buffer.height)
  print(SGR())
  print(buffer.generateStatusMessage())
  print(EL())

proc inputLoop(attrs: TermAttributes, buffer: Buffer): bool =
  var s = ""
  var feedNext = false
  while true:
    buffer.redraw = false
    buffer.displayStatusMessage()
    stdout.showCursor()
    buffer.cursorBufferPos()
    if not feedNext:
      s = ""
    else:
      feedNext = false


    let c = getch()
    s &= c
    let action = getNormalAction(s)
    var nostatus = false
    case action
    of ACTION_QUIT:
      eraseScreen()
      setCursorPos(0, 0)
      return false
    of ACTION_CURSOR_LEFT: buffer.cursorLeft()
    of ACTION_CURSOR_DOWN: buffer.cursorDown()
    of ACTION_CURSOR_UP: buffer.cursorUp()
    of ACTION_CURSOR_RIGHT: buffer.cursorRight()
    of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
    of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
    of ACTION_CURSOR_NEXT_WORD: buffer.cursorNextWord()
    of ACTION_CURSOR_PREV_WORD: buffer.cursorPrevWord()
    of ACTION_CURSOR_NEXT_LINK: buffer.cursorNextLink()
    of ACTION_CURSOR_PREV_LINK: buffer.cursorPrevLink()
    of ACTION_PAGE_DOWN: buffer.pageDown()
    of ACTION_PAGE_UP: buffer.pageUp()
    of ACTION_PAGE_RIGHT: buffer.pageRight()
    of ACTION_PAGE_LEFT: buffer.pageLeft()
    of ACTION_HALF_PAGE_DOWN: buffer.halfPageDown()
    of ACTION_HALF_PAGE_UP: buffer.halfPageUp()
    of ACTION_CURSOR_FIRST_LINE: buffer.cursorFirstLine()
    of ACTION_CURSOR_LAST_LINE: buffer.cursorLastLine()
    of ACTION_CURSOR_TOP: buffer.cursorTop()
    of ACTION_CURSOR_MIDDLE: buffer.cursorMiddle()
    of ACTION_CURSOR_BOTTOM: buffer.cursorBottom()
    of ACTION_CENTER_LINE: buffer.centerLine()
    of ACTION_SCROLL_DOWN: buffer.scrollDown()
    of ACTION_SCROLL_UP: buffer.scrollUp()
    of ACTION_SCROLL_LEFT: buffer.scrollLeft()
    of ACTION_SCROLL_RIGHT: buffer.scrollRight()
    of ACTION_CLICK:
      discard
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.location

      termGoto(0, buffer.height)
      print(EL())
      let status = readLine("URL: ", url, buffer.width)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_LINE_INFO:
      buffer.setStatusMessage("line " & $(buffer.cursory + 1) & "/" & $buffer.numLines & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth() & " cell width: " & $buffer.currentCell().width())
      nostatus = true
    of ACTION_FEED_NEXT:
      feedNext = true
    of ACTION_RELOAD: return true
    of ACTION_RESHAPE:
      buffer.reshape = true
    of ACTION_REDRAW: buffer.redraw = true
    of ACTION_TOGGLE_SOURCE:
      buffer.showsource = not buffer.showsource
      buffer.reshape = true
      buffer.redraw = true
    else: discard
    stdout.hideCursor()

    if buffer.refreshTermAttrs():
      buffer.redraw = true
      buffer.reshape = true

    if buffer.redraw:
      buffer.refreshDisplay()
      buffer.displayBuffer()
      buffer.redraw = false

    #TODO
    buffer.updateHover()
    if buffer.reshape:
      buffer.reshapeBuffer()
      buffer.reshape = false
      buffer.refreshDisplay()
      buffer.displayBufferSwapOutput()

    if not nostatus:
      buffer.statusMsgForBuffer()
    else:
      nostatus = false

proc displayPage*(attrs: TermAttributes, buffer: Buffer): bool =
  discard buffer.gotoAnchor()
  buffer.refreshDisplay()
  buffer.displayBuffer()
  buffer.statusMsgForBuffer()
  return inputLoop(attrs, buffer)
