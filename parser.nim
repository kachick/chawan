import streams
import unicode
import strutils
import tables
import json

import twtio
import enums
import twtstr
import dom
import radixtree

type
  ParseState = object
    stream: Stream
    closed: bool
    parents: seq[Node]
    parsedNode: Node
    a: string
    b: string
    attrs: seq[string]
    in_comment: bool
    in_script: bool
    in_style: bool
    in_noscript: bool
    parentNode: Node
    textNode: Text

#func newHtmlElement(tagType: TagType, parentNode: Node): HtmlElement =
#  case tagType
#  of TAG_INPUT: result = new(HtmlInputElement)
#  of TAG_A: result = new(HtmlAnchorElement)
#  of TAG_SELECT: result = new(HtmlSelectElement)
#  of TAG_OPTION: result = new(HtmlOptionElement)
#  else: result = new(HtmlElement)
#
#  result.nodeType = ELEMENT_NODE
#  result.tagType = tagType
#  result.parentNode = parentNode
#  if parentNode.isElemNode():
#    result.parentElement = HtmlElement(parentNode)
#
#  if tagType in DisplayInlineTags:
#    result.display = DISPLAY_INLINE
#  elif tagType in DisplayBlockTags:
#    result.display = DISPLAY_BLOCK
#  elif tagType in DisplayInlineBlockTags:
#    result.display = DISPLAY_INLINE_BLOCK
#  elif tagType == TAG_LI:
#    result.display = DISPLAY_LIST_ITEM
#  else:
#    result.display = DISPLAY_NONE
#
#  case tagType
#  of TAG_CENTER:
#    result.centered = true
#  of TAG_B:
#    result.bold = true
#  of TAG_I:
#    result.italic = true
#  of TAG_U:
#    result.underscore = true
#  of TAG_HEAD:
#    result.hidden = true
#  of TAG_STYLE:
#    result.hidden = true
#  of TAG_SCRIPT:
#    result.hidden = true
#  of TAG_OPTION:
#    result.hidden = true #TODO
#  of TAG_PRE, TAG_TD, TAG_TH:
#    result.margin = 1
#  of TAG_UL, TAG_OL:
#    result.indent = 2
#    result.margin = 1
#  of TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6:
#    result.bold = true
#    result.margin = 1
#  of TAG_A:
#    result.islink = true
#  of TAG_INPUT:
#    HtmlInputElement(result).size = 20
#  else: discard
#
#  if parentNode.isElemNode():
#    let parent = HtmlElement(parentNode)
#    result.centered = result.centered or parent.centered
#    result.bold = result.bold or parent.bold
#    result.italic = result.italic or parent.italic
#    result.underscore = result.underscore or parent.underscore
#    result.hidden = result.hidden or parent.hidden
#    result.islink = result.islink or parent.islink

func inputSize*(str: string): int =
  if str.len == 0:
    return 20
  for c in str:
    if not c.isDigit:
      return 20
  return str.parseInt()

proc genEntityMap(): RadixTree[string] =
  let entity = staticRead"entity.json"
  let entityJson = parseJson(entity)
  var entityMap = newRadixTree[string]()

  for k, v in entityJson:
    entityMap[k.substr(1)] = v{"characters"}.getStr()

  return entityMap

const entityMap = genEntityMap()

func genHexCharMap(): seq[int] =
  for i in 0..255:
    case chr(i)
    of '0'..'9': result &= i - ord('0')
    of 'a'..'f': result &= i - ord('a') + 10
    of 'A'..'F': result &= i - ord('A') + 10
    else: result &= -1

func genDecCharMap(): seq[int] =
  for i in 0..255:
    case chr(i)
    of '0'..'9': result &= i - ord('0')
    else: result &= -1

const hexCharMap = genHexCharMap()
const decCharMap = genDecCharMap()

#w3m's getescapecmd and parse_tag, transpiled to nim.
#(C) Copyright 1994-2002 by Akinori Ito
#(C) Copyright 2002-2011 by Akinori Ito, Hironori Sakamoto, Fumitoshi Ukai
#
#Use, modification and redistribution of this software is hereby granted,
#provided that this entire copyright notice is included on any copies of
#this software and applications and derivations thereof.
#
#This software is provided on an "as is" basis, without warranty of any
#kind, either expressed or implied, as to any matter including, but not
#limited to warranty of fitness of purpose, or merchantability, or
#results obtained from use of this software.
proc getescapecmd(buf: string, at: var int): string =
  var i = at

  if buf[i] == '#': #num
    inc i
    var num: int
    if buf[i].tolower() == 'x': #hex
      inc i
      if not isdigit(buf[i]):
        at = i
        return ""

      num = hexCharMap[int(buf[i])]
      inc i
      while i < buf.len and hexCharMap[int(buf[i])] != -1:
        num *= 0x10
        num += hexCharMap[int(buf[i])]
        inc i
    else: #dec
      if not isDigit(buf[i]):
        at = i
        return ""

      num = decCharMap[int(buf[i])]
      inc i
      while i < buf.len and isDigit(buf[i]):
        num *= 10
        num += decCharMap[int(buf[i])]
        inc i

    if buf[i] == ';':
      inc i
    at = i
    return $(Rune(num))
  elif not isAlphaAscii(buf[i]):
    return ""

  var n: uint16 = 0
  var s = ""
  while true:
    let c = buf[i]
    s &= c
    if not entityMap.hasPrefix(s, n):
      break
    let pn = n
    n = entityMap.getPrefix(s, n)
    if n != pn:
      s = ""
    inc i

  if entityMap.nodes[n].leaf:
    at = i
    return entityMap.nodes[n].value

  return ""

