import strutils
import re
import terminal
import options

import fusion/htmlparser
import fusion/htmlparser/xmltree

import twtstr
import twtio

type
  NodeType* =
    enum
    NODE_ELEMENT, NODE_TEXT, NODE_COMMENT
  DisplayType* =
    enum
    DISPLAY_INLINE, DISPLAY_BLOCK, DISPLAY_SINGLE, DISPLAY_LIST_ITEM, DISPLAY_NONE
  InputType* =
    enum
    INPUT_BUTTON, INPUT_CHECKBOX, INPUT_COLOR, INPUT_DATE, INPUT_DATETIME_LOCAL,
    INPUT_EMAIL, INPUT_FILE, INPUT_HIDDEN, INPUT_IMAGE, INPUT_MONTH,
    INPUT_NUMBER, INPUT_PASSWORD, INPUT_RADIO, INPUT_RANGE, INPUT_RESET,
    INPUT_SEARCH, INPUT_SUBMIT, INPUT_TEL, INPUT_TEXT, INPUT_TIME, INPUT_URL,
    INPUT_WEEK, INPUT_UNKNOWN
  WhitespaceType* =
    enum
    WHITESPACE_NORMAL, WHITESPACE_NOWRAP,
    WHITESPACE_PRE, WHITESPACE_PRE_LINE, WHITESPACE_PRE_WRAP,
    WHITESPACE_INITIAL, WHITESPACE_INHERIT

type
  HtmlText* = ref HtmlTextObj
  HtmlTextObj = object
    parent*: HtmlElement
  HtmlElement* = ref HtmlElementObj
  HtmlElementObj = object
    node*: HtmlNode
    id*: string
    name*: string
    value*: string
    centered*: bool
    hidden*: bool
    display*: DisplayType
    innerText*: string
    textNodes*: int
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int
    bold*: bool
    italic*: bool
    underscore*: bool
    islink*: bool
    parent*: HtmlElement
    case htmlTag*: HtmlTag
    of tagInput:
      itype*: InputType
      size*: int
    of tagA:
      href*: string
      selected*: bool
    else:
      discard
  HtmlNode* = ref HtmlNodeObj
  HtmlNodeObj = object
    case nodeType*: NodeType
    of NODE_ELEMENT:
      element*: HtmlElement
    of NODE_TEXT:
      text*: HtmlText
    of NODE_COMMENT:
      comment*: string
    rawtext*: string
    fmttext*: string
    x*: int
    y*: int
    width*: int
    height*: int
    openblock*: bool
    closeblock*: bool
    next*: HtmlNode
    prev*: HtmlNode

func nodeAttr*(node: HtmlNode): HtmlElement =
  case node.nodeType
  of NODE_TEXT: return node.text.parent
  of NODE_ELEMENT: return node.element
  else: assert(false)

func displayed*(node: HtmlNode): bool =
  return node.rawtext.len > 0 and node.nodeAttr().display != DISPLAY_NONE

func isTextNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_TEXT

func isElemNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_ELEMENT

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
  return str.parseInt()

func getInputElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagInput)
  htmlElement.itype = xmlElement.attr("type").toInputType()
  if htmlElement.itype == INPUT_HIDDEN:
    htmlElement.hidden = true
  htmlElement.size = xmlElement.attr("size").toInputSize()
  htmlElement.value = xmlElement.attr("value")
  return htmlElement

func getAnchorElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagA)
  htmlElement.href = xmlElement.attr("href")
  htmlElement.islink = true
  return htmlElement

func getSelectElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagSelect)
  for item in xmlElement.items:
    if item.kind == xnElement:
      if item.tag == "option":
        htmlElement.value = item.attr("value")
        break
  htmlElement.name = xmlElement.attr("name")
  return htmlElement

func getOptionElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagOption)
  htmlElement.value = xmlElement.attr("value")
  if htmlElement.parent.value != htmlElement.value:
    htmlElement.hidden = true
  return htmlElement

func getFormattedInput(htmlElement: HtmlElement): string =
  case htmlElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    let valueFit = fitValueToSize(htmlElement.value, htmlElement.size)
    return valueFit.addAnsiStyle(styleUnderscore).buttonStr()
  of INPUT_SUBMIT:
    return htmlElement.value.buttonStr()
  else: discard

func getRawInput(htmlElement: HtmlElement): string =
  case htmlElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    return "[" & htmlElement.value.fitValueToSize(htmlElement.size) & "]"
  of INPUT_SUBMIT:
    return "[" & htmlElement.value & "]"
  else: discard

func getParent*(htmlElement: HtmlElement, htmlTag: HtmlTag): HtmlElement =
  result = htmlElement
  while result != nil and result.htmlTag != htmlTag:
    result = result.parent

