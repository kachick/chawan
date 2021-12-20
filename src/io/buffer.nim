import terminal
import uri
import strutils
import unicode
import streams

import css/values
import css/cascade
import css/sheet
import utils/twtstr
import html/dom
import html/tags
import layout/box
import layout/engine
import config/config
import io/term
import io/lineedit
import io/cell

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

func generateFullOutput*(buffer: Buffer): string =
  var x = 0
  var w = 0
  var formatting = newFormatting()
  result &= HVP(1, 1)

  for cell in buffer.display:
    if x >= buffer.width:
      if w < buffer.width:
        result &= EL()
      result &= '\n'
      x = 0
      w = 0


    result &= formatting.processFormatting(cell.formatting)
    result &= $cell.runes

    w += cell.width()
    inc x

  if w < buffer.width:
    result &= EL()
  result &= '\n'

# generate a sequence of instructions to replace the previous frame with the
# current one. ideally should be used when small changes are made (e.g. hover
# changes underlining)
func generateSwapOutput*(buffer: Buffer): string =
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
  for cell in buffer.statusmsg:
    for r in cell.runes:
      if r != Rune(0):
        result &= $r

func numLines*(buffer: Buffer): int = buffer.lines.len

func lastVisibleLine*(buffer: Buffer): int = min(buffer.fromy + buffer.height, buffer.numLines)

func currentLineWidth*(buffer: Buffer): int =
  if buffer.cursory > buffer.lines.len:
    return 0
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

#TODO counter-intuitive naming?
func currentDisplayCell(buffer: Buffer): FixedCell =
  let row = (buffer.cursory - buffer.fromy) * buffer.width
  return buffer.display[row + buffer.currentCellOrigin()]

func cell(buffer: Buffer): FixedCell =
  let row = (buffer.cursory - buffer.fromy) * buffer.width
  return buffer.display[row + buffer.acursorx]

func getLink(nodes: seq[Node]): Element =
  for node in nodes:
    if node.nodeType == ELEMENT_NODE:
      let elem = Element(node)
      if elem.tagType == TAG_A:
        return elem
  return nil

func getCursorLink(buffer: Buffer): Element =
  return buffer.currentDisplayCell().nodes.getLink()

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
        buffer.display[dls + k].ow = r.width()
        inc k

    while i < line.str.len:
      let j = i
      fastRuneAt(line.str, i, r)
      w += r.width()
      if w > buffer.fromx + buffer.width:
        buffer.display[dls + k].ow += r.width()
        break
      if nf.pos != -1 and nf.pos <= j:
        cf = nf
        nf = line.findNextFormat(j)
      buffer.display[dls + k].runes.add(r)
      if cf.pos != -1:
        buffer.display[dls + k].formatting = cf.formatting
        buffer.display[dls + k].nodes = cf.nodes
      let tk = k + r.width()
      while k < tk and k < buffer.width - 1:
        buffer.display[dls + k].ow += r.width()
        inc k

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

proc cursorTo*(buffer: Buffer, x, y: int) =
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

proc setCursorXB*(buffer: Buffer, byte: int) =
  var b = buffer.currentCursorBytes()
  if byte == b:
    return

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


proc setCursorX*(buffer: Buffer, x: int) =
  if buffer.cursorx == x:
    return
  var b = buffer.currentCursorBytes()
  var w = buffer.fromx + buffer.cursorx
  while b < buffer.currentLine.len and w < x:
    var r: Rune
    fastRuneAt(buffer.currentLine, b, r)
    w += r.width()

  b = min(b, max(buffer.currentLine.len - 1, 0))
  while b > 0 and w > x:
    let (r, o) = lastRune(buffer.currentLine, b)
    w -= r.width()
    b -= o

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

proc setCursorY*(buffer: Buffer, y: int) =
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

proc cursorDown*(buffer: Buffer) =
  if buffer.cursory < buffer.numLines - 1:
    buffer.setCursorY(buffer.cursory + 1)

proc cursorUp*(buffer: Buffer) =
  if buffer.cursory > 0:
    buffer.setCursorY(buffer.cursory - 1)

proc cursorRight*(buffer: Buffer) =
  let cellwidth = buffer.cell().ow
  if buffer.cursorx < buffer.currentLineWidth() - 1:
    buffer.setCursorX(buffer.cursorx + cellwidth)

