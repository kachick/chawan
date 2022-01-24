import options
import streams
import terminal
import unicode

import css/cascade
import css/sheet
import html/dom
import html/tags
import html/parser
import io/cell
import io/loader
import io/term
import layout/box
import render/renderdocument
import render/rendertext
import types/url
import utils/twtstr

type
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
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    attrs*: TermAttributes
    document*: Document
    viewport*: Viewport
    redraw*: bool
    reshape*: bool
    nostatus*: bool
    location*: Url
    ispipe*: bool
    istream*: Stream
    streamclosed*: bool
    source*: string
    rootbox*: CSSBox
    prevnode*: Node
    sourcepair*: Buffer
    prev*: Buffer
    next* {.cursor.}: Buffer
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

func generateFullOutput(buffer: Buffer): string =
  var x = 0
  var w = 0
  var formatting = newFormatting()
  result &= HVP(1, 1)

  for cell in buffer.display:
    if x >= buffer.width:
      result &= EL()
      result &= '\n'
      x = 0
      w = 0

    result &= formatting.processFormatting(cell.formatting)
    result &= $cell.runes

    w += cell.width()
    inc x

  result &= EL()
  result &= '\n'

# generate a sequence of instructions to replace the previous frame with the
# current one. ideally should be used when small changes are made (e.g. hover
# changes underlining)
func generateSwapOutput(buffer: Buffer): string =
  var formatting = newFormatting()
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
    line &= formatting.processFormatting(curr[i].formatting)
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

  #    text &= formatting.processFormatting(curr[i].formatting)

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
  var formatting = newFormatting()
  var w = 0
  for cell in buffer.statusmsg:
    result &= formatting.processFormatting(cell.formatting)
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
  while buffer.display[row + ox].runes.len == 0 and ox > 0:
    dec ox
  return ox

func currentCellOrigin(buffer: Buffer): int =
  return buffer.cellOrigin(buffer.acursorx, buffer.acursory)

func currentDisplayCell(buffer: Buffer): FixedCell =
  let row = (buffer.cursory - buffer.fromy) * buffer.width
  return buffer.display[row + buffer.currentCellOrigin()]

func getLink(node: Node): Element =
  if node == nil:
    return nil
  if node.nodeType == ELEMENT_NODE and Element(node).tagType == TAG_A:
    return Element(node)
  return node.findAncestor({TAG_A})

func getCursorLink(buffer: Buffer): Element =
  return buffer.currentDisplayCell().node.getLink()

func currentLine(buffer: Buffer): string =
  return buffer.lines[buffer.cursory].str

func currentCursorBytes(buffer: Buffer): int =
  let line = buffer.currentLine
  var w = 0
  var i = 0
  let cc = buffer.fromx + buffer.cursorx
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.width()
  return i

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
    let titles = buffer.document.getElementsByTag(TAG_TITLE)
    if titles.len > 0:
      for text in titles[0].textNodes:
        result &= text.data.strip().clearControls()
    return
  if buffer.ispipe:
    result = "*pipe*"
  else:
    result = $buffer.location

proc clearDisplay(buffer: Buffer) =
  buffer.prevdisplay = buffer.display
  buffer.display = newFixedGrid(buffer.width, buffer.height)

proc refreshDisplay(buffer: Buffer) =
  var r: Rune
  var y = 0
  buffer.clearDisplay()

  for line in buffer.lines[buffer.fromy..
                           buffer.lastVisibleLine - 1]:
    var w = 0
    var i = 0
    while w < buffer.fromx and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.width()

    let dls = y * buffer.width
    var k = 0
    var cf = line.findFormat(i)
    var nf = line.findNextFormat(i)
    if w > buffer.fromx:
      while k < w - buffer.fromx:
        buffer.display[dls + k].runes.add(Rune(' '))
        inc k

    while i < line.str.len:
      let j = i
      fastRuneAt(line.str, i, r)
      w += r.width()
      if w > buffer.fromx + buffer.width:
        break
      if nf.pos != -1 and nf.pos <= j:
        cf = nf
        nf = line.findNextFormat(j)
      buffer.display[dls + k].runes.add(r)
      if cf.pos != -1:
        buffer.display[dls + k].formatting = cf.formatting
        buffer.display[dls + k].node = cf.node
      let tk = k + r.width()
      while k < tk and k < buffer.width - 1:
        inc k

    inc y

