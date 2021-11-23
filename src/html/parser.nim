import streams
import unicode
import strutils
import tables
import json

import types/enums
import types/tagtypes
import utils/twtstr
import utils/radixtree
import html/dom
import html/entity

type
  HTMLParseState = object
    in_comment: bool
    in_script: bool
    in_style: bool
    in_noscript: bool
    in_body: bool
    skip_lf: bool
    elementNode: Element
    textNode: Text
    commentNode: Comment

func inputSize*(str: string): int =
  if str.len == 0:
    return 20
  for c in str:
    if not c.isDigit:
      return 20
  return str.parseInt()

#w3m's getescapecmd and parse_tag, transpiled to nim and heavily modified.
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
        return "&"

      num = hexValue(buf[i])
      inc i
      while i < buf.len and hexValue(buf[i]) != -1:
        num *= 0x10
        num += hexValue(buf[i])
        inc i
    else: #dec
      if not isDigit(buf[i]):
        at = i
        return "&"

      num = decValue(buf[i])
      inc i
      while i < buf.len and isDigit(buf[i]):
        num *= 10
        num += decValue(buf[i])
        inc i

    if buf[i] == ';':
      inc i
    at = i
    return $(Rune(num))
  elif not isAlphaAscii(buf[i]):
    return "&"

  var n = entityMap
  var s = ""
  while true:
    s &= buf[i]
    if not entityMap.hasPrefix(s, n):
      break
    let pn = n
    n = n{s}
    if n != pn:
      s = ""
    inc i

  if n.leaf:
    at = i
    return n.value

  return "&"

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
    at = skipBlanks(buf, at)

  while at < buf.len and not buf[at].isWhitespace() and not (tag.open and buf[at] == '/') and buf[at] != '>':
    tagname &= buf[at].tolower()
    at += buf.runeLenAt(at)

  tag.tagid = tagType(tagname)
  at = skipBlanks(buf, at)

  while at < buf.len and buf[at] != '>':
    var value = ""
    var attrname = ""
    while at < buf.len and buf[at] != '=' and not buf[at].isWhitespace() and buf[at] != '>':
      attrname &= buf[at].tolower()
      at += buf.runeLenAt(at)

    at = skipBlanks(buf, at)
    if buf[at] == '=':
      inc at
      at = skipBlanks(buf, at)
      if at < buf.len and (buf[at] == '"' or buf[at] == '\''):
        let startc = buf[at]
        inc at
        while at < buf.len and buf[at] != startc:
          if buf[at + 1] == '&':
            inc at
            value &= getescapecmd(buf, at)
          else:
            var r: Rune
            fastRuneAt(buf, at, r)
            value &= r
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

  if parent.childNodes.len > 1:
    let prevSibling = parent.childNodes[^2]
    prevSibling.nextSibling = node
    node.previousSibling = prevSibling

  node.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    node.parentElement = Element(parent)

  if parent.ownerDocument != nil:
    node.ownerDocument = parent.ownerDocument
  elif parent.nodeType == DOCUMENT_NODE:
    node.ownerDocument = Document(parent)

  if node.nodeType == ELEMENT_NODE:
    parent.children.add(Element(node))

    let element = (Element(node))
    if element.ownerDocument != nil:
      node.ownerDocument.all_elements.add(Element(node))
      element.ownerDocument.type_elements[element.tagType].add(element)
      if element.id != "":
        if not (element.id in element.ownerDocument.id_elements):
          element.ownerDocument.id_elements[element.id] = newSeq[Element]()
        element.ownerDocument.id_elements[element.id].add(element)

      for c in element.classList:
        if not (c in element.ownerDocument.class_elements):
          element.ownerDocument.class_elements[c] = newSeq[Element]()
        element.ownerDocument.class_elements[c].add(element)

proc processDocumentBody(state: var HTMLParseState) =
  if not state.in_body:
    state.in_body = true
    if state.elementNode.ownerDocument != nil:
      state.elementNode = state.elementNode.ownerDocument.body

