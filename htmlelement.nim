import strutils
import terminal
import uri
import unicode

import fusion/htmlparser
import fusion/htmlparser/xmltree

import twtstr
import twtio
import enums
import macros

type
  HtmlNode* = ref HtmlNodeObj
  HtmlNodeObj = object of RootObj
    nodeType*: NodeType
    childNodes*: seq[HtmlNode]
    firstChild*: HtmlNode
    isConnected*: bool
    lastChild*: HtmlNode
    nextSibling*: HtmlNode
    previousSibling*: HtmlNode
    parentNode*: HtmlNode
    parentElement*: HtmlElement

    rawtext*: ustring
    fmttext*: ustring
    x*: int
    y*: int
    width*: int
    height*: int
    openblock*: bool
    closeblock*: bool
    hidden*: bool

  Document* = ref DocumentObj
  DocumentObj = object of HtmlNodeObj
    location*: Uri

  HtmlElement* = ref HtmlElementObj
  HtmlElementObj = object of HtmlNodeObj
    id*: string
    tagType*: TagType
    name*: string
    centered*: bool
    display*: DisplayType
    innerText*: string
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int
    bold*: bool
    italic*: bool
    underscore*: bool
    islink*: bool
    selected*: bool

  HtmlInputElement* = ref HtmlInputElementObj
  HtmlInputElementObj = object of HtmlElementObj
    itype*: InputType
    autofocus*: bool
    required*: bool
    value*: string
    size*: int

  HtmlAnchorElement* = ref HtmlAnchorElementObj
  HtmlAnchorElementObj = object of HtmlElementObj
    href*: string

  HtmlSelectElement* = ref HtmlSelectElementObj
  HtmlSelectElementObj = object of HtmlElementObj
    value*: string

  HtmlOptionElement* = ref HtmlOptionElementObj
  HtmlOptionElementObj = object of HtmlElementObj
    value*: string

#no I won't manually write all this down
#maybe todo to accept stuff other than tagtype (idk how useful that'd be)
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

func tagType*(s: string): TagType =
  genEnumCase(s)

func nodeAttr*(node: HtmlNode): HtmlElement =
  case node.nodeType
  of NODE_TEXT: return node.parentElement
  of NODE_ELEMENT: return HtmlElement(node)
  else: assert(false)

func displayed*(node: HtmlNode): bool =
  return node.rawtext.len > 0 and node.nodeAttr().display != DISPLAY_NONE

func isTextNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_TEXT

func isElemNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_ELEMENT

func isComment*(node: HtmlNode): bool =
  return node.nodeType == NODE_COMMENT

func isCData*(node: HtmlNode): bool =
  return node.nodeType == NODE_CDATA

func isDocument*(node: HtmlNode): bool =
  return node.nodeType == NODE_DOCUMENT

func getFmtLen*(htmlNode: HtmlNode): int =
  return htmlNode.fmttext.len

func getRawLen*(htmlNode: HtmlNode): int =
  return htmlNode.rawtext.len

func visibleNode*(node: HtmlNode): bool =
  case node.nodeType
  of NODE_TEXT: return true
  of NODE_ELEMENT: return true
  else: return false

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

func getFmtInput(inputElement: HtmlInputElement): ustring =
  case inputElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    let valueFit = fitValueToSize(inputElement.value.toRunes(), inputElement.size)
    return valueFit.ansiStyle(styleUnderscore).ansiReset().buttonFmt()
  of INPUT_SUBMIT:
    return inputElement.value.toRunes().buttonFmt()
  else: discard

func getRawInput(inputElement: HtmlInputElement): ustring =
  case inputElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    return inputElement.value.toRunes().fitValueToSize(inputElement.size).buttonFmt()
  of INPUT_SUBMIT:
    return inputElement.value.toRunes().buttonFmt()
  else: discard

func getParent*(htmlNode: HtmlNode, tagType: TagType): HtmlElement =
  var pnode = htmlNode.parentElement
  while pnode != nil and pnode.tagType != tagType:
    pnode = pnode.parentElement
  
  return pnode

proc getRawText*(htmlNode: HtmlNode): ustring =
  if htmlNode.isElemNode():
    case HtmlElement(htmlNode).tagType
    of TAG_INPUT: return HtmlInputElement(htmlNode).getRawInput()
    else: return @[]
  elif htmlNode.isTextNode():
    if htmlNode.parentElement != nil and htmlNode.parentElement.tagType != TAG_PRE:
      result = htmlNode.rawtext.remove(runeNewline)
      if unicode.strip($result).toRunes().len > 0:
        if htmlNode.nodeAttr().display != DISPLAY_INLINE:
          if htmlNode.previousSibling == nil or htmlNode.previousSibling.nodeAttr().display != DISPLAY_INLINE:
            result = unicode.strip($result, true, false).toRunes()
          if htmlNode.nextSibling == nil or htmlNode.nextSibling.nodeAttr().display != DISPLAY_INLINE:
            result = unicode.strip($result, false, true).toRunes()
      else:
        result = @[]
    else:
      result = unicode.strip($htmlNode.rawtext).toRunes()
    if htmlNode.parentElement != nil and htmlNode.parentElement.tagType == TAG_OPTION:
      result = result.buttonRaw()
  else:
    assert(false)

