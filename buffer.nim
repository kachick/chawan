import options
import uri
import tables
import strutils

import fusion/htmlparser/xmltree

import termattrs
import htmlelement
import twtio
import enums

type
  Buffer* = ref BufferObj
  BufferObj = object
    text*: string
    rawtext*: string
    lines*: seq[int]
    rawlines*: seq[int]
    title*: string
    hovertext*: string
    htmlSource*: XmlNode
    width*: int
    height*: int
    cursorX*: int
    cursorY*: int
    xend*: int
    fromX*: int
    fromY*: int
    nodes*: seq[HtmlNode]
    links*: seq[HtmlNode]
    clickables*: seq[HtmlNode]
    elements*: seq[HtmlElement]
    idelements*: Table[string, HtmlElement]
    selectedlink*: HtmlNode
    printwrite*: bool
    attrs*: TermAttributes
    document*: Document

proc newBuffer*(attrs: TermAttributes): Buffer =
  return Buffer(lines: @[0],
                rawlines: @[0],
                width: attrs.termWidth,
                height: attrs.termHeight,
                cursorY: 1,
                document: newDocument())

func lastLine*(buffer: Buffer): int =
  assert(buffer.rawlines.len == buffer.lines.len)
  return buffer.lines.len - 1

func lastVisibleLine*(buffer: Buffer): int =
  return min(buffer.fromY + buffer.height - 1, buffer.lastLine())

#doesn't include newline
func lineLength*(buffer: Buffer, line: int): int =
  assert buffer.lines.len > line
  let len = buffer.lines[line] - buffer.lines[line - 1] - 2
  if len >= 0:
    return len
  else:
    return 0

func currentLine*(buffer: Buffer): int =
  return buffer.cursorY - 1

func rawLineLength*(buffer: Buffer, line: int): int =
  assert buffer.rawlines.len > line
  let len = buffer.rawlines[line] - buffer.rawlines[line - 1] - 2
  if len >= 0:
    return len
  else:
    return 0

func currentLineLength*(buffer: Buffer): int =
  return buffer.lineLength(buffer.cursorY)

func currentRawLineLength*(buffer: Buffer): int =
  return buffer.rawLineLength(buffer.cursorY)

func cursorAtLineEnd*(buffer: Buffer): bool =
  return buffer.cursorX == buffer.currentRawLineLength()

func atPercentOf*(buffer: Buffer): int =
  return (100 * buffer.cursorY) div buffer.lastLine()

func visibleText*(buffer: Buffer): string = 
  result = buffer.text.substr(buffer.lines[buffer.fromY], buffer.lines[buffer.lastVisibleLine()])
  result.stripLineEnd()

func lastNode*(buffer: Buffer): HtmlNode =
  return buffer.nodes[^1]

func onNewLine*(buffer: Buffer): bool =
  return buffer.text.len == 0 or buffer.text[^1] == '\n'

func onSpace*(buffer: Buffer): bool =
  return buffer.text.len > 0 and buffer.text[^1] == ' '

func cursorOnNode*(buffer: Buffer, node: HtmlNode): bool =
    return buffer.cursorY >= node.y and buffer.cursorY < node.y + node.height and
           buffer.cursorX >= node.x and buffer.cursorX <= node.x + node.width

func findSelectedElement*(buffer: Buffer): Option[HtmlElement] =
  if buffer.selectedlink != nil and buffer.selectedLink.parentNode of HtmlElement:
    return some(HtmlElement(buffer.selectedlink.parentNode))
  for node in buffer.nodes:
    if node.isElemNode():
      if node.getFmtLen() > 0:
        if buffer.cursorOnNode(node): return some(HtmlElement(node))
  return none(HtmlElement)

func cursorAt*(buffer: Buffer): int =
  return buffer.rawlines[buffer.currentLine()] + buffer.cursorX

func cursorChar*(buffer: Buffer): char =
  return buffer.text[buffer.cursorAt()]

func canScroll*(buffer: Buffer): bool =
  return buffer.lastLine() > buffer.height