proc processDocumentAddNode(state: var HTMLParseState, newNode: Node) =
  if state.elementNode.tagType == TAG_HTML:
    if state.in_body:
      state.elementNode = state.elementNode.ownerDocument.body
    else:
      state.elementNode = state.elementNode.ownerDocument.head

  insertNode(state.elementNode, newNode)

proc processDocumentEndNode(state: var HTMLParseState) =
  if state.elementNode == nil or state.elementNode.nodeType == DOCUMENT_NODE:
    return
  state.elementNode = state.elementNode.parentElement

proc processDocumentText(state: var HTMLParseState) =
  if state.textNode == nil:
    state.textNode = newText()
    processDocumentAddNode(state, state.textNode)

proc processDocumentStartElement(state: var HTMLParseState, element: Element, tag: DOMParsedTag) =
  var add = true

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
  of TAG_HTML:
    add = false
  of TAG_HEAD:
    add = false
    state.in_body = false
    if state.elementNode.ownerDocument != nil:
      state.elementNode = state.elementNode.ownerDocument.head
  of TAG_BODY:
    add = false
  of TAG_PRE:
    state.skip_lf = true
  else: discard

  if not state.in_body and not (element.tagType in HeadTagTypes):
    processDocumentBody(state)

  if state.elementNode.nodeType == ELEMENT_NODE:
    case element.tagType
    of SelfClosingTagTypes:
      if state.elementNode.tagType == element.tagType:
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

    if state.elementNode.tagType == TAG_P and element.tagType in PClosingTagTypes:
      processDocumentEndNode(state)

  if add:
    processDocumentAddNode(state, element)
    state.elementNode = element

  if element.tagType in VoidTagTypes:
    processDocumentEndNode(state)

proc processDocumentEndElement(state: var HTMLParseState, tag: DOMParsedTag) =
  if tag.tagid in VoidTagTypes:
    return
  if tag.tagid == TAG_HEAD:
    processDocumentBody(state)
    return
  if tag.tagid == TAG_BODY:
    return
  if state.elementNode.nodeType == ELEMENT_NODE and tag.tagid != state.elementNode.tagType:
    if state.elementNode.tagType in SelfClosingTagTypes:
      processDocumentEndNode(state)
  
  processDocumentEndNode(state)

proc processDocumentTag(state: var HTMLParseState, tag: DOMParsedTag) =
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

proc processDocumentPart(state: var HTMLParseState, buf: string) =
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
        state.commentNode.data &= p
      else:
        processDocumentText(state)
        state.textNode.data &= p
    of '<':
      if state.in_comment:
        state.commentNode.data &= buf[at]
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
              let comment = newComment()
              state.commentNode = comment
              processDocumentAddNode(state, comment)
              if state.textNode != nil:
                state.textNode = nil
          else:
            #TODO for doctype
            while p < max and buf[p] != '>':
              inc p
            at = p + 1
            continue

        if not state.in_comment:
          if state.textNode != nil:
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
          state.commentNode = nil
          state.in_comment = false

      if state.in_comment:
        state.commentNode.data &= buf[at]
        inc at
    else:
      var r: Rune
      fastRuneAt(buf, at, r)
      if state.in_comment:
        state.commentNode.data &= $r
      else:
        if not (state.skip_lf and r == Rune('\n')):
          processDocumentText(state)
          state.textNode.data &= $r
        state.skip_lf = false

proc parseHtml*(inputStream: Stream): Document =
  let document = newDocument()
  insertNode(document, document.root)
  insertNode(document.root, document.head)
  insertNode(document.root, document.body)

  var state = HTMLParseState()
  state.elementNode = document.root

  var till_when = false

  var buf = ""
  var lineBuf: string
  while not inputStream.atEnd():
    lineBuf = inputStream.readLine() & '\n'
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
