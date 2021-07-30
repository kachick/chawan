import options
import uri
import tables
import strutils
import unicode

import types/enums

import utils/termattrs
import utils/twtstr

import html/dom

import io/twtio

type
  Buffer* = ref BufferObj
  BufferObj = object
    fmttext*: seq[string]
    rawtext*: seq[string]
    title*: string
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
    clickables*: seq[Node]
    elements*: seq[Element]
    idelements*: Table[string, Element]
    selectedlink*: Node
    printwrite*: bool
    attrs*: TermAttributes
    document*: Document

proc newBuffer*(attrs: TermAttributes): Buffer =
  return Buffer(width: attrs.termWidth,
                height: attrs.termHeight,
                attrs: attrs)

func lastLine*(buffer: Buffer): int =
  assert(buffer.fmttext.len == buffer.rawtext.len)
  return buffer.fmttext.len - 1

func lastVisibleLine*(buffer: Buffer): int =
  return min(buffer.fromy + buffer.height - 1, buffer.lastLine())

func currentLineLength*(buffer: Buffer): int =
  return buffer.rawtext[buffer.cursory].width()

func atPercentOf*(buffer: Buffer): int =
  if buffer.fmttext.len == 0: return 100
  return (100 * (buffer.cursory + 1)) div (buffer.lastLine() + 1)

func fmtBetween*(buffer: Buffer, sx: int, sy: int, ex: int, ey: int): string =
  if sy < ey:
    result &= buffer.rawtext[sy].runeSubstr(sx)
    var i = sy + 1
    while i < ey - 1:
      result &= buffer.rawtext[i]
      inc i
    result &= buffer.rawtext[i].runeSubstr(0, ex - sx)
  else:
    result &= buffer.rawtext[sy].runeSubstr(sx, ex - sx)

func visibleText*(buffer: Buffer): string = 
  return buffer.fmttext[buffer.fromy..buffer.lastVisibleLine()].join("\n")

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

proc addNode*(buffer: Buffer, node: Node) =
  buffer.nodes.add(node)

  if node.isTextNode() and node.parentElement != nil and node.parentElement.getStyle().islink:
    buffer.links.add(node)

  if node.isElemNode():
    case Element(node).tagType
    of TAG_INPUT, TAG_OPTION:
      if not Element(node).hidden:
        buffer.clickables.add(node)
    else: discard
  elif node.isTextNode():
    if node.parentElement != nil and node.getStyle().islink:
      let anchor = node.ancestor(TAG_A)
      assert(anchor != nil)
      buffer.clickables.add(anchor)

  if node.isElemNode():
    let elem = Element(node)
    buffer.elements.add(elem)
    if elem.id != "" and not buffer.idelements.hasKey(elem.id):
      buffer.idelements[elem.id] = elem

proc writefmt*(buffer: Buffer, str: string) =
  buffer.fmttext &= str
  if buffer.printwrite:
    stdout.write(str)

proc writefmt*(buffer: Buffer, c: char) =
  buffer.rawtext &= $c
  if buffer.printwrite:
    stdout.write(c)

proc writeraw*(buffer: Buffer, str: string) =
  buffer.rawtext &= str

proc writeraw*(buffer: Buffer, c: char) =
  buffer.rawtext &= $c

proc write*(buffer: Buffer, str: string) =
  buffer.writefmt(str)
  buffer.writeraw(str)

proc write*(buffer: Buffer, c: char) =
  buffer.writefmt(c)
  buffer.writeraw(c)

proc clearText*(buffer: Buffer) =
  buffer.fmttext.setLen(0)
  buffer.rawtext.setLen(0)

proc clearNodes*(buffer: Buffer) =
  buffer.nodes.setLen(0)
  buffer.links.setLen(0)
  buffer.clickables.setLen(0)
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

proc scrollTo*(buffer: Buffer, y: int): bool =
  if y == buffer.fromy:
    return false
  buffer.fromy = min(max(buffer.lastLine() - buffer.height + 1, 0), y)
  buffer.cursory = min(max(buffer.fromy, buffer.cursory), buffer.fromy + buffer.height)
  return true

proc cursorTo*(buffer: Buffer, x: int, y: int): bool =
  result = false
  buffer.cursory = min(max(y, 0), buffer.lastLine())
  if buffer.fromy > buffer.cursory:
    buffer.fromy = max(buffer.cursory, 0)
    result = true
  elif buffer.fromy + buffer.height - 1 <= buffer.cursory:
    buffer.fromy = max(buffer.cursory - buffer.height + 2, 0)
    result = true
  buffer.cursorx = min(max(x, 0), buffer.currentLineLength())
  #buffer.fromX = min(max(buffer.currentLineLength() - buffer.width + 1, 0), 0) #TODO