func getElementById*(buffer: Buffer, id: string): HtmlElement =
  if buffer.idelements.hasKey(id):
    return buffer.idelements[id]
  return nil

proc findSelectedNode*(buffer: Buffer): Option[HtmlNode] =
  for node in buffer.nodes:
    if node.getFmtLen() > 0 and node.displayed():
      if buffer.cursorY >= node.y and buffer.cursorY <= node.y + node.height and buffer.cursorX >= node.x and buffer.cursorX <= node.x + node.width:
        return some(node)
  return none(HtmlNode)

proc addNode*(buffer: Buffer, htmlNode: HtmlNode) =
  buffer.nodes.add(htmlNode)

  if htmlNode.isTextNode() and htmlNode.parentElement != nil and htmlNode.parentElement.islink:
    buffer.links.add(htmlNode)

  if htmlNode.isElemNode():
    case HtmlElement(htmlNode).tagType
    of TAG_INPUT, TAG_OPTION:
      if not HtmlElement(htmlNode).hidden:
        buffer.clickables.add(htmlNode)
    else: discard
  elif htmlNode.isTextNode():
    if htmlNode.parentElement != nil and htmlNode.parentElement.islink:
      let anchor = htmlNode.ancestor(TAG_A)
      assert(anchor != nil)
      buffer.clickables.add(anchor)

  if htmlNode.isElemNode():
    let elem = HtmlElement(htmlNode)
    buffer.elements.add(elem)
    if elem.id != "" and not buffer.idelements.hasKey(elem.id):
      buffer.idelements[elem.id] = elem

proc writefmt*(buffer: Buffer, str: string) =
  buffer.text &= str
  if buffer.printwrite:
    stdout.write(str)

proc writefmt*(buffer: Buffer, c: char) =
  buffer.text &= c
  if buffer.printwrite:
    stdout.write(c)

proc writeraw*(buffer: Buffer, str: string) =
  buffer.rawtext &= str

proc writeraw*(buffer: Buffer, c: char) =
  buffer.rawtext &= c

proc write*(buffer: Buffer, str: string) =
  buffer.writefmt(str)
  buffer.writeraw(str)

proc write*(buffer: Buffer, c: char) =
  buffer.writefmt(c)
  buffer.writeraw(c)

proc clearText*(buffer: Buffer) =
  buffer.text = ""
  buffer.rawtext = ""
  buffer.lines = @[0]
  buffer.rawlines = @[0]

proc clearNodes*(buffer: Buffer) =
  buffer.nodes.setLen(0)
  buffer.links.setLen(0)
  buffer.clickables.setLen(0)
  buffer.elements.setLen(0)
  buffer.idelements.clear()

proc clearBuffer*(buffer: Buffer) =
  buffer.clearText()
  buffer.clearNodes()
  buffer.cursorX = 0
  buffer.cursorY = 1
  buffer.fromX = 0
  buffer.fromY = 0
  buffer.hovertext = ""

proc scrollTo*(buffer: Buffer, y: int): bool =
  if y == buffer.fromY:
    return false
  buffer.fromY = min(max(buffer.lastLine() - buffer.height + 1, 0), y)
  buffer.cursorY = min(max(buffer.fromY, buffer.cursorY), buffer.fromY + buffer.height)
  return true

proc cursorTo*(buffer: Buffer, x: int, y: int): bool =
  buffer.cursorY = min(max(y, 0), buffer.lastLine())
  if buffer.fromY > buffer.cursorY:
    buffer.fromY = min(buffer.cursorY, buffer.lastLine() - buffer.height)
  elif buffer.fromY + buffer.height < buffer.cursorY:
    buffer.fromY = max(buffer.cursorY - buffer.height, 0)
  buffer.cursorX = min(max(x, 0), buffer.currentRawLineLength())
  buffer.fromX = min(max(buffer.currentRawLineLength() - buffer.width + 1, 0), 0) #TODO
  return true