type
  DOMParsedTag = object
    tagid: TagType
    attrs: Table[string, string]
    open: bool

proc parse_tag(buf: string, at: var int): DOMParsedTag =
  var tag = DOMParsedTag()
  tag.open = true

  #Parse tag name
  var tagname = ""
  inc at
  if buf[at] == '/':
    inc at
    tag.open = false
    skipBlanks(buf, at)

  while at < buf.len and not buf[at].isWhitespace() and not (tag.open and buf[at] == '/') and buf[at] != '>':
    tagname &= buf[at].tolower()
    at += buf.runeLenAt(at)

  tag.tagid = tagType(tagname)
  skipBlanks(buf, at)

  while at < buf.len and buf[at] != '>':
    var value = ""
    var attrname = ""
    while at < buf.len and buf[at] != '=' and not buf[at].isWhitespace() and buf[at] != '>':
      attrname &= buf[at].tolower()
      at += buf.runeLenAt(at)

    skipBlanks(buf, at)
    if buf[at] == '=':
      inc at
      skipBlanks(buf, at)
      if at < buf.len and (buf[at] == '"' or buf[at] == '\''):
        let startc = buf[at]
        inc at
        while at < buf.len and buf[at] != startc:
          var r: Rune
          fastRuneAt(buf, at, r)
          if r == Rune('&'):
            value &= getescapecmd(buf, at)
          else:
            value &= $r
        if at < buf.len:
          inc at
      elif at < buf.len:
        while at < buf.len and not buf[at].isWhitespace() and buf[at] != '>':
          value &= buf[at]
          at += buf.runeLenAt(at)

    if attrname.len > 0:
      tag.attrs[attrname] = value

  while at < buf.len and buf[at] != '>':
    at += buf.runeLenAt(at)

  if at < buf.len and buf[at] == '>':
    inc at
  return tag

proc insertNode(parent: Node, node: Node) =
  parent.childNodes.add(node)

  if parent.firstChild == nil:
    parent.firstChild = node

  parent.lastChild = node

  if parent.childNodes.len > 1:
    let prevSibling = parent.childNodes[^1]
    prevSibling.nextSibling = node
    node.previousSibling = prevSibling

  node.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    node.parentElement = Element(parent)

  if parent.ownerDocument != nil:
    node.ownerDocument = parent.ownerDocument
  elif parent.nodeType == DOCUMENT_NODE:
    node.ownerDocument = Document(parent)

proc processDocumentStartNode(state: var ParseState, newNode: Node) =
  insertNode(state.parentNode, newNode)
  state.parentNode = newNode

proc processDocumentEndNode(state: var ParseState) =
  if state.parentNode == nil or state.parentNode.parentNode == nil:
    return
  state.parentNode = state.parentNode.parentNode

proc processDocumentText(state: var ParseState) =
  if state.textNode == nil:
    state.textNode = newText()

    processDocumentStartNode(state, state.textNode)
    processDocumentEndNode(state)

proc processDocumentStartElement(state: var ParseState, element: Element, tag: DOMParsedTag) =
  for k, v in tag.attrs:
    element.attributes[k] = element.newAttr(k, v)
  
  element.id = element.getAttrValue("id")
  if element.attributes.hasKey("class"):
    for w in unicode.split(element.attributes["class"].value, Rune(' ')):
      element.classList.add(w)

  case element.tagType
  of TAG_SCRIPT:
    state.in_script = true
  of TAG_NOSCRIPT:
    state.in_noscript = true
  of TAG_STYLE:
    state.in_style = true
  of TAG_SELECT:
    HTMLSelectElement(element).name = element.getAttrValue("name")
    HTMLSelectElement(element).value = element.getAttrValue("value")
  of TAG_INPUT:
    HTMLInputElement(element).value = element.getAttrValue("value")
    HTMLInputElement(element).itype = element.getAttrValue("type").inputType()
    HTMLInputElement(element).size = element.getAttrValue("size").inputSize()
  of TAG_A:
    HTMLAnchorElement(element).href = element.getAttrValue("href")
  of TAG_OPTION:
    HTMLOptionElement(element).value = element.getAttrValue("href")
  else: discard

  if state.parentNode.nodeType == ELEMENT_NODE:
    case element.tagType
    of TAG_LI, TAG_P:
      if Element(state.parentNode).tagType == element.tagType:
        processDocumentEndNode(state)
    of TAG_H1:
      HTMLHeadingElement(element).rank = 1
    of TAG_H2:
      HTMLHeadingElement(element).rank = 2
    of TAG_H3:
      HTMLHeadingElement(element).rank = 3
    of TAG_H4:
      HTMLHeadingElement(element).rank = 4
    of TAG_H5:
      HTMLHeadingElement(element).rank = 5
    of TAG_H6:
      HTMLHeadingElement(element).rank = 6
    else: discard

  processDocumentStartNode(state, element)

  if element.tagType in VoidTagTypes:
    processDocumentEndNode(state)