proc cursorDown*(buffer: Buffer): bool =
  if buffer.cursory < buffer.lastLine():
    inc buffer.cursory
    if buffer.cursorx >= buffer.currentLineLength():
      buffer.cursorx = max(buffer.currentLineLength() - 1, 0)
    elif buffer.xend > 0:
      buffer.cursorx = min(buffer.currentLineLength() - 1, buffer.xend)
    if buffer.cursory >= buffer.lastVisibleLine() and buffer.lastVisibleLine() != buffer.lastLine():
      inc buffer.fromy
      return true
  return false

proc cursorUp*(buffer: Buffer): bool =
  if buffer.cursory > 0:
    dec buffer.cursory
    if buffer.cursorx > buffer.currentLineLength():
      if buffer.cursorx == 0:
        buffer.xend = buffer.cursorx
      buffer.cursorx = max(buffer.currentLineLength() - 1, 0)
    elif buffer.xend > 0:
      buffer.cursorx = min(buffer.currentLineLength() - 1, buffer.xend)
    if buffer.cursory < buffer.fromy:
      dec buffer.fromy
      return true
  return false

proc cursorRight*(buffer: Buffer): bool =
  if buffer.cursorx < buffer.currentLineLength() - 1:
    inc buffer.cursorx
    buffer.xend = 0
  else:
    buffer.xend = buffer.cursorx
  return false

proc cursorLeft*(buffer: Buffer): bool =
  if buffer.cursorx > 0:
    dec buffer.cursorx
  buffer.xend = 0
  return false

proc cursorLineBegin*(buffer: Buffer) =
  buffer.cursorx = 0
  buffer.xend = 0

proc cursorLineEnd*(buffer: Buffer) =
  buffer.cursorx = buffer.currentLineLength() - 1
  buffer.xend = buffer.cursorx

iterator revnodes*(buffer: Buffer): Node {.inline.} =
  var i = buffer.nodes.len - 1
  while i >= 0:
    yield buffer.nodes[i]
    dec i

proc cursorNextWord*(buffer: Buffer): bool =
  let llen = buffer.currentLineLength() - 1
  var r: Rune
  var x = buffer.cursorx
  var y = buffer.cursory
  if llen >= 0:
    fastRuneAt(buffer.rawtext[y], x, r, false)

    while r != Rune(' '):
      if x >= llen:
        break
      inc x
      fastRuneAt(buffer.rawtext[y], x, r, false)

    while r == Rune(' '):
      if x >= llen:
        break
      inc x
      fastRuneAt(buffer.rawtext[y], x, r, false)

  if x >= llen:
    if y < buffer.lastLine():
      inc y
      x = 0
  return buffer.cursorTo(x, y)

proc cursorPrevWord*(buffer: Buffer): bool =
  var r: Rune
  var x = buffer.cursorx
  var y = buffer.cursory
  if buffer.currentLineLength() > 0:
    fastRuneAt(buffer.rawtext[y], x, r, false)

    while r != Rune(' '):
      if x == 0:
        break
      dec x
      fastRuneAt(buffer.rawtext[y], x, r, false)

    while r == Rune(' '):
      if x == 0:
        break
      dec x
      fastRuneAt(buffer.rawtext[y], x, r, false)

  if x == 0:
    if y > 0:
      dec y
      x = buffer.rawtext[y].runeLen() - 1
  return buffer.cursorTo(x, y)

iterator revclickables*(buffer: Buffer): Node {.inline.} =
  var i = buffer.clickables.len - 1
  while i >= 0:
    yield buffer.clickables[i]
    dec i

proc cursorNextLink*(buffer: Buffer): bool =
  for node in buffer.clickables:
    if node.y > buffer.cursory or (node.y == buffer.cursorY and node.x > buffer.cursorx):
      result = buffer.cursorTo(node.x, node.y)
      if buffer.cursorx < buffer.currentLineLength():
        var r: Rune
        fastRuneAt(buffer.rawtext[buffer.cursory], buffer.cursorx, r, false)
        if r == Rune(' '):
          return result or buffer.cursorNextWord()
      return result
  return false

proc cursorPrevLink*(buffer: Buffer): bool =
  for node in buffer.revclickables:
    if node.y < buffer.cursorY or (node.y == buffer.cursorY and node.x < buffer.cursorx):
      return buffer.cursorTo(node.x, node.y)
  return false