proc cursorDown*(buffer: Buffer): bool =
  if buffer.cursorY < buffer.lastLine():
    buffer.cursorY += 1
    if buffer.cursorX > buffer.currentRawLineLength():
      if buffer.xend == 0:
        buffer.xend = buffer.cursorX
      buffer.cursorX = buffer.currentRawLineLength()
    elif buffer.xend > 0:
      buffer.cursorX = min(buffer.currentRawLineLength(), buffer.xend)
    if buffer.cursorY > buffer.lastVisibleLine():
      buffer.fromY += 1
      return true
  return false

proc cursorUp*(buffer: Buffer): bool =
  if buffer.cursorY > 1:
    buffer.cursorY -= 1
    if buffer.cursorX > buffer.currentRawLineLength():
      if buffer.xend == 0:
        buffer.xend = buffer.cursorX
      buffer.cursorX = buffer.currentRawLineLength()
    elif buffer.xend > 0:
      buffer.cursorX = min(buffer.currentRawLineLength(), buffer.xend)
    if buffer.cursorY <= buffer.fromY:
      buffer.fromY -= 1
      return true
  return false

proc cursorRight*(buffer: Buffer): bool =
  if buffer.cursorX < buffer.currentRawLineLength():
    buffer.cursorX += 1
    buffer.xend = 0
  else:
    buffer.xend = buffer.cursorX
  return false

proc cursorLeft*(buffer: Buffer): bool =
  if buffer.cursorX > 0:
    buffer.cursorX -= 1
  buffer.xend = 0
  return false

proc cursorLineBegin*(buffer: Buffer) =
  buffer.cursorX = 0
  buffer.xend = 0

proc cursorLineEnd*(buffer: Buffer) =
  buffer.cursorX = buffer.currentRawLineLength()
  buffer.xend = buffer.cursorX

proc cursorNextNode*(buffer: Buffer):  bool =
  if buffer.cursorAtLineEnd():
    if buffer.cursorY < buffer.lastLine():
      let ret = buffer.cursorDown()
      buffer.cursorLineEnd()
      return ret
    else:
      buffer.cursorLineBegin()
      return false

  let selectedNode = buffer.findSelectedNode()
  var res = buffer.cursorRight()
  if selectedNode.isNone:
    return res
  while buffer.findSelectedNode().isNone or buffer.findSelectedNode().get() == selectedNode.get():
    if buffer.cursorAtLineEnd():
      return res
    res = buffer.cursorRight()

proc cursorNextWord*(buffer: Buffer): bool =
  if buffer.cursorAtLineEnd():
    if buffer.cursorY < buffer.lastLine():
      let ret = buffer.cursorDown()
      buffer.cursorLineBegin()
      return ret
    else:
      buffer.cursorLineEnd()
      return false

  var res = buffer.cursorRight()
  while buffer.rawtext[buffer.rawlines[buffer.currentLine()] + buffer.cursorX] != ' ':
    if buffer.cursorAtLineEnd():
      return res
    res = res or buffer.cursorRight()

proc cursorPrevNode*(buffer: Buffer): bool =
  if buffer.cursorX <= 1:
    if buffer.cursorY > 1:
      let res = buffer.cursorUp()
      buffer.cursorLineEnd()
      return res
    else:
      buffer.cursorLineBegin()
      return false

  let selectedNode = buffer.findSelectedNode()
  var res = buffer.cursorLeft()
  if selectedNode.isNone:
    return res
  while buffer.findSelectedNode().isNone or buffer.findSelectedNode().get() == selectedNode.get():
    if buffer.cursorX == 0:
      return res
    res = res or buffer.cursorLeft()

proc cursorPrevWord*(buffer: Buffer): bool =
  if buffer.cursorX <= 1:
    if buffer.cursorY > 1:
      let ret = buffer.cursorUp()
      buffer.cursorLineEnd()
      return ret
    else:
      buffer.cursorLineBegin()
      return false

  discard buffer.cursorLeft()
  while buffer.rawtext[buffer.rawlines[buffer.currentLine()] + buffer.cursorX] != ' ':
    if buffer.cursorX == 0:
      return false
    discard buffer.cursorLeft()

