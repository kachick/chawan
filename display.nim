import terminal
import options
import uri
import strutils

import fusion/htmlparser/xmltree
import fusion/htmlparser

import buffer
import termattrs
import htmlelement
import twtstr
import twtio
import config

proc clearStatusMsg*(at: int) =
  setCursorPos(0, at)
  eraseLine()

proc statusMsg*(str: string, at: int) =
  clearStatusMsg(at)
  print(str.addAnsiStyle(styleReverse))

type
  RenderState = object
    x: int
    y: int
    lastwidth: int
    atchar: int
    atrawchar: int
    centerqueue: int
    centerlen: int
    blanklines: int
    blankspaces: int
    nextspaces: int
    docenter: bool
    indent: int
    listval: int

func newRenderState(): RenderState =
  return RenderState(y: 1)

proc flushLine(buffer: Buffer, state: var RenderState) =
  if buffer.onNewLine():
    state.blanklines += 1
  buffer.write('\n')
  state.x = 0
  state.y += 1
  state.atchar += 1
  state.atrawchar += 1
  state.nextspaces = 0
  buffer.lines.add(state.atchar)
  buffer.rawlines.add(state.atrawchar)
  assert(buffer.onNewLine())

proc addSpaces(buffer: Buffer, state: var RenderState, n: int) =
  if state.x + n > buffer.width:
    buffer.flushLine(state)
    return
  state.blankspaces += n
  buffer.write(' '.repeat(n))
  state.x += n
  state.atchar += n
  state.atrawchar += n

proc addSpace(buffer: Buffer, state: var RenderState) =
  buffer.addSpaces(state, 1)

proc addSpacePadding(buffer: Buffer, state: var RenderState) =
  if not buffer.onSpace():
    buffer.addSpace(state)

proc writeWrappedText(buffer: Buffer, state: var RenderState, fmttext: string, rawtext: string) =
  state.lastwidth = 0
  var n = 0
  var fmtword = ""
  var rawword = ""
  var prevl = false
  for c in fmttext:
    fmtword &= c

    if n >= rawtext.len or rawtext[n] != c:
      continue

    rawword &= c
    state.x += 1

    if state.x > buffer.width:
      if buffer.rawtext.len > 0 and buffer.rawtext[^1] == ' ':
        buffer.rawtext = buffer.rawtext.substr(0, buffer.rawtext.len - 2)
        buffer.text = buffer.text.substr(0, buffer.text.len - 2)
        state.atchar -= 1
        state.atrawchar -= 1
        state.x -= 1
      state.lastwidth = max(state.lastwidth, state.x)
      buffer.flushLine(state)
      prevl = true
    else:
      state.lastwidth = max(state.lastwidth, state.x)

    if c == ' ':
      buffer.writefmt(fmtword)
      buffer.writeraw(rawword)
      state.atchar += fmtword.len
      state.atrawchar += rawword.len
      if prevl:
        state.x += rawword.len
        prevl = false
      fmtword = ""
      rawword = ""
    n += 1

  buffer.writefmt(fmtword)
  buffer.writeraw(rawword)
  state.atchar += fmtword.len
  state.atrawchar += rawword.len
  state.lastwidth = max(state.lastwidth, state.x)

proc preAlignNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  let elem = node.nodeAttr()
  if not buffer.onNewLine() and node.openblock and state.blanklines == 0:
    buffer.flushLine(state)

  if node.openblock:
    while state.blanklines < max(elem.margin, elem.margintop):
      buffer.flushLine(state)
    if elem.display == DISPLAY_LIST_ITEM:
      eprint "???"
      state.indent += 1

  if not buffer.onNewLine() and state.blanklines == 0 and node.displayed():
    buffer.addSpaces(state, state.nextspaces)
    state.nextspaces = 0
    if state.blankspaces < max(elem.margin, elem.marginleft):
      buffer.addSpaces(state, max(elem.margin, elem.marginleft) - state.blankspaces)

  if elem.centered and buffer.onNewLine() and node.displayed():
    buffer.addSpaces(state, max(buffer.width div 2 - state.centerlen div 2, 0))
    state.centerlen = 0
  
  if elem.display == DISPLAY_LIST_ITEM and state.indent > 0:
    var listchar = ""
    eprint "Display", listchar, elem.parent.htmlTag
    case elem.parent.htmlTag
    of tagUl:
      listchar = "*"
    of tagOl:
      state.listval += 1
      listchar = $state.listval & ")"
    else:
      return
    buffer.addSpaces(state, state.indent)
    buffer.write(listchar)
    state.x += 1
    state.atchar += 1
    state.atrawchar += 1
    buffer.addSpaces(state, 1)