proc cursorLeft*(buffer: Buffer) =
  let cellwidth = buffer.cell().ow
  if buffer.cursorx >= cellwidth:
    buffer.setCursorX(buffer.cursorx - cellwidth)

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
  buffer.redraw = buffer.redraw or buffer.fromx > 0

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
    link = line.formats[i].nodes.getLink()
  inc i

  while i < line.formats.len:
    let format = line.formats[i]
    let fl = format.nodes.getLink()
    if fl != nil and fl != link:
      buffer.setCursorXB(format.pos)
      return
    inc i

  for y in (buffer.cursory + 1)..(buffer.numLines - 1):
    let line = buffer.lines[y]
    i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      let fl = format.nodes.getLink()
      if fl != nil and fl != link:
        buffer.setCursorY(y)
        buffer.setCursorXB(format.pos)
        return
      inc i

proc cursorPrevLink*(buffer: Buffer) =
  let line = buffer.lines[buffer.cursory]
  var i = line.findFormatN(buffer.currentCursorBytes()) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].nodes.getLink()
  dec i

  while i >= 0:
    let format = line.formats[i]
    let fl = format.nodes.getLink()
    if fl != nil and fl != link:
      buffer.setCursorXB(format.pos)
      return
    dec i

  for y in countdown(buffer.cursory - 1, 0):
    let line = buffer.lines[y]
    i = line.formats.len - 1
    while i >= 0:
      let format = line.formats[i]
      let fl = format.nodes.getLink()
      if fl != nil and fl != link:
        #go to beginning of link
        var ly = y #last y
        var lx = format.pos #last x
        for iy in countdown(ly - 1, 0):
          let line = buffer.lines[iy]
          i = line.formats.len - 1
          while i >= 0:
            let format = line.formats[i]
            let nl = format.nodes.getLink()
            if nl == fl:
              ly = iy
              lx = format.pos
            dec i
        buffer.setCursorY(ly)
        buffer.setCursorXB(lx)
        return
      dec i

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

proc cursorLeftEdge*(buffer: Buffer) =
  buffer.cursorx = buffer.fromx
  buffer.xend = buffer.cursorx

proc cursorVertMiddle*(buffer: Buffer) =
  buffer.cursorx = min(buffer.fromx + (buffer.width - 2) div 2, buffer.currentLineWidth)
  buffer.xend = buffer.cursorx

proc cursorRightEdge*(buffer: Buffer) =
  buffer.cursorx = min(buffer.fromx + buffer.width - 1, buffer.currentLineWidth)
  buffer.xend = buffer.cursorx

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
    result.italic_on
  if line.fontweight > 500:
    result.bold_on
  if line.textdecoration == TEXT_DECORATION_UNDERLINE:
    result.underline_on
  if line.textdecoration == TEXT_DECORATION_OVERLINE:
    result.overline_on
  if line.textdecoration == TEXT_DECORATION_LINE_THROUGH:
    result.strike_on

proc setRowBox(buffer: Buffer, line: CSSRowBox) =
  var r: Rune

  var x = line.x
  var i = 0
  while x < 0:
    fastRuneAt(line.str, i, r)
    x += r.width()
  let linestr = line.str.substr(i)
  i = 0

  let y = line.y

  while buffer.lines.len <= y:
    buffer.addLine()

  var cx = 0
  while cx < x and i < buffer.lines[y].str.len:
    fastRuneAt(buffer.lines[y].str, i, r)
    cx += r.width()

  let ostr = buffer.lines[y].str.substr(i)
  let oformats = buffer.lines[y].formats.subformats(i)
  buffer.lines[y].setLen(i)

  buffer.lines.addFormat(y, i, line.formatFromLine(), line.nodes)

  var nx = cx
  if nx < x:
    buffer.lines[y].str &= ' '.repeat(x - nx)
    nx = x

  buffer.lines[y].str &= linestr
  nx += linestr.width()

  i = 0
  while cx < nx and i < ostr.len:
    fastRuneAt(ostr, i, r)
    cx += r.width()

  if i < ostr.len:
    let oline = FlexibleLine(str: ostr.substr(i), formats: oformats.subformats(i))
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

proc updateHover(buffer: Buffer) =
  let nodes = buffer.currentDisplayCell().nodes
  if nodes != buffer.prevnodes:
    for node in nodes:
      var elem: Element
      if node of Element:
        elem = Element(node)
      else:
        elem = node.parentElement
        assert elem != nil

      if not elem.hover and not (node in buffer.prevnodes):
        elem.hover = true
        buffer.reshape = true
        elem.refreshStyle()
    let link = nodes.getLink()
    if link != nil:
      buffer.hovertext = "(link)"
    else:
      buffer.hovertext = ""
    for node in buffer.prevnodes:
      var elem: Element
      if node of Element:
        elem = Element(node)
      else:
        elem = node.parentElement
        assert elem != nil
      if elem.hover and not (node in nodes):
        elem.hover = false
        buffer.reshape = true
        elem.refreshStyle()
  buffer.prevnodes = nodes