proc cursorFirstLine*(buffer: Buffer): bool =
  if buffer.fromy > 0:
    buffer.fromy = 0
    result = true
  else:
    result = false

  buffer.cursorY = 0
  buffer.cursorLineBegin()

proc cursorLastLine*(buffer: Buffer): bool =
  if buffer.fromy < buffer.lastLine() - buffer.height:
    buffer.fromy = buffer.lastLine() - (buffer.height - 2)
    result = true
  else:
    result = false
  buffer.cursory = buffer.lastLine()
  buffer.cursorLineBegin()

proc cursorTop*(buffer: Buffer): bool =
  buffer.cursorY = buffer.fromy
  return false

proc cursorMiddle*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.fromy + (buffer.height - 2) div 2, buffer.lastLine())
  return false

proc cursorBottom*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.fromy + buffer.height - 2, buffer.lastLine())
  return false

proc centerLine*(buffer: Buffer): bool =
  let ny = max(min(buffer.cursory - buffer.height div 2, buffer.lastLine() - buffer.height + 2), 0)
  if ny != buffer.fromy:
    buffer.fromy = ny
    return true
  return false

proc halfPageUp*(buffer: Buffer): bool =
  buffer.cursory = max(buffer.cursorY - buffer.height div 2 + 1, 0)
  let nfy = max(0, buffer.fromy - buffer.height div 2 + 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    return true
  return false

proc halfPageDown*(buffer: Buffer): bool =
  buffer.cursory = min(buffer.cursorY + buffer.height div 2 - 1, buffer.lastLine())
  let nfy = min(max(buffer.lastLine() - buffer.height + 2, 0), buffer.fromy + buffer.height div 2 - 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    return true
  return false

proc pageUp*(buffer: Buffer): bool =
  buffer.cursorY = max(buffer.cursorY - buffer.height + 1, 1)
  buffer.fromy = max(0, buffer.fromy - buffer.height)
  return true

proc pageDown*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.cursorY + buffer.height div 2 - 1, buffer.lastLine())
  buffer.fromy = min(max(buffer.lastLine() - buffer.height + 1, 0), buffer.fromy + buffer.height div 2)
  return true

proc scrollDown*(buffer: Buffer): bool =
  if buffer.fromy + buffer.height - 1 <= buffer.lastLine():
    inc buffer.fromy
    if buffer.fromy >= buffer.cursory:
      discard buffer.cursorDown()
    return true
  discard buffer.cursorDown()
  return false

proc scrollUp*(buffer: Buffer): bool =
  if buffer.fromy > 0:
    dec buffer.fromy
    if buffer.fromy + buffer.height - 1 <= buffer.cursorY:
      discard buffer.cursorUp()
    return true
  discard buffer.cursorUp()
  return false

proc checkLinkSelection*(buffer: Buffer): bool =
  if buffer.selectedlink != nil:
    if buffer.cursorOnNode(buffer.selectedlink):
      return false
    else:
      let anchor = buffer.selectedlink.ancestor(TAG_A)
      buffer.selectedlink.fmttext = buffer.selectedlink.getFmtText()
      buffer.selectedlink = nil
      buffer.hovertext = ""
      var stack: seq[Node]
      stack.add(anchor)
      while stack.len > 0:
        let elem = stack.pop()
        elem.fmttext = elem.getFmtText()
        for child in elem.childNodes:
          stack.add(child)
  for node in buffer.links:
    if buffer.cursorOnNode(node):
      buffer.selectedlink = node
      let anchor = node.ancestor(TAG_A)
      assert(anchor != nil)
      buffer.hovertext = HtmlAnchorElement(anchor).href
      var stack: seq[Node]
      stack.add(anchor)
      while stack.len > 0:
        let elem = stack.pop()
        elem.fmttext = elem.getFmtText()
        for child in elem.childNodes:
          stack.add(child)
      return true
  return false

proc gotoAnchor*(buffer: Buffer): bool =
  if buffer.document.location.anchor != "":
    let node =  buffer.getElementById(buffer.document.location.anchor)
    if node != nil:
      return buffer.scrollTo(max(node.y - buffer.height div 2, 0))
  return false

proc setLocation*(buffer: Buffer, uri: Uri) =
  buffer.document.location = uri

proc gotoLocation*(buffer: Buffer, uri: Uri) =
  buffer.document.location = buffer.document.location.combine(uri)

proc refreshTermAttrs*(buffer: Buffer): bool =
  let newAttrs = getTermAttributes()
  if newAttrs != buffer.attrs:
    buffer.attrs = newAttrs
    buffer.width = newAttrs.termWidth
    buffer.height = newAttrs.termHeight
    return true
  return false