proc postAlignNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  let elem = node.nodeAttr()

  if node.getRawLen() > 0:
    state.blanklines = 0
    state.blankspaces = 0

  if not buffer.onNewLine() and state.blanklines == 0:
    state.nextspaces += max(elem.margin, elem.marginright)
    if node.closeblock:
      buffer.flushLine(state)

  if node.closeblock:
    while state.blanklines < max(elem.margin, elem.marginbottom):
      buffer.flushLine(state)
    if elem.display == DISPLAY_LIST_ITEM and node.isTextNode():
      state.indent -= 1

  if elem.htmlTag == tagBr and not node.openblock:
    buffer.flushLine(state)

  if elem.display == DISPLAY_LIST_ITEM and node.isElemNode():
    buffer.flushLine(state)

proc renderNode(buffer: Buffer, node: HtmlNode, state: var RenderState) =
  if not node.visibleNode():
    return
  let elem = node.nodeAttr()
  if elem.htmlTag == tagTitle:
    if node.isTextNode():
      buffer.title = node.rawtext
    return
  else: discard
  if elem.hidden: return

  if not state.docenter:
    if elem.centered:
      if not node.closeblock and elem.htmlTag != tagBr:
        state.centerqueue += 1
        return
    if state.centerqueue > 0:
      state.docenter = true
      state.centerlen = 0
      var i = state.centerqueue
      while i > 0:
        state.centerlen += buffer.nodes[^i].getRawLen()
        i -= 1
      while state.centerqueue > 0:
        buffer.renderNode(buffer.nodes[^state.centerqueue], state)
        state.centerqueue -= 1
      state.docenter = false

  buffer.preAlignNode(node, state)

  node.x = state.x
  node.y = state.y
  buffer.writeWrappedText(state, node.fmttext, node.rawtext)
  node.width = state.lastwidth - node.x + 1
  node.height = state.y - node.y + 1

  buffer.postAlignNode(node, state)

iterator revItems*(n: XmlNode): XmlNode {.inline.} =
  var i = n.len - 1
  while i >= 0:
    if n[i].kind != xnComment:
      yield n[i]
    i -= 1

type
  XmlHtmlNode* = ref XmlHtmlNodeObj
  XmlHtmlNodeObj = object
    xml*: XmlNode
    html*: HtmlNode

proc setLastHtmlLine(buffer: Buffer, state: var RenderState) =
  if buffer.text.len != buffer.lines[^1]:
    state.atchar = buffer.text.len + 1
    state.atrawchar = buffer.rawtext.len + 1
  buffer.flushLine(state)

proc renderHtml*(buffer: Buffer) =
  var stack: seq[XmlHtmlNode]
  let first = XmlHtmlNode(xml: buffer.htmlSource,
                         html: getHtmlNode(buffer.htmlSource, none(HtmlElement)))
  stack.add(first)

  var state = newRenderState()
  while stack.len > 0:
    let currElem = stack.pop()
    buffer.renderNode(currElem.html, state)
    buffer.addNode(currElem.html)
    var last = false
    var prev: HtmlNode = nil
    for item in currElem.xml.revItems:
      let child = XmlHtmlNode(xml: item,
                              html: getHtmlNode(item, some(currElem.html.element)))
      stack.add(child)
      child.html.prev = prev
      prev = child.html
      if not last and child.html.visibleNode():
        last = true
        if currElem.html.element.display == DISPLAY_BLOCK:
          stack[^1].html.closeblock = true
      else:
        child.html.next = stack[^1].html
    if last:
      if currElem.html.element.display == DISPLAY_BLOCK:
        stack[^1].html.openblock = true
  buffer.setLastHtmlLine(state)

proc drawHtml(buffer: Buffer) =
  var state = newRenderState()
  for node in buffer.nodes:
    buffer.renderNode(node, state)
  buffer.setLastHtmlLine(state)

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = $buffer.cursorY & "/" & $buffer.lastLine() & " (" &
            $buffer.atPercentOf() & "%) " &
            "<" & buffer.title & ">"
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  statusMsg(msg.maxString(buffer.width), buffer.height)

