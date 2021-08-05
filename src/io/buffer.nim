import options
import uri
import tables
import strutils
import unicode

import ../types/enums
import ../types/color

import ../utils/twtstr
import ../utils/eprint

import ../html/dom

import ./twtio
import ./term

type
  Cell = object of RootObj
    fgcolor*: CellColor
    bgcolor*: CellColor
    italic: bool
    bold: bool
    underline: bool

  BufferCell = object of Cell
    rune*: Rune

# xterm supports max 2 characters per cell by default. might make the tuple a
# seq in the future but for now it's fine like this
  DisplayCell = object of Cell
    runes*: tuple[a: Rune, b: Rune]

  Buffer* = ref BufferObj
  BufferObj = object
    title*: string
    lines*: seq[seq[BufferCell]]
    display*: seq[DisplayCell]
    hovertext*: string
    width*: int
    height*: int
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    nodes*: seq[Node]
    links*: seq[Node]
    elements*: seq[Element]
    idelements*: Table[string, Element]
    selectedlink*: Node
    printwrite*: bool
    attrs*: TermAttributes
    document*: Document
    displaycontrols*: bool
    redraw*: bool
    location*: Uri

func newBuffer*(attrs: TermAttributes): Buffer =
  new(result)
  result.width = attrs.termWidth
  result.height = attrs.termHeight
  result.attrs = attrs

  result.display = newSeq[DisplayCell](result.width * result.height)

func generateFullOutput*(buffer: Buffer): string =
  var x = 0
  var y = 0
  for cell in buffer.display:
    if x >= buffer.width:
      inc y
      result &= '\n'
      x = 0

    if cell.runes.a != Rune(0):
      result &= $cell.runes.a
    if cell.runes.b != Rune(0):
      result &= $cell.runes.b
    inc x

func lastLine*(buffer: Buffer): int =
  return buffer.lines.len - 1

func lastVisibleLine*(buffer: Buffer): int =
  return min(buffer.fromy + buffer.height - 1, buffer.lastLine())

func width(line: seq[BufferCell]): int =
  for c in line:
    result += c.rune.width()

func currentLineWidth*(buffer: Buffer): int =
  return buffer.lines[buffer.cursory].width()

func maxScreenWidth*(buffer: Buffer): int =
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine()]:
    result = max(line.width(), result)

func atPercentOf*(buffer: Buffer): int =
  if buffer.lines.len == 0: return 100
  return (100 * (buffer.cursory + 1)) div (buffer.lastLine() + 1)

func lastNode*(buffer: Buffer): Node =
  return buffer.nodes[^1]

func cursorOnNode*(buffer: Buffer, node: Node): bool =
  if node.y == node.ey and node.y == buffer.cursory:
    return buffer.cursorx >= node.x and buffer.cursorx < node.ex
  else:
    return (buffer.cursory == node.y and buffer.cursorx >= node.x) or
           (buffer.cursory > node.y and buffer.cursory < node.ey) or
           (buffer.cursory == node.ey and buffer.cursorx < node.ex)

func findSelectedElement*(buffer: Buffer): Option[HtmlElement] =
  if buffer.selectedlink != nil and buffer.selectedLink.parentNode of HtmlElement:
    return some(HtmlElement(buffer.selectedlink.parentNode))
  for node in buffer.nodes:
    if node.isElemNode():
      if node.getFmtLen() > 0:
        if buffer.cursorOnNode(node): return some(HtmlElement(node))
  return none(HtmlElement)

func canScroll*(buffer: Buffer): bool =
  return buffer.lastLine() > buffer.height

func getElementById*(buffer: Buffer, id: string): Element =
  if buffer.idelements.hasKey(id):
    return buffer.idelements[id]
  return nil

proc findSelectedNode*(buffer: Buffer): Option[Node] =
  for node in buffer.nodes:
    if node.getFmtLen() > 0 and node.displayed():
      if buffer.cursory >= node.y and buffer.cursory <= node.y + node.height and buffer.cursorx >= node.x and buffer.cursorx <= node.x + node.width:
        return some(node)
  return none(Node)

proc writefmt*(buffer: Buffer, str: string) =
  discard

proc writefmt*(buffer: Buffer, c: char) =
  discard

proc writeraw*(buffer: Buffer, str: string) =
  discard

proc writeraw*(buffer: Buffer, c: char) =
  discard

proc write*(buffer: Buffer, str: string) =
  buffer.writefmt(str)
  buffer.writeraw(str)

proc write*(buffer: Buffer, c: char) =
  buffer.writefmt(c)
  buffer.writeraw(c)

proc clearText*(buffer: Buffer) =
  buffer.lines.setLen(0)