func getFmtText*(htmlNode: HtmlNode): ustring =
  if htmlNode.isElemNode():
    case HtmlElement(htmlNode).tagType
    of TAG_INPUT: return HtmlInputElement(htmlNode).getFmtInput()
    else: return @[]
  elif htmlNode.isTextNode():
    result = htmlNode.rawtext
    if htmlNode.parentElement != nil and htmlNode.parentElement.islink:
      result = result.ansiFgColor(fgBlue)
      let parent = HtmlElement(htmlNode.parentNode).getParent(TAG_A)
      if parent != nil and parent.selected:
        result = result.ansiStyle(styleUnderscore).ansiReset()

    if HtmlElement(htmlNode.parentNode).tagType == TAG_OPTION:
      result = result.ansiFgColor(fgRed).ansiReset()

    if HtmlElement(htmlNode.parentNode).bold:
      result = result.ansiStyle(styleBright).ansiReset()
    if HtmlElement(htmlNode.parentNode).italic:
      result = result.ansiStyle(styleItalic).ansiReset()
    if HtmlElement(htmlNode.parentNode).underscore:
      result = result.ansiStyle(styleUnderscore).ansiReset()
  else:
    assert(false)

proc getHtmlElement*(xmlElement: XmlNode, parentNode: HtmlNode): HtmlElement =
  assert kind(xmlElement) == xnElement
  let tagType = xmlElement.tag().tagType()

  case tagType
  of TAG_INPUT: result = new(HtmlInputElement)
  of TAG_A: result = new(HtmlAnchorElement)
  else: new(result)

  result.tagType = tagType
  result.parentNode = parentNode
  if parentNode.isElemNode():
    result.parentElement = HtmlElement(parentNode)

  result.id = xmlElement.attr("id")

  if tagType in InlineTagTypes:
    result.display = DISPLAY_INLINE
  elif tagType in BlockTagTypes:
    result.display = DISPLAY_BLOCK
  elif tagType in SingleTagTypes:
    result.display = DISPLAY_SINGLE
  elif tagType ==  TAG_LI:
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
  of TAG_INPUT:
    let inputElement = HtmlInputElement(result)
    inputElement.itype = xmlElement.attr("type").toInputType()
    if inputElement.itype == INPUT_HIDDEN:
      inputElement.hidden = true
    inputElement.size = xmlElement.attr("size").toInputSize()
    inputElement.value = xmlElement.attr("value")
    result = inputElement
  of TAG_A:
    let anchorElement = HtmlAnchorElement(result)
    anchorElement.href = xmlElement.attr("href")
    anchorElement.islink = true
    result = anchorElement
  of TAG_SELECT:
    var selectElement = new(HtmlSelectElement)
    for item in xmlElement.items:
      if item.kind == xnElement:
        if item.tag == "option":
          selectElement.value = item.attr("value")
          break
    selectElement.name = xmlElement.attr("name")
    result = selectElement
  of TAG_OPTION:
    var optionElement = new(HtmlOptionElement)
    optionElement.value = xmlElement.attr("value")
    if parentNode.isElemNode() and HtmlSelectElement(parentNode).value != optionElement.value:
      optionElement.hidden = true
    result = optionElement
  of TAG_PRE, TAG_TD, TAG_TH:
    result.margin = 1
  else: discard

  if parentNode.isElemNode():
    let parent = HtmlElement(parentNode)
    result.centered = result.centered or parent.centered
    result.bold = result.bold or parent.bold
    result.italic = result.italic or parent.italic
    result.underscore = result.underscore or parent.underscore
    result.hidden = result.hidden or parent.hidden
    result.islink = result.islink or parent.islink
  

proc getHtmlNode*(xmlElement: XmlNode, parent: HtmlNode): HtmlNode =
  case kind(xmlElement)
  of xnElement:
    result = getHtmlElement(xmlElement, parent)
    result.nodeType = NODE_ELEMENT
  of xnText:
    new(result)
    result.nodeType = NODE_TEXT
    result.rawtext = xmlElement.text.toRunes()
  of xnComment:
    new(result)
    result.nodeType = NODE_COMMENT
    result.rawtext = xmlElement.text.toRunes()
  of xnCData:
    new(result)
    result.nodeType = NODE_CDATA
    result.rawtext = xmlElement.text.toRunes()
  else: assert(false)

  result.parentNode = parent
  if parent.isElemNode():
    result.parentElement = HtmlElement(parent)

  result.rawtext = result.getRawText()
  result.fmttext = result.getFmtText()
  if parent.childNodes.len > 0:
    result.previousSibling = parent.childNodes[^1]
    result.previousSibling.nextSibling = result
  parent.childNodes.add(result)

func newDocument*(): Document =
  new(result)
  result.nodeType = NODE_DOCUMENT