proc cursorBufferPos(buffer: Buffer) =
  var x = buffer.cursorX
  if x > buffer.currentRawLineLength():
    x = buffer.currentRawLineLength()
  var y = buffer.cursorY - 1 - buffer.fromY
  termGoto(x, y)

proc displayBuffer(buffer: Buffer) =
  eraseScreen()
  termGoto(0, 0)

  print(buffer.visibleText())

proc inputLoop(attrs: TermAttributes, buffer: Buffer): bool =
  var s = ""
  var feedNext = false
  while true:
    cursorBufferPos(buffer)
    if not feedNext:
      s = ""
    else:
      feedNext = false
    let c = getch()
    s &= c
    let action = getNormalAction(s)
    var redraw = false
    var reshape = false
    case action
    of ACTION_QUIT:
      eraseScreen()
      return false
    of ACTION_CURSOR_LEFT: redraw = buffer.cursorLeft()
    of ACTION_CURSOR_DOWN: redraw = buffer.cursorDown()
    of ACTION_CURSOR_UP: redraw = buffer.cursorUp()
    of ACTION_CURSOR_RIGHT: redraw = buffer.cursorRight()
    of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
    of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
    of ACTION_CURSOR_NEXT_WORD: redraw = buffer.cursorNextWord()
    of ACTION_CURSOR_NEXT_NODE: redraw = buffer.cursorNextNode()
    of ACTION_CURSOR_PREV_WORD: redraw = buffer.cursorPrevWord()
    of ACTION_CURSOR_PREV_NODE: redraw = buffer.cursorPrevNode()
    of ACTION_CURSOR_NEXT_LINK: redraw = buffer.cursorNextLink()
    of ACTION_CURSOR_PREV_LINK: redraw = buffer.cursorPrevLink()
    of ACTION_PAGE_DOWN: redraw = buffer.pageDown()
    of ACTION_PAGE_UP: redraw = buffer.pageUp()
    of ACTION_HALF_PAGE_DOWN: redraw = buffer.halfPageDown()
    of ACTION_HALF_PAGE_UP: redraw = buffer.halfPageUp()
    of ACTION_CURSOR_FIRST_LINE: redraw = buffer.cursorFirstLine()
    of ACTION_CURSOR_LAST_LINE: redraw = buffer.cursorLastLine()
    of ACTION_CURSOR_TOP: redraw = buffer.cursorTop()
    of ACTION_CURSOR_MIDDLE: redraw = buffer.cursorMiddle()
    of ACTION_CURSOR_BOTTOM: redraw = buffer.cursorBottom()
    of ACTION_SCROLL_DOWN: redraw = buffer.scrollDown()
    of ACTION_SCROLL_UP: redraw = buffer.scrollUp()
    of ACTION_CLICK:
      let selectedElem = buffer.findSelectedElement()
      if selectedElem.isSome:
        case selectedElem.get().htmlTag
        of tagInput:
          clearStatusMsg(buffer.height)
          let status = readLine("TEXT:", selectedElem.get().value)
          if status:
            reshape = true
            redraw = true
        else: discard
        if selectedElem.get().islink:
          let anchor = buffer.selectedlink.text.parent.getParent(tagA).href
          buffer.setLocation(parseUri(anchor))
          return true
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.location
      clearStatusMsg(buffer.height)
      let status = readLine("URL:", url)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_FEED_NEXT:
      feedNext = true
    of ACTION_RELOAD: return true
    of ACTION_RESHAPE:
      reshape = true
      redraw = true
    of ACTION_REDRAW: redraw = true
    else: discard
    redraw = redraw or buffer.checkLinkSelection()
    if reshape:
      buffer.clearText()
      buffer.drawHtml()
    if redraw:
      buffer.displayBuffer()
    buffer.statusMsgForBuffer()

proc displayPage*(attrs: TermAttributes, buffer: Buffer): bool =
  eraseScreen()
  termGoto(0, 0)
  #buffer.printwrite = true
  discard buffer.gotoAnchor()
  buffer.displayBuffer()
  buffer.statusMsgForBuffer()
  return inputLoop(attrs, buffer)

