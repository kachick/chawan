import parsexml
import htmlelement
import streams
import macros

import twtio
import enums
import strutils

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

func newHtmlElement(tagType: TagType): HtmlElement =
  case tagType
  of TAG_INPUT: result = new(HtmlInputElement)
  of TAG_A: result = new(HtmlAnchorElement)
  of TAG_SELECT: result = new(HtmlSelectElement)
  of TAG_OPTION: result = new(HtmlOptionElement)
  else: result = new(HtmlElement)
  result.tagType = tagType
  result.nodeType = NODE_ELEMENT

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

var s = ""
proc nparseHtml*(inputStream: Stream): Document =
  var x: XmlParser
  x.open(inputStream, "")
  var parents: seq[HtmlNode]
  let document = newDocument()
  parents.add(document)
  var closed = true
  while parents.len > 0 and x.kind != xmlEof:
    var currParent = parents[^1]
    while true:
      var parsedNode: HtmlNode
      x.next()
      case x.kind
      of xmlComment: discard #TODO
      of xmlElementStart:
        if not closed and currParent.isElemNode() and HtmlElement(currParent).tagType in SingleTagTypes:
          parents.setLen(parents.len - 1)
          currParent = parents[^1]
          closed = true
        eprint "<" & x.rawData & ">"
        parsedNode = newHtmlElement(tagType(x.rawData))
        currParent.childNodes.add(parsedNode)
        if currParent.isElemNode():
          parsedNode.parentElement = HtmlElement(currParent)
        parsedNode.parentNode = currParent
        parents.add(parsedNode)
        closed = false
        break
      of xmlElementEnd:
        eprint "</" & x.rawData & ">"
        parents.setLen(parents.len - 1)
        closed = true
      of xmlElementOpen:
        if not closed and currParent.isElemNode() and HtmlElement(currParent).tagType in SingleTagTypes:
          parents.setLen(parents.len - 1)
          currParent = parents[^1]
          closed = true
        parsedNode = newHtmlElement(tagType(x.rawData))
        s = "<" & x.rawData
        x.next()
        while x.kind != xmlElementClose and x.kind != xmlEof:
          if x.kind == xmlAttribute:
            HtmlElement(parsedNode).applyAttribute(x.rawData.tolower(), x.rawData2)
            s &= " "
            s &= x.rawData
            s &= "=\""
            s &= x.rawData2
            s &= "\""
          x.next()
        s &= ">"
        eprint s

        currParent.childNodes.add(parsedNode)
        if currParent.isElemNode():
          parsedNode.parentElement = HtmlElement(currParent)
        parsedNode.parentNode = currParent
        parents.add(parsedNode)
        closed = false
        break
      of xmlCharData:
        let textNode = new(HtmlNode)
        textNode.nodeType = NODE_TEXT
        textNode.rawtext = x.rawData
        currParent.childNodes.add(textNode)
        textNode.parentNode = currParent
        if currParent.isElemNode():
          textNode.parentElement = HtmlElement(currParent)
        eprint x.rawData, currParent.nodeType
      of xmlEntity:
        eprint "entity", x.rawData
      of xmlEof: break
      else: discard
  return document