proc clearNodes*(buffer: Buffer) =
  buffer.nodes.setLen(0)
  buffer.links.setLen(0)
  buffer.elements.setLen(0)
  buffer.idelements.clear()

proc clearBuffer*(buffer: Buffer) =
  buffer.clearText()
  buffer.clearNodes()
  buffer.cursorx = 0
  buffer.cursory = 0
  buffer.fromx = 0
  buffer.fromy = 0
  buffer.hovertext = ""
  buffer.selectedlink = nil

proc restoreCursorX(buffer: Buffer) =
  buffer.cursorx = min(buffer.currentLineWidth() - 1, buffer.xend)

proc scrollTo*(buffer: Buffer, y: int) =
  if y == buffer.fromy:
    return
  buffer.fromy = min(max(buffer.lastLine() - buffer.height + 1, 0), y)
  buffer.cursory = min(max(buffer.fromy, buffer.cursory), buffer.fromy + buffer.height)
  buffer.redraw = true
  buffer.restoreCursorX()

proc cursorTo*(buffer: Buffer, x: int, y: int) =
  buffer.redraw = false
  buffer.cursory = min(max(y, 0), buffer.lastLine())
  if buffer.fromy > buffer.cursory:
    buffer.fromy = max(buffer.cursory, 0)
    buffer.redraw = true
  elif buffer.fromy + buffer.height - 1 <= buffer.cursory:
    buffer.fromy = max(buffer.cursory - buffer.height + 2, 0)
    buffer.redraw = true
  buffer.cursorx = min(max(x, 0), buffer.currentLineWidth())
  #buffer.fromX = min(max(buffer.currentLineWidth() - buffer.width + 1, 0), 0) #TODO

proc cursorDown*(buffer: Buffer) =
  if buffer.cursory < buffer.lastLine():
    inc buffer.cursory
    buffer.restoreCursorX()
    if buffer.cursory >= buffer.lastVisibleLine() and buffer.lastVisibleLine() != buffer.lastLine():
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
  if buffer.cursorx < buffer.currentLineWidth() - 1:
    inc buffer.cursorx
    buffer.xend = buffer.cursorx
    if buffer.cursorx - buffer.width >= buffer.fromx:
      inc buffer.fromx
      buffer.redraw = true

proc cursorLeft*(buffer: Buffer) =
  if buffer.fromx > buffer.cursorx:
    buffer.fromx = buffer.cursorx
    buffer.redraw = true
  elif buffer.cursorx > 0:
    dec buffer.cursorx
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
  buffer.cursorx = buffer.currentLineWidth() - 1
  buffer.xend = buffer.cursorx
  buffer.fromx = max(buffer.cursorx - buffer.width + 1, 0)
  buffer.redraw = buffer.fromx > 0

iterator revnodes*(buffer: Buffer): Node {.inline.} =
  var i = buffer.nodes.len - 1
  while i >= 0:
    yield buffer.nodes[i]
    dec i

proc cursorNextWord*(buffer: Buffer) =
  let llen = buffer.currentLineWidth() - 1
  var x = buffer.cursorx
  var y = buffer.cursory
  if llen >= 0:

    while buffer.lines[y][x].rune != Rune(' '):
      if x >= llen:
        break
      inc x

    while buffer.lines[y][x].rune == Rune(' '):
      if x >= llen:
        break
      inc x

  if x >= llen:
    if y < buffer.lastLine():
      inc y
      x = 0
  buffer.cursorTo(x, y)

proc cursorPrevWord*(buffer: Buffer) =
  var x = buffer.cursorx
  var y = buffer.cursory
  if buffer.currentLineWidth() > 0:
    while buffer.lines[y][x].rune != Rune(' '):
      if x == 0:
        break
      dec x

    while buffer.lines[y][x].rune == Rune(' '):
      if x == 0:
        break
      dec x

  if x == 0:
    if y > 0:
      dec y
      x = buffer.lines[y].len - 1
  buffer.cursorTo(x, y)

proc cursorNextLink*(buffer: Buffer) =
  #TODO
  return

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
  if buffer.fromy < buffer.lastLine() - buffer.height:
    buffer.fromy = buffer.lastLine() - (buffer.height - 2)
    buffer.redraw = true
  else:
    buffer.redraw = false
  buffer.cursory = buffer.lastLine()
  buffer.restoreCursorX()

proc cursorTop*(buffer: Buffer) =
  buffer.cursory = buffer.fromy
  buffer.restoreCursorX()

proc cursorMiddle*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + (buffer.height - 2) div 2, buffer.lastLine())
  buffer.restoreCursorX()

