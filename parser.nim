import parsexml
import htmlelement
import streams
import macros
import unicode

import twtio
import enums
import strutils

type
  ParseState = object
    stream: Stream
    closed: bool
    parents: seq[HtmlNode]
    parsedNode: HtmlNode
    a: string
    attrs: seq[string]

  ParseEvent =
    enum
    NO_EVENT, EVENT_COMMENT, EVENT_STARTELEM, EVENT_ENDELEM, EVENT_OPENELEM,
    EVENT_CLOSEELEM, EVENT_ATTRIBUTE, EVENT_TEXT

#> no I won't manually write all this down
#yes this is incredibly ugly
#...but hey, so long as it works

macro genEnumCase(s: string, t: typedesc) =
  result = quote do:
    let casestmt = nnkCaseStmt.newTree() 
    casestmt.add(ident(`s`))
    var first = true
    for e in low(`t`) .. high(`t`):
      if first:
        first = false
        continue
      let ret = nnkReturnStmt.newTree()
      ret.add(newLit(e))
      let branch = nnkOfBranch.newTree()
      let enumname = $e
      let tagname = enumname.split('_')[1..^1].join("_").tolower()
      branch.add(newLit(tagname))
      branch.add(ret)
      casestmt.add(branch)
    let ret = nnkReturnStmt.newTree()
    ret.add(newLit(low(`t`)))
    let branch = nnkElse.newTree()
    branch.add(ret)
    casestmt.add(branch)

macro genTagTypeCase() =
  genEnumCase("s", TagType)

macro genInputTypeCase() =
  genEnumCase("s", InputType)

func tagType(s: string): TagType =
  genTagTypeCase

func inputType(s: string): InputType =
  genInputTypeCase

func newHtmlElement(tagType: TagType, parentNode: HtmlNode): HtmlElement =
  case tagType
  of TAG_INPUT: result = new(HtmlInputElement)
  of TAG_A: result = new(HtmlAnchorElement)
  of TAG_SELECT: result = new(HtmlSelectElement)
  of TAG_OPTION: result = new(HtmlOptionElement)
  else: result = new(HtmlElement)

  result.nodeType = NODE_ELEMENT
  result.tagType = tagType
  result.parentNode = parentNode
  if parentNode.isElemNode():
    result.parentElement = HtmlElement(parentNode)

  if tagType in DisplayInlineTags:
    result.display = DISPLAY_INLINE
  elif tagType in DisplayBlockTags:
    result.display = DISPLAY_BLOCK
  elif tagType in DisplayInlineBlockTags:
    result.display = DISPLAY_INLINE_BLOCK
  elif tagType == TAG_LI:
    result.display = DISPLAY_LIST_ITEM
  else:
    result.display = DISPLAY_NONE

  case tagType
  of TAG_CENTER:
    result.centered = true
  of TAG_B:
    result.bold = true
  of TAG_I:
    result.italic = true
  of TAG_U:
    result.underscore = true
  of TAG_HEAD:
    result.hidden = true
  of TAG_STYLE:
    result.hidden = true
  of TAG_SCRIPT:
    result.hidden = true
  of TAG_OPTION:
    result.hidden = true #TODO
  of TAG_PRE, TAG_TD, TAG_TH:
    result.margin = 1
  of TAG_UL, TAG_OL:
    result.indent = 1
  of TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6:
    result.bold = true
    result.marginbottom = 1
  of TAG_A:
    result.islink = true
  of TAG_INPUT:
    HtmlInputElement(result).size = 20
  else: discard

  if parentNode.isElemNode():
    let parent = HtmlElement(parentNode)
    result.centered = result.centered or parent.centered
    result.bold = result.bold or parent.bold
    result.italic = result.italic or parent.italic
    result.underscore = result.underscore or parent.underscore
    result.hidden = result.hidden or parent.hidden
    result.islink = result.islink or parent.islink

func toInputSize*(str: string): int =
  if str.len == 0:
    return 20
  for c in str:
    if not c.isDigit:
      return 20
  return str.parseInt()

proc applyAttribute(htmlElement: HtmlElement, key: string, value: string) =
  case key
  of "id": htmlElement.id = value
  of "class": htmlElement.class = value
  of "name":
    case htmlElement.tagType
    of TAG_SELECT: HtmlSelectElement(htmlElement).name = value
    else: discard
  of "value":
    case htmlElement.tagType
    of TAG_INPUT: HtmlInputElement(htmlElement).value = value
    of TAG_SELECT: HtmlSelectElement(htmlElement).value = value
    of TAG_OPTION: HtmlOptionElement(htmlElement).value = value
    else: discard
  of "href":
    case htmlElement.tagType
    of TAG_A: HtmlAnchorElement(htmlElement).href = value
    else: discard
  of "type":
    case htmlElement.tagType
    of TAG_INPUT: HtmlInputElement(htmlElement).itype = value.inputType()
    else: discard
  of "size":
    case htmlElement.tagType
    of TAG_INPUT: HtmlInputElement(htmlElement).size = value.toInputSize()
    else: discard
  else: return