proc setCursorXB(buffer: Buffer, byte: int) =
  var b = buffer.currentCursorBytes()
  var w = buffer.fromx + buffer.cursorx
  if b < byte:
    while b < byte:
      var r: Rune
      fastRuneAt(buffer.currentLine, b, r)
      w += r.width()
  else:
    while b > byte:
      let (r, o) = lastRune(buffer.currentLine, b)
      w -= r.width()
      b -= o

  let x = w
  if x - buffer.fromx >= 0 and x - buffer.width < buffer.fromx:
    buffer.cursorx = x
  else:
    if x > buffer.cursorx:
      buffer.fromx = max(x - buffer.width + 1, 0)
    elif x < buffer.cursorx:
      buffer.fromx = min(x, buffer.maxfromx)
    buffer.cursorx = x
    buffer.redraw = true
  buffer.xend = buffer.cursorx

proc setCursorX(buffer: Buffer, x: int, refresh = true, save = true) =
  if (not refresh) or (buffer.fromx <= x and x < buffer.fromx + buffer.width):
    buffer.cursorx = x
  else:
    if refresh and buffer.fromx > buffer.cursorx:
      buffer.fromx = max(buffer.currentLineWidth() - 1, 0)
      buffer.cursorx = buffer.fromx
    elif x > buffer.cursorx:
      buffer.fromx = max(x - buffer.width + 1, 0)
      buffer.cursorx = x
    elif x < buffer.cursorx:
      buffer.fromx = x
      buffer.cursorx = x
    buffer.redraw = true
  if save:
    buffer.xend = buffer.cursorx

proc restoreCursorX(buffer: Buffer) =
  buffer.setCursorX(max(min(buffer.currentLineWidth() - 1, buffer.xend), 0), false, false)

proc setCursorY(buffer: Buffer, y: int) =
  if buffer.cursory == y:
    return
  if y - buffer.fromy >= 0 and y - buffer.height < buffer.fromy:
    buffer.cursory = y
  else:
    if y > buffer.cursory:
      buffer.fromy = max(y - buffer.height + 1, 0)
    else:
      buffer.fromy = min(y, buffer.maxfromy)
    buffer.cursory = y
    buffer.redraw = true
  buffer.restoreCursorX()

proc setCursorXY*(buffer: Buffer, x, y: int) =
  buffer.setCursorY(max(min(y, buffer.numLines - 1), 0))
  buffer.setCursorX(max(min(buffer.currentLineWidth(), x), 0))

proc setFromXY*(buffer: Buffer, x, y: int) =
  buffer.fromy = max(min(y, buffer.maxfromy), 0)
  buffer.fromx = max(min(x, buffer.maxfromx), 0)

proc setCursorXBY(buffer: Buffer, x, y: int) =
  buffer.setCursorY(y)
  buffer.setCursorXB(x)

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
  var i = line.findFormatN(buffer.currentCursorBytes()) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getLink()
  inc i

  while i < line.formats.len:
    let format = line.formats[i]
    let fl = format.node.getLink()
    if fl != nil and fl != link:
      buffer.setCursorXB(format.pos)
      return
    inc i

  for y in (buffer.cursory + 1)..(buffer.numLines - 1):
    let line = buffer.lines[y]
    i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      let fl = format.node.getLink()
      if fl != nil and fl != link:
        buffer.setCursorXBY(format.pos, y)
        return
      inc i

proc cursorPrevLink*(buffer: Buffer) =
  let line = buffer.lines[buffer.cursory]
  var i = line.findFormatN(buffer.currentCursorBytes()) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getLink()
  dec i

  while i >= 0:
    let format = line.formats[i]
    let fl = format.node.getLink()
    if fl != nil and fl != link:
      buffer.setCursorXB(format.pos)
      return
    dec i

  for y in countdown(buffer.cursory - 1, 0):
    let line = buffer.lines[y]
    i = line.formats.len - 1
    while i >= 0:
      let format = line.formats[i]
      let fl = format.node.getLink()
      if fl != nil and fl != link:
        #go to beginning of link
        var ly = y #last y
        var lx = format.pos #last x
        for iy in countdown(ly - 1, 0):
          let line = buffer.lines[iy]
          i = line.formats.len - 1
          while i >= 0:
            let format = line.formats[i]
            let nl = format.node.getLink()
            if nl == fl:
              ly = iy
              lx = format.pos
            dec i
        buffer.setCursorXBY(lx, ly)
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
    buffer.redraw = true

proc scrollLeft*(buffer: Buffer) =
  if buffer.fromx > 0:
    dec buffer.fromx
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
      if anchor in format.node:
        buffer.setCursorY(y)
        buffer.centerLine()
        buffer.setCursorXB(format.pos)
        return
      inc i

proc gotoLocation*(buffer: Buffer, s: string) =
  discard parseUrl(s, buffer.location.some, buffer.location, true)

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
    buffer.fromy = 0
    buffer.cursory = buffer.lastVisibleLine - 1

  if buffer.lines.len == 0:
    buffer.cursory = 0