proc cursorBottom*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + buffer.height - 2, buffer.lastLine())
  buffer.restoreCursorX()

proc centerLine*(buffer: Buffer) =
  let ny = max(min(buffer.cursory - buffer.height div 2, buffer.lastLine() - buffer.height + 2), 0)
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
  buffer.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.lastLine())
  let nfy = min(max(buffer.lastLine() - buffer.height + 2, 0), buffer.fromy + buffer.height div 2 - 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageUp*(buffer: Buffer) =
  buffer.cursory = max(buffer.cursory - buffer.height + 1, 1)
  buffer.fromy = max(0, buffer.fromy - buffer.height)
  buffer.redraw = true
  buffer.restoreCursorX()

proc pageDown*(buffer: Buffer) =
  buffer.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.lastLine())
  buffer.fromy = min(max(buffer.lastLine() - buffer.height + 1, 0), buffer.fromy + buffer.height div 2)
  buffer.redraw = true
  buffer.restoreCursorX()

proc pageLeft*(buffer: Buffer) =
  buffer.cursorx = max(buffer.cursorx - buffer.width, 0)
  buffer.fromx = max(0, buffer.fromx - buffer.width)
  buffer.redraw = true

proc pageRight*(buffer: Buffer) =
  buffer.cursorx = min(buffer.fromx, buffer.currentLineWidth())
  buffer.fromx = min(max(buffer.maxScreenWidth() - buffer.width, 0), buffer.fromx + buffer.width)
  buffer.redraw = true

proc scrollDown*(buffer: Buffer) =
  if buffer.fromy + buffer.height - 1 <= buffer.lastLine():
    inc buffer.fromy
    if buffer.fromy > buffer.cursory:
      buffer.cursorDown()
    buffer.redraw = true
  else:
    buffer.cursorDown()

proc scrollUp*(buffer: Buffer) =
  if buffer.fromy > 0:
    dec buffer.fromy
    if buffer.fromy + buffer.height - 1 <= buffer.cursory:
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
  if buffer.location.anchor != "":
    let node =  buffer.getElementById(buffer.location.anchor)
    if node != nil:
      buffer.scrollTo(max(node.y - buffer.height div 2, 0))

proc setLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = uri

proc gotoLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = buffer.location.combine(uri)

proc refreshTermAttrs*(buffer: Buffer): bool =
  let newAttrs = getTermAttributes()
  if newAttrs != buffer.attrs:
    buffer.attrs = newAttrs
    buffer.width = newAttrs.termWidth
    buffer.height = newAttrs.termHeight
    return true
  return false

proc setText*(buffer: Buffer, x: int, y: int, text: seq[Rune]) =
  while buffer.lines.len <= y:
    buffer.lines.add(newSeq[BufferCell]())

  while buffer.lines[y].len < x + text.len:
    buffer.lines[y].add(BufferCell())
  
  var i = 0
  while i < text.len:
    buffer.lines[y][i].rune = text[i]
    inc i

proc setDisplayText(buffer: Buffer, x: int, y: int, text: seq[Rune]) =
  let pos = y * buffer.width + x
  var i = 0
  var n = 0
  while i < text.len:
    if text[i].width() == 0:
      buffer.display[pos + i - n].runes.b = text[i]
      inc n
    else:
      buffer.display[pos + i - n].runes.a = text[i]
    inc i

proc reshape*(buffer: Buffer) =
  buffer.display = newSeq[DisplayCell](buffer.width * buffer.height)

proc refreshDisplay*(buffer: Buffer) =
  var y = 0
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine()]:
    var w = 0
    var i = 0
    var n = 0
    while w < buffer.fromx and i < line.len:
      w += line[i].rune.width()
      inc i

    let dls = y * buffer.width
    var j = 0
    while w < buffer.fromx + buffer.width and i < line.len:
      w += line[i].rune.width()
      if line[i].rune.width() == 0:
        buffer.display[dls + j].runes.b = line[i].rune
      else:
        buffer.display[dls + j].runes.a = line[i].rune
      inc i
      inc j

    while j < buffer.width:
      buffer.display[dls + j].runes.a = Rune(0)
      buffer.display[dls + j].runes.b = Rune(0)
      inc j

    inc y

proc renderPlainText*(buffer: Buffer, text: string) =
  var i = 0
  var y = 0
  var line = ""
  while i < text.len:
    if text[i] == '\n':
      buffer.setText(0, y, line.toRunes())
      inc y
      line = ""
    elif text[i] == '\t':
      line &= ' '.repeat(8)
    else:
      line &= text[i]
    inc i
  if line.len > 0:
    buffer.setText(0, y, line.toRunes())

  buffer.refreshDisplay()