proc closeNode(state: var ParseState) =
  let node = state.parents[^1]
  if node.childNodes.len > 0 and node.isElemNode() and HtmlElement(node).display == DISPLAY_BLOCK:
    node.childNodes[0].openblock = true
    node.childNodes[^1].closeblock = true
  state.parents.setLen(state.parents.len - 1)
  state.closed = true

proc closeSingleNodes(state: var ParseState) =
  if not state.closed and state.parents[^1].isElemNode() and HtmlElement(state.parents[^1]).tagType in SingleTagTypes:
    state.closeNode()

proc applyNodeText(htmlNode: HtmlNode) =
  htmlNode.rawtext = htmlNode.getRawText()
  htmlNode.fmttext = htmlNode.getFmtText()

proc setParent(state: var ParseState, htmlNode: HtmlNode) =
  htmlNode.parentNode = state.parents[^1]
  if state.parents[^1].isElemNode():
    htmlNode.parentElement = HtmlElement(state.parents[^1])
  if state.parents[^1].childNodes.len > 0:
    htmlNode.previousSibling = state.parents[^1].childNodes[^1]
    htmlNode.previousSibling.nextSibling = htmlNode
  state.parents[^1].childNodes.add(htmlNode)

proc processHtmlElement(state: var ParseState, htmlElement: HtmlElement) =
  state.closed = false
  state.setParent(htmlElement)
  state.parents.add(htmlElement)

proc parsecomment(state: var ParseState) =
  var s = ""
  state.a = ""
  var e = 0
  while not state.stream.atEnd():
    let c = cast[char](state.stream.readInt8())
    if c > char(127):
      s &= c
      if s.validateUtf8() == -1:
        state.a &= s
        s = ""
    else:
      case e
      of 0:
        if c == '-': inc e
      of 1:
        if c == '-': inc e
        else:
          e = 0
          state.a &= '-' & c
      of 2:
        if c == '>': return
        else:
          e = 0
          state.a &= "--" & c
      else: state.a &= c

proc parsecdata(state: var ParseState) =
  var s = ""
  var e = 0
  while not state.stream.atEnd():
    let c = cast[char](state.stream.readInt8())
    if c > char(127):
      s &= c
      if s.validateUtf8() == -1:
        state.a &= s
        s = ""
    else:
      case e
      of 0:
        if c == ']': inc e
      of 1:
        if c == ']': inc e
        else: e = 0
      of 2:
        if c == '>': return
        else: e = 0
      else: discard
      state.a &= c

proc next(state: var ParseState): ParseEvent =
  result = NO_EVENT
  if state.stream.atEnd(): return result

  var c = cast[char](state.stream.readInt8())
  var cdata = false
  var s = ""
  state.a = ""
  if c < char(128): #ascii
    case c
    of '<':
      if state.stream.atEnd():
        state.a = $c
        return EVENT_TEXT
      let d = char(state.stream.peekInt8())
      case d
      of '/': result = EVENT_ENDELEM
      of '!':
        state.a = state.stream.readStr(2)
        case state.a
        of "[C":
          state.a &= state.stream.readStr(7)
          if state.a == "[CDATA[":
            state.parsecdata()
            return EVENT_COMMENT
          result = EVENT_TEXT
        of "--":
          state.parsecomment()
          return EVENT_COMMENT
        else:
          while not state.stream.atEnd():
            c = cast[char](state.stream.readInt8())
            if s.len == 0 and c == '>':
              break
            elif c > char(127):
              s &= c
              if s.validateUtf8() == -1:
                s = ""
          return NO_EVENT
      of Letters:
        result = EVENT_STARTELEM
      else:
        result = EVENT_TEXT
        state.a = c & d
    of '>':
      return EVENT_CLOSEELEM
    else: result = EVENT_TEXT
  else: result = EVENT_TEXT

  case result
  of EVENT_STARTELEM:
    var atspace = false
    var atattr = false
    while not state.stream.atEnd():
      c = cast[char](state.stream.peekInt8())
      if s.len == 0 and c < char(128):
        case c
        of Whitespace: atspace = true
        of '>':
          discard state.stream.readInt8()
          break
        else:
          if atspace:
            return EVENT_OPENELEM
          else:
            state.a &= s
      else:
        if atspace:
          return EVENT_OPENELEM
        s &= c
        if s.validateUtf8() == -1:
          state.a &= s
          s = ""
      discard state.stream.readInt8()
  of EVENT_ENDELEM:
    while not state.stream.atEnd():
      c = cast[char](state.stream.readInt8())
      if s.len == 0 and c < char(128):
        if c == '>': break
        elif c in Whitespace: discard
        else: state.a &= c
      else:
        s &= c
        if s.validateUtf8() == -1:
          state.a &= s
          s = ""
  of EVENT_TEXT:
    while not state.stream.atEnd():
      c = cast[char](state.stream.peekInt8())
      if s.len == 0 and c < char(128):
        if c in {'<', '>'}: break
        state.a &= c
      else:
        s &= c
        if s.validateUtf8() == -1:
          state.a &= s
          s = ""
      discard state.stream.readInt8()
  else: assert(false)