proc updateHover(buffer: Buffer) =
  let thisnode = buffer.currentDisplayCell().node
  let prevnode = buffer.prevnode

  if thisnode != prevnode:
    for node in thisnode.branch:
      if node.nodeType == ELEMENT_NODE:
        let elem = Element(node)
        if not elem.hover and node notin prevnode:
          elem.hover = true
          buffer.reshape = true
          elem.refreshStyle()

    let link = thisnode.getLink()
    if link != nil:
      if link.tagType == TAG_A:
        let anchor = HTMLAnchorElement(link)
        buffer.hovertext = parseUrl(anchor.href, buffer.location.some).serialize()
    else:
      buffer.hovertext = ""

    for node in prevnode.branch:
      if node.nodeType == ELEMENT_NODE:
        let elem = Element(node)
        if elem.hover and node notin thisnode:
          elem.hover = false
          buffer.reshape = true
          elem.refreshStyle()

  buffer.prevnode = thisnode

proc loadResources(buffer: Buffer, document: Document) =
  for elem in document.head.children:
    if elem.tagType == TAG_LINK:
      let elem = HTMLLinkElement(elem)
      if elem.rel == "stylesheet":
        let url = parseUrl(elem.href, document.location.some)
        if url.issome:
          let res = buffer.loader.getPage(url.get)
          if res.s != nil and res.contenttype == "text/css":
            elem.s = res.s

proc load*(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if not buffer.streamclosed:
      #TODO not sure what to do with this.
      #Ideally we could just throw away the source data after parsing but then
      #source view won't work. Well we could still generate it... best would be a
      #config option like a) store source b) generate source
      buffer.source = buffer.istream.readAll()
      buffer.istream.close()
      buffer.streamclosed = true
    buffer.document = parseHtml(newStringStream(buffer.source))
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
    buffer.lines = renderDocument(buffer.document, buffer.attrs, buffer.userstyle, buffer.viewport)
  else: discard
  buffer.updateCursor()

proc cursorBufferPos(buffer: Buffer) =
  let x = buffer.acursorx
  let y = buffer.acursory
  print(HVP(y + 1, x + 1))

proc clearStatusMessage(buffer: Buffer) =
  buffer.statusmsg = newFixedGrid(buffer.width)

proc writeStatusMessage(buffer: Buffer, str: string, formatting: Formatting = Formatting()) =
  buffer.clearStatusMessage()
  var i = 0
  for r in str.runes:
    i += r.width()
    if i >= buffer.statusmsg.len:
      buffer.statusmsg[^1].runes.setLen(0)
      buffer.statusmsg[^1].runes.add(Rune('$'))
      break
    buffer.statusmsg[i].runes.add(r)
    buffer.statusmsg[i].formatting = formatting

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = $(buffer.cursory + 1) & "/" & $buffer.numLines & " (" &
            $buffer.atPercentOf() & "%) " & "<" & buffer.title & ">"
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  var formatting: Formatting
  formatting.reverse = true
  buffer.writeStatusMessage(msg, formatting)

proc setStatusMessage*(buffer: Buffer, str: string) =
  buffer.writeStatusMessage(str)
  buffer.nostatus = true

proc lineInfo*(buffer: Buffer) =
    buffer.setStatusMessage("line " & $(buffer.cursory + 1) & "/" & $buffer.numLines & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth() & " cell width: " & $buffer.currentDisplayCell().width())

proc displayBufferSwapOutput(buffer: Buffer) =
  print(buffer.generateSwapOutput())

proc displayBuffer(buffer: Buffer) =
  print(buffer.generateFullOutput())

proc displayStatusMessage*(buffer: Buffer) =
  print(HVP(buffer.height + 1, 1))
  print(SGR())
  print(buffer.generateStatusMessage())
  print(SGR())

proc click*(buffer: Buffer): string =
  let link = buffer.getCursorLink()
  if link != nil:
    if link.tagType == TAG_A:
      return HTMLAnchorElement(link).href
  return ""

proc drawBuffer*(buffer: Buffer) =
  var formatting = newFormatting()
  for line in buffer.lines:
    if line.formats.len == 0:
      print(line.str & '\n')
    else:
      var x = 0
      for format in line.formats:
        print(line.str.substr(x, format.pos - 1))
        print(formatting.processFormatting(format.formatting))
        x = format.pos
      print(line.str.substr(x, line.str.len) & '\n')

proc refreshBuffer*(buffer: Buffer) =
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

  if not buffer.nostatus:
    buffer.statusMsgForBuffer()
  else:
    buffer.nostatus = false
  buffer.displayStatusMessage()
  buffer.cursorBufferPos()
  stdout.showCursor()
