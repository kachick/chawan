import parsexml
import htmlelement
import streams
import macros

import twtio
import enums
import strutils

type
  ParseState = object
    closed: bool
    parents: seq[HtmlNode]
    parsedNode: HtmlNode

#> no I won't manually write all this down
#> maybe todo to accept stuff other than tagtype (idk how useful that'd be)
#still todo, it'd be very useful
macro genEnumCase(s: string): untyped =
  let casestmt = nnkCaseStmt.newTree() 
  casestmt.add(ident("s"))
  for i in low(TagType) .. high(TagType):
    let ret = nnkReturnStmt.newTree()
    ret.add(newLit(TagType(i)))
    let branch = nnkOfBranch.newTree()
    let enumname = $TagType(i)
    let tagname = enumname.substr("TAG_".len, enumname.len - 1).tolower()
    branch.add(newLit(tagname))
    branch.add(ret)
    casestmt.add(branch)
  let ret = nnkReturnStmt.newTree()
  ret.add(newLit(TAG_UNKNOWN))
  let branch = nnkElse.newTree()
  branch.add(ret)
  casestmt.add(branch)

func tagType(s: string): TagType =
  genEnumCase(s)

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
  else: discard

  if parentNode.isElemNode():
    let parent = HtmlElement(parentNode)
    result.centered = result.centered or parent.centered
    result.bold = result.bold or parent.bold
    result.italic = result.italic or parent.italic
    result.underscore = result.underscore or parent.underscore
    result.hidden = result.hidden or parent.hidden
    result.islink = result.islink or parent.islink

func toInputType*(str: string): InputType =
  case str
  of "button": INPUT_BUTTON
  of "checkbox": INPUT_CHECKBOX
  of "color": INPUT_COLOR
  of "date": INPUT_DATE
  of "datetime_local": INPUT_DATETIME_LOCAL
  of "email": INPUT_EMAIL
  of "file": INPUT_FILE
  of "hidden": INPUT_HIDDEN
  of "image": INPUT_IMAGE
  of "month": INPUT_MONTH
  of "number": INPUT_NUMBER
  of "password": INPUT_PASSWORD
  of "radio": INPUT_RADIO
  of "range": INPUT_RANGE
  of "reset": INPUT_RESET
  of "search": INPUT_SEARCH
  of "submit": INPUT_SUBMIT
  of "tel": INPUT_TEL
  of "text": INPUT_TEXT
  of "time": INPUT_TIME
  of "url": INPUT_URL
  of "week": INPUT_WEEK
  else: INPUT_UNKNOWN

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
    of TAG_INPUT: HtmlInputElement(htmlElement).itype = value.toInputType()
    else: discard
  of "size":
    case htmlElement.tagType
    of TAG_INPUT: HtmlInputElement(htmlElement).size = value.toInputSize()
    else: discard
  else: return

proc closeNode(state: var ParseState) =
  state.parents.setLen(state.parents.len - 1)
  state.closed = true

proc closeSingleNodes(state: var ParseState) =
  if not state.closed and state.parents[^1].isElemNode() and HtmlElement(state.parents[^1]).tagType in SingleTagTypes:
    state.closeNode()

proc processHtmlElement(state: var ParseState, htmlElement: HtmlElement) =
  state.closed = false
  if state.parents[^1].childNodes.len > 0:
    htmlElement.previousSibling = state.parents[^1].childNodes[^1]
    htmlElement.previousSibling.nextSibling = htmlElement
  state.parents[^1].childNodes.add(htmlElement)
  state.parents.add(htmlElement)

proc applyNodeText(htmlNode: HtmlNode) =
  htmlNode.rawtext = htmlNode.getRawText()
  htmlNode.fmttext = htmlNode.getFmtText()

proc nparseHtml*(inputStream: Stream): Document =
  var x: XmlParser
  x.open(inputStream, "")
  var state: ParseState
  let document = newDocument()
  state.parents.add(document)
  while state.parents.len > 0 and x.kind != xmlEof:
    x.next()
    case x.kind
    of xmlComment: discard #TODO
    of xmlElementStart:
      eprint "<" & x.rawdata & ">"
      state.closeSingleNodes()
      let parsedNode = newHtmlElement(tagType(x.rawData), state.parents[^1])
      parsedNode.applyNodeText()
      state.processHtmlElement(parsedNode)
    of xmlElementEnd:
      eprint "</" & x.rawdata & ">"
      state.closeNode()
    of xmlElementOpen:
      var s = "<" & x.rawdata
      state.closeSingleNodes()
      let parsedNode = newHtmlElement(tagType(x.rawData), state.parents[^1])
      x.next()
      while x.kind != xmlElementClose and x.kind != xmlEof:
        if x.kind == xmlAttribute:
          HtmlElement(parsedNode).applyAttribute(x.rawData.tolower(), x.rawData2)
          s &= " " & x.rawdata & "=\"" & x.rawdata2 & "\""
        elif x.kind == xmlError:
          HtmlElement(parsedNode).applyAttribute(x.rawData.tolower(), "")
        elif x.kind == xmlCharData:
          if x.rawData.strip() == "/>":
            break
        else:
          assert(false, "wtf") #TODO
        x.next()
      s &= ">"
      eprint s
      parsedNode.applyNodeText()
      state.processHtmlElement(parsedNode)
    of xmlCharData:
      eprint x.rawdata
      let textNode = new(HtmlNode)
      textNode.nodeType = NODE_TEXT
      state.parents[^1].childNodes.add(textNode)
      textNode.parentNode = state.parents[^1]
      if state.parents[^1].isElemNode():
        textNode.parentElement = HtmlElement(state.parents[^1])
      textNode.rawtext = x.rawData
      textNode.applyNodeText()
    of xmlEntity: discard #TODO
    of xmlEof: break
    else: discard
  return document