proc processDocumentEndElement(state: var ParseState, tag: DOMParsedTag) =
  if tag.tagid in VoidTagTypes:
    return
  if state.parentNode.nodeType == ELEMENT_NODE:
    if Element(state.parentNode).tagType in {TAG_LI, TAG_P}:
      processDocumentEndNode(state)
  
  processDocumentEndNode(state)

proc processDocumentTag(state: var ParseState, tag: DOMParsedTag) =
  if state.in_script:
    if tag.tagid == TAG_SCRIPT:
      state.in_script = false
    else:
      return

  if state.in_style:
    if tag.tagid == TAG_STYLE:
      state.in_style = false
    else:
      return

  if state.in_noscript:
    if tag.tagid == TAG_NOSCRIPT:
      state.in_noscript = false
    else:
      return

  if tag.open:
    processDocumentStartElement(state, newHtmlElement(tag.tagid), tag)
  else:
    processDocumentEndElement(state, tag)
  #XXX PROCDOCCASE stuff... good lord I'll never finish this thing

proc processDocumentPart(state: var ParseState, buf: string) =
  var at = 0
  var max = 0
  var was_script = false

  max = buf.len

  while at < max:
    case buf[at]
    of '&':
      inc at
      let p = getescapecmd(buf, at)
      if state.in_comment:
        CharacterData(state.parentNode).data &= p
      else:
        processDocumentText(state)
        state.textNode.data &= p
    of '<':
      if state.in_comment:
        CharacterData(state.parentNode).data &= buf[at]
        inc at
      else:
        var p = at
        inc p
        if p < max and buf[p] == '!':
          inc p
          if p < max and buf[p] == '-':
            inc p
            if p < max and buf[p] == '-':
              inc p
              at = p
              state.in_comment = true
              processDocumentStartNode(state, newComment())
              if state.textNode != nil:
                state.textNode.rawtext = state.textNode.getRawText()
                state.textNode = nil

        if not state.in_comment:
          if state.textNode != nil:
            state.textNode.rawtext = state.textNode.getRawText()
            state.textNode = nil
          p = at
          var tag = parse_tag(buf, at)
          was_script = state.in_script

          processDocumentTag(state, tag)
#         if (was_script) {
#             if (state->in_script) {
#                 ptr = p;
#                 processDocumentText(&state->parentNode, &state->textNode);
#                 Strcat_char(((CharacterData *)state->textNode)->data, *ptr++);
#             } else if (buffer->javascript_enabled) {
#                 loadJSToBuffer(buffer, childTextContentNode(state->parentNode->lastChild)->ptr, "<inline>", state->document);
#             }
#         }
    elif buf[at] == '-' and state.in_comment:
      var p = at
      inc p
      if p < max and buf[p] == '-':
        inc p
        if p < max and buf[p] == '>':
          inc p
          at = p
          state.in_comment = false
          processDocumentEndNode(state)

      if state.in_comment:
        CharacterData(state.parentNode).data &= buf[at]
        inc at
    else:
      var r: Rune
      fastRuneAt(buf, at, r)
      if state.in_comment:
        CharacterData(state.parentNode).data &= $r
      else:
        processDocumentText(state)
        state.textNode.data &= $r

proc parseHtml*(inputStream: Stream): Document =
  let document = newDocument()

  var state = ParseState(stream: inputStream)
  state.parentNode = document

  var till_when = false

  var buf = ""
  var lineBuf: string
  while not inputStream.atEnd():
    lineBuf = inputStream.readLine()
    if lineBuf.len == 0:
      break
    buf &= lineBuf

    var at = 0
    while at < lineBuf.len:
      case lineBuf[at]
      of '<':
        till_when = true
      of '>':
        till_when = false
      else: discard
      at += lineBuf.runeLenAt(at)

    if till_when:
      continue

    processDocumentPart(state, buf)
    buf = ""

  inputStream.close()
  return document