func getRawText*(htmlNode: HtmlNode): string =
  if htmlNode.isElemNode():
    case htmlNode.element.htmlTag
    of tagInput: return htmlNode.element.getRawInput()
    else: return ""
  elif htmlNode.isTextNode():
    if htmlNode.text.parent.htmlTag != tagPre:
      result = htmlNode.rawtext.replace(re"\n")
      if result.strip().len > 0:
        if htmlNode.nodeAttr().display != DISPLAY_INLINE:
          if htmlNode.prev == nil or htmlNode.prev.nodeAttr().display != DISPLAY_INLINE:
            result = result.strip(true, false)
          if htmlNode.next == nil or htmlNode.next.nodeAttr().display != DISPLAY_INLINE:
            result = result.strip(false, true)
      else:
        result = ""
    else:
      result = htmlNode.rawtext.strip()
    if htmlNode.text.parent.htmlTag == tagOption:
      result = "[" & result & "]"
  else:
    assert(false)

func getFmtText*(htmlNode: HtmlNode): string =
  if htmlNode.isElemNode():
    case htmlNode.element.htmlTag
    of tagInput: return htmlNode.element.getFormattedInput()
    else: return ""
  elif htmlNode.isTextNode():
    result = htmlNode.rawtext
    if htmlNode.text.parent.islink:
      result = result.addAnsiFgColor(fgBlue)
      let parent = htmlNode.text.parent.getParent(tagA)
      if parent != nil and parent.selected:
        result = result.addAnsiStyle(styleUnderscore)

    if htmlNode.text.parent.htmlTag == tagOption:
      result = result.addAnsiFgColor(fgRed)

    if htmlNode.text.parent.bold:
      result = result.addAnsiStyle(styleBright)
    if htmlNode.text.parent.italic:
      result = result.addAnsiStyle(styleItalic)
    if htmlNode.text.parent.underscore:
      result = result.addAnsiStyle(styleUnderscore)

proc newElemFromParent(elem: HtmlElement, parentOpt: Option[HtmlElement]): HtmlElement =
  if parentOpt.isSome:
    let parent = parentOpt.get()
    elem.centered = parent.centered
    elem.bold = parent.bold
    elem.italic = parent.italic
    elem.underscore = parent.underscore
    elem.hidden = parent.hidden
    elem.display = parent.display
    #elem.margin = parent.margin
    #elem.margintop = parent.margintop
    #elem.marginbottom = parent.marginbottom
    #elem.marginleft = parent.marginleft
    #elem.marginright = parent.marginright
    elem.parent = parent
    elem.islink = parent.islink

  return elem

proc getHtmlElement*(xmlElement: XmlNode, inherit: Option[HtmlElement]): HtmlElement =
  assert kind(xmlElement) == xnElement
  var htmlElement: HtmlElement
  htmlElement = newElemFromParent(HtmlElement(htmlTag: htmlTag(xmlElement)), inherit)
  htmlElement.id = xmlElement.attr("id")

  if htmlElement.htmlTag in InlineTags:
    htmlElement.display = DISPLAY_INLINE
  elif htmlElement.htmlTag in BlockTags:
    htmlElement.display = DISPLAY_BLOCK
  elif htmlElement.htmlTag in SingleTags:
    htmlElement.display = DISPLAY_SINGLE
  elif htmlElement.htmlTag ==  tagLi:
    htmlElement.display = DISPLAY_LIST_ITEM
  else:
    htmlElement.display = DISPLAY_NONE

  case htmlElement.htmlTag
  of tagCenter:
    htmlElement.centered = true
  of tagB:
    htmlElement.bold = true
  of tagI:
    htmlElement.italic = true
  of tagU:
    htmlElement.underscore = true
  of tagHead:
    htmlElement.hidden = true
  of tagStyle:
    htmlElement.hidden = true
  of tagScript:
    htmlElement.hidden = true
  of tagInput:
    htmlElement = getInputElement(xmlElement, htmlElement)
  of tagA:
    htmlElement = getAnchorElement(xmlElement, htmlElement)
  of tagSelect:
    htmlElement = getSelectElement(xmlElement, htmlElement)
  of tagOption:
    htmlElement = getOptionElement(xmlElement, htmlElement)
  of tagPre, tagTd, tagTh:
    htmlElement.margin = 1
  else:
    discard

  for child in xmlElement.items:
    if child.kind == xnText and child.text.strip().len > 0:
      htmlElement.textNodes += 1
  
  return htmlElement

proc getHtmlText*(parent: HtmlElement): HtmlText =
  return HtmlText(parent: parent)

proc getHtmlNode*(xmlElement: XmlNode, parent: Option[HtmlElement]): HtmlNode =
  case kind(xmlElement)
  of xnElement:
    result = HtmlNode(nodeType: NODE_ELEMENT, element: getHtmlElement(xmlElement, parent))
    result.element.node = result
  of xnText:
    assert(parent.isSome)
    result = HtmlNode(nodeType: NODE_TEXT, text: getHtmlText(parent.get()))
    result.rawtext = xmlElement.text
  of xnComment:
    result = HtmlNode(nodeType: NODE_COMMENT, comment: xmlElement.text)
  of xnCData:
    result = HtmlNode(nodeType: NODE_TEXT, text: getHtmlText(parent.get()))
    result.rawtext = xmlElement.text
  else: assert(false)
  result.rawtext = result.getRawText()
  result.fmttext = result.getFmtText()