iterator revclickables*(buffer: Buffer): HtmlNode {.inline.} =
  var i = buffer.clickables.len - 1
  while i >= 0:
    yield buffer.clickables[i]
    i -= 1

proc cursorNextLink*(buffer: Buffer): bool =
  for node in buffer.clickables:
    if node.y > buffer.cursorY or (node.y == buffer.cursorY and node.x > buffer.cursorX):
      return buffer.cursorTo(node.x, node.y)
  return false

proc cursorPrevLink*(buffer: Buffer): bool =
  for node in buffer.revclickables:
    if node.y < buffer.cursorY or (node.y == buffer.cursorY and node.x < buffer.cursorX):
      return buffer.cursorTo(node.x, node.y)
  return false

proc cursorFirstLine*(buffer: Buffer): bool =
  if buffer.fromY > 0:
    buffer.fromY = 0
    result = true
  else:
    result = false

  buffer.cursorY = 1
  buffer.cursorLineBegin()

proc cursorLastLine*(buffer: Buffer): bool =
  if buffer.fromY < buffer.lastLine() - buffer.height:
    buffer.fromY = buffer.lastLine() - (buffer.height - 1)
    result = true
  else:
    result = false
  buffer.cursorY = buffer.lastLine()
  buffer.cursorLineBegin()

proc halfPageUp*(buffer: Buffer): bool =
  buffer.cursorY = max(buffer.cursorY - buffer.height div 2 + 1, 1)
  if buffer.fromY - 1 > buffer.cursorY or true:
    buffer.fromY = max(0, buffer.fromY - buffer.height div 2 + 1)
    return true
  return false

proc halfPageDown*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.cursorY + buffer.height div 2 - 1, buffer.lastLine())
  buffer.fromY = min(max(buffer.lastLine() - buffer.height + 1, 0), buffer.fromY + buffer.height div 2 - 1)
  return true

proc pageUp*(buffer: Buffer): bool =
  buffer.cursorY = max(buffer.cursorY - buffer.height + 1, 1)
  buffer.fromY = max(0, buffer.fromY - buffer.height)
  return true

proc pageDown*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.cursorY + buffer.height div 2 - 1, buffer.lastLine())
  buffer.fromY = min(max(buffer.lastLine() - buffer.height + 1, 0), buffer.fromY + buffer.height div 2)
  return true

proc cursorTop*(buffer: Buffer): bool =
  buffer.cursorY = buffer.fromY + 1
  return false

proc cursorMiddle*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.fromY + buffer.height div 2, buffer.lastLine())
  return false

proc cursorBottom*(buffer: Buffer): bool =
  buffer.cursorY = min(buffer.fromY + buffer.height - 1, buffer.lastLine())
  return false

proc scrollDown*(buffer: Buffer): bool =
  if buffer.fromY + buffer.height <= buffer.lastLine():
    buffer.fromY += 1
    if buffer.fromY >= buffer.cursorY:
      discard buffer.cursorDown()
    return true
  discard buffer.cursorDown()
  return false

proc scrollUp*(buffer: Buffer): bool =
  if buffer.fromY > 0:
    buffer.fromY -= 1
    if buffer.fromY + buffer.height <= buffer.cursorY:
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
      anchor.selected = false
      buffer.selectedlink = nil
      buffer.hovertext = ""
  for node in buffer.links:
    if buffer.cursorOnNode(node):
      buffer.selectedlink = node
      let anchor = node.ancestor(TAG_A)
      assert(anchor != nil)
      anchor.selected = true
      buffer.hovertext = HtmlAnchorElement(anchor).href
      return true
  return false

proc gotoAnchor*(buffer: Buffer): bool =
  if buffer.document.location.anchor != "":
    let node =  buffer.getElementById(buffer.document.location.anchor)
    if node != nil:
      return buffer.scrollTo(node.y)
  return false

proc setLocation*(buffer: Buffer, uri: Uri) =
  buffer.document.location = uri

proc gotoLocation*(buffer: Buffer, uri: Uri) =
  buffer.document.location = buffer.document.location.combine(uri)