proc nparseHtml*(inputStream: Stream): Document =
  var state = ParseState(stream: inputStream)
  let document = newDocument()
  state.parents.add(document)
  while state.parents.len > 0 and not inputStream.atEnd():
    let event = state.next()
    case event
    of EVENT_COMMENT: discard #TODO
    of EVENT_STARTELEM:
      state.closeSingleNodes()
      let parsedNode = newHtmlElement(tagType(state.a), state.parents[^1])
      parsedNode.applyNodeText()
      state.processHtmlElement(parsedNode)
    of EVENT_ENDELEM:
      state.closeNode()
    of EVENT_OPENELEM:
      state.closeSingleNodes()
      let parsedNode = newHtmlElement(tagType(state.a), state.parents[^1])
      var next = state.next()
      while next != EVENT_CLOSEELEM and not inputStream.atEnd():
        #TODO
        #if next == EVENT_ATTRIBUTE:
        #  parsedNode.applyAttribute(state.a.tolower(), state.b)
        #  s &= " " & x.rawdata & "=\"" & x.rawdata2 & "\""
        #else:
        #  assert(false, "wtf " & $x.kind & " " & x.rawdata) #TODO
        next = state.next()
      parsedNode.applyNodeText()
      state.processHtmlElement(parsedNode)
    of EVENT_TEXT:
      if unicode.strip(state.a).len == 0:
        continue
      let textNode = new(HtmlNode)
      textNode.nodeType = NODE_TEXT
      state.setParent(textNode)
      textNode.rawtext = state.a
      textNode.applyNodeText()
    else: discard
  return document

#old nparseHtml because I don't trust myself
#proc nparseHtml*(inputStream: Stream): Document =
#  var x: XmlParser
#  let options = {reportWhitespace, allowUnquotedAttribs, allowEmptyAttribs}
#  x.open(inputStream, "", options)
#  var state = ParseState(stream: inputStream)
#  let document = newDocument()
#  state.parents.add(document)
#  while state.parents.len > 0 and x.kind != xmlEof:
#    #let event = state.next()
#    x.next()
#    case x.kind
#    of xmlComment: discard #TODO
#    of xmlElementStart:
#      state.closeSingleNodes()
#      let parsedNode = newHtmlElement(tagType(x.rawData), state.parents[^1])
#      parsedNode.applyNodeText()
#      state.processHtmlElement(parsedNode)
#    of xmlElementEnd:
#      state.closeNode()
#    of xmlElementOpen:
#      var s = "<" & x.rawdata
#      state.closeSingleNodes()
#      let parsedNode = newHtmlElement(tagType(x.rawData), state.parents[^1])
#      x.next()
#      while x.kind != xmlElementClose and x.kind != xmlEof:
#        if x.kind == xmlAttribute:
#          parsedNode.applyAttribute(x.rawData.tolower(), x.rawData2)
#          s &= " " & x.rawdata & "=\"" & x.rawdata2 & "\""
#        else:
#          assert(false, "wtf " & $x.kind & " " & x.rawdata) #TODO
#        x.next()
#      s &= ">"
#      parsedNode.applyNodeText()
#      state.processHtmlElement(parsedNode)
#    of xmlCharData:
#      let textNode = new(HtmlNode)
#      textNode.nodeType = NODE_TEXT
#
#      state.setParent(textNode)
#      textNode.rawtext = x.rawData
#      textNode.applyNodeText()
#    of xmlEntity: discard #TODO
#    of xmlEof: break
#    else: discard
#  return document
