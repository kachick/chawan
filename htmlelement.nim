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
    DISPLAY_INLINE, DISPLAY_BLOCK, DISPLAY_SINGLE, DISPLAY_NONE
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
    text*: string
    formattedText*: string
  HtmlElement* = ref HtmlElementObj
  HtmlElementObj = object
    id*: string
    name*: string
    value*: string
    centered*: bool
    hidden*: bool
    display*: DisplayType
    innerText*: string
    formattedElem*: string
    rawElem*: string
    textNodes*: int
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int
    pad*: bool
    bold*: bool
    italic*: bool
    underscore*: bool
    parentElement*: HtmlElement
    case htmlTag*: HtmlTag
    of tagInput:
      itype*: InputType
      size*: int
    of tagA:
      href*: string
      selected*: bool
    else:
      discard

type
  HtmlNode* = ref HtmlNodeObj
  HtmlNodeObj = object
    case nodeType*: NodeType
    of NODE_ELEMENT:
      element*: HtmlElement
    of NODE_TEXT:
      text*: HtmlText
    of NODE_COMMENT:
      comment*: string
    x*: int
    y*: int
    width*: int
    height*: int
    openblock*: bool
    closeblock*: bool

func isTextNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_TEXT

func isElemNode*(node: HtmlNode): bool =
  return node.nodeType == NODE_ELEMENT

func getFormattedLen*(htmlText: HtmlText): int =
  return htmlText.formattedText.strip().len

func getFormattedLen*(htmlElem: HtmlElement): int =
  return htmlElem.formattedElem.len

func getFormattedLen*(htmlNode: HtmlNode): int =
  case htmlNode.nodeType
  of NODE_TEXT: return htmlNode.text.getFormattedLen()
  of NODE_ELEMENT: return htmlNode.element.getFormattedLen()
  else:
    assert(false)
    return 0

func getRawLen*(htmlText: HtmlText): int =
  return htmlText.text.len

func getRawLen*(htmlElem: HtmlElement): int =
  return htmlElem.rawElem.len

func getRawLen*(htmlNode: HtmlNode): int =
  case htmlNode.nodeType
  of NODE_TEXT: return htmlNode.text.getRawLen()
  of NODE_ELEMENT: return htmlNode.element.getRawLen()
  else:
    assert(false)
    return 0

func visibleNode*(node: HtmlNode): bool =
  case node.nodeType
  of NODE_TEXT: return true
  of NODE_ELEMENT: return true
  else: return false

func displayed*(elem: HtmlElement): bool =
  return elem.display != DISPLAY_NONE and (elem.getFormattedLen() > 0 or elem.htmlTag == tagBr) and not elem.hidden

func displayed*(node: HtmlNode): bool =
  if node.isTextNode():
    return node.getRawLen() > 0
  elif node.isElemNode():
    return node.element.displayed()

func empty*(elem: HtmlElement): bool =
  return elem.textNodes == 0 or not elem.displayed()

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
  htmlElement.size = xmlElement.attr("size").toInputSize()
  htmlElement.value = xmlElement.attr("value")
  htmlElement.pad = true
  return htmlElement

func getAnchorElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagA)
  htmlElement.href = xmlElement.attr("href")
  return htmlElement

func getSelectElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagSelect)
  for item in xmlElement.items:
    if item.kind == xnElement:
      if item.tag == "option" and item.attr("value") != "":
        htmlElement.value = item.attr("value")
        break
  htmlElement.name = xmlElement.attr("name")
  return htmlElement

func getOptionElement(xmlElement: XmlNode, htmlElement: HtmlElement): HtmlElement =
  assert(htmlElement.htmlTag == tagOption)
  htmlElement.value = xmlElement.attr("value")
  if htmlElement.parentElement.value != htmlElement.value:
    htmlElement.hidden = true
  return htmlElement

func getFormattedInput(htmlElement: HtmlElement): string =
  case htmlElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    let valueFit = fitValueToSize(htmlElement.value, htmlElement.size)
    return "[" & valueFit.addAnsiStyle(styleUnderscore).addAnsiFgColor(fgRed) & "]"
  of INPUT_SUBMIT: return ("[" & htmlElement.value & "]").addAnsiFgColor(fgRed)
  else: discard

func getRawInput(htmlElement: HtmlElement): string =
  case htmlElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    return "[" & htmlElement.value.fitValueToSize(htmlElement.size) & "]"
  of INPUT_SUBMIT: return "[" & htmlElement.value & "]"
  else: discard

func getRawElem*(htmlElement: HtmlElement): string =
  case htmlElement.htmlTag
  of tagInput: return htmlElement.getRawInput()
  of tagOption: return "[]"
  else: return ""

func getFormattedElem*(htmlElement: HtmlElement): string =
  case htmlElement.htmlTag
  of tagInput: return htmlElement.getFormattedInput()
  else: return ""

func getRawText*(htmlText: HtmlText): string =
  if htmlText.parent.htmlTag != tagPre:
    result = htmlText.text.replace(re"\n").strip()
  else:
    result = htmlText.text

  if htmlText.parent.htmlTag == tagOption:
    result = "[" & result & "]"

func getFormattedText*(htmlText: HtmlText): string =
  result = htmlText.text
  case htmlText.parent.htmlTag
  of tagA:
    result = result.addAnsiFgColor(fgBlue)
    if htmlText.parent.selected:
      result = result.addAnsiStyle(styleUnderscore)
  of tagOption: result = result.addAnsiFgColor(fgRed)
  else: discard

  if htmlText.parent.bold:
    result = result.addAnsiStyle(styleBright)
  if htmlText.parent.italic:
    result = result.addAnsiStyle(styleItalic)
  if htmlText.parent.underscore:
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
    elem.parentElement = parent
  elem.pad = false

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
    htmlElement.pad = true
  elif htmlElement.htmlTag in SingleTags:
    htmlElement.display = DISPLAY_SINGLE
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
  
  htmlElement.rawElem = htmlElement.getRawElem()
  htmlElement.formattedElem = htmlElement.getFormattedElem()
  return htmlElement

proc getHtmlText*(text: string, parent: HtmlElement): HtmlText =
  var textNode = HtmlText(parent: parent, text: text)
  textNode.text = textNode.getRawText()
  textNode.formattedText = textNode.getFormattedText()
  return textNode

proc getHtmlNode*(xmlElement: XmlNode, parent: Option[HtmlElement]): HtmlNode =
  case kind(xmlElement)
  of xnElement:
    return HtmlNode(nodeType: NODE_ELEMENT, element: getHtmlElement(xmlElement, parent))
  of xnText:
    assert(parent.isSome)
    return HtmlNode(nodeType: NODE_TEXT, text: getHtmlText(xmlElement.text, parent.get()))
  of xnComment:
    return HtmlNode(nodeType: NODE_COMMENT, comment: xmlElement.text)
  of xnCData:
    return HtmlNode(nodeType: NODE_TEXT, text: getHtmlText(xmlElement.text, parent.get()))
  else: assert(false)