proc renderPlainText*(buffer: Buffer, text: string) =
  var format = newFormatting()
  template add_format() =
    if af:
      af = false
      buffer.lines.addFormat(y, buffer.lines[y].str.len, format)

  buffer.clearText()
  var i = 0
  var x = 0
  var y = 0
  var af = false
  while i < text.len:
    if text[i] == '\n':
      if i != text.len - 1:
        add_format
        buffer.addLine()
        inc y
        x = 0
      inc i
    elif text[i] == '\r':
      inc i
    elif text[i] == '\t':
      add_format
      for i in 0..8:
        buffer.lines[^1].str &= ' '
      inc i
    elif text[i] == '\e':
      i = format.parseAnsiCode(text, i)
      af = true
    elif text[i].isControlChar():
      add_format
      buffer.lines[y].str &= '^' & text[i].getControlLetter()
      inc i
    else:
      add_format
      buffer.lines[y].str &= text[i]
      inc i
  buffer.updateCursor()


const css = staticRead"res/ua.css"
let ua_stylesheet = newStringStream(css).parseStylesheet()

#TODO refactor
var ss_init = false
var user_stylesheet: CSSStylesheet
proc renderDocument*(buffer: Buffer) =
  buffer.clearText()

  if not ss_init:
    user_stylesheet = newStringStream(gconfig.stylesheet).parseStylesheet()
    ss_init = true

  buffer.document.applyStylesheets(ua_stylesheet, user_stylesheet)
  buffer.rootbox = buffer.document.alignBoxes(buffer.attrs)
  if buffer.rootbox == nil:
    return
  var stack: seq[CSSBox]
  stack.add(buffer.rootbox)
  while stack.len > 0:
    let box = stack.pop()
    if box of CSSBlockBox:
      for line in box.icontext.rows:
        buffer.setRowBox(line)

    var i = box.children.len - 1
    while i >= 0:
      stack.add(box.children[i])
      dec i
  buffer.updateCursor()

proc reshapeBuffer*(buffer: Buffer) =
  if buffer.showsource:
    buffer.renderPlainText(buffer.source)
  else:
    buffer.renderDocument()

proc cursorBufferPos(buffer: Buffer) =
  let x = max(buffer.cursorx - buffer.fromx, 0)
  let y = buffer.cursory - buffer.fromy
  print(HVP(y + 1, x + 1))

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
  var msg = $(buffer.cursory + 1) & "/" & $buffer.numLines & " (" &
            $buffer.atPercentOf() & "%) " & "<" & buffer.title & ">"
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  buffer.setStatusMessage(msg.ansiStyle(styleReverse).ansiReset())

proc displayBufferSwapOutput(buffer: Buffer) =
  print(buffer.generateSwapOutput())

proc displayBuffer(buffer: Buffer) =
  print(buffer.generateFullOutput())

proc displayStatusMessage(buffer: Buffer) =
  print(HVP(buffer.height + 1, 1))
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
      print(HVP(0, 0))
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
    of ACTION_CURSOR_LEFT_EDGE: buffer.cursorLeftEdge()
    of ACTION_CURSOR_VERT_MIDDLE: buffer.cursorVertMiddle()
    of ACTION_CURSOR_RIGHT_EDGE: buffer.cursorRightEdge()
    of ACTION_CENTER_LINE: buffer.centerLine()
    of ACTION_SCROLL_DOWN: buffer.scrollDown()
    of ACTION_SCROLL_UP: buffer.scrollUp()
    of ACTION_SCROLL_LEFT: buffer.scrollLeft()
    of ACTION_SCROLL_RIGHT: buffer.scrollRight()
    of ACTION_CLICK:
      discard
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.location

      print(HVP(buffer.height + 1, 1))
      print(EL())
      let status = readLine("URL: ", url, buffer.width)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_LINE_INFO:
      buffer.setStatusMessage("line " & $(buffer.cursory + 1) & "/" & $buffer.numLines & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth() & " cell width: " & $buffer.currentDisplayCell().width())
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
  buffer.updateHover()
  if buffer.reshape:
    buffer.reshapeBuffer()
    buffer.reshape = false
    buffer.refreshDisplay()
    buffer.displayBufferSwapOutput()
  buffer.statusMsgForBuffer()
  return inputLoop(attrs, buffer)
