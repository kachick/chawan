import terminal
import uri
import unicode
import strutils
import tables

import twtstr
import twtio
import enums
import style

type
  EventTarget* = ref EventTargetObj
  EventTargetObj = object of RootObj

  Node* = ref NodeObj
  NodeObj = object of EventTargetObj
    nodeType*: NodeType
    childNodes*: seq[Node]
    firstChild*: Node
    isConnected*: bool
    lastChild*: Node
    nextSibling*: Node
    previousSibling*: Node
    parentNode*: Node
    parentElement*: Element
    ownerDocument*: Document

    rawtext*: string
    fmttext*: seq[string]
    x*: int
    y*: int
    ex*: int
    ey*: int
    width*: int
    height*: int
    hidden*: bool

  Attr* = ref AttrObj
  AttrObj = object of NodeObj
    namespaceURI*: string
    prefix*: string
    localName*: string
    name*: string
    value*: string
    ownerElement*: Element

  Document* = ref DocumentObj
  DocumentObj = object of NodeObj
    location*: Uri
    id_elements*: Table[string, Element]
    class_elements*: Table[string, seq[Element]]

  CharacterData* = ref CharacterDataObj
  CharacterDataObj = object of NodeObj
    data*: string
    length*: int

  Text* = ref TextObj
  TextObj = object of CharacterDataObj
    wholeText*: string

  Comment* = ref CommentObj
  CommentObj = object of CharacterDataObj

  Element* = ref ElementObj
  ElementObj = object of NodeObj
    namespaceURI*: string
    prefix*: string
    localName*: string
    tagName*: string
    tagType*: TagType

    id*: string
    classList*: seq[string]
    attributes*: Table[string, Attr]
    style*: CSS2Properties

  HTMLElement* = ref HTMLElementObj
  HTMLElementObj = object of ElementObj

  HTMLInputElement* = ref HTMLInputElementObj
  HTMLInputElementObj = object of HTMLElementObj
    itype*: InputType
    autofocus*: bool
    required*: bool
    value*: string
    size*: int

  HTMLAnchorElement* = ref HTMLAnchorElementObj
  HTMLAnchorElementObj = object of HTMLElementObj
    href*: string

  HTMLSelectElement* = ref HTMLSelectElementObj
  HTMLSelectElementObj = object of HTMLElementObj
    name*: string
    value*: string
    valueSet*: bool

  HTMLOptionElement* = ref HTMLOptionElementObj
  HTMLOptionElementObj = object of HTMLElementObj
    value*: string
  
  HTMLHeadingElement* = ref HTMLHeadingElementObj
  HTMLHeadingElementObj = object of HTMLElementObj
    rank*: uint16

  HTMLBRElement* = ref HTMLBRElementObj
  HTMLBRElementObj = object of HTMLElementObj


func getTagTypeMap(): Table[string, TagType] =
  for i in low(TagType) .. high(TagType):
    let enumname = $TagType(i)
    let tagname = enumname.split('_')[1..^1].join("_").tolower()
    result[tagname] = TagType(i)

func getInputTypeMap(): Table[string, InputType] =
  for i in low(InputType) .. high(InputType):
    let enumname = $InputType(i)
    let tagname = enumname.split('_')[1..^1].join("_").tolower()
    result[tagname] = InputType(i)

const tagTypeMap = getTagTypeMap()
const inputTypeMap = getInputTypeMap()

func tagType*(s: string): TagType =
  if tagTypeMap.hasKey(s):
    return tagTypeMap[s]
  else:
    return TAG_UNKNOWN

func inputType*(s: string): InputType =
  if inputTypeMap.hasKey(s):
    return inputTypeMap[s]
  else:
    return INPUT_UNKNOWN

#TODO
func nodeAttr*(node: Node): HtmlElement =
  case node.nodeType
  of TEXT_NODE: return HtmlElement(node.parentElement)
  of ELEMENT_NODE: return HtmlElement(node)
  else: assert(false)

func getStyle*(node: Node): CSS2Properties =
  case node.nodeType
  of TEXT_NODE: return node.parentElement.style
  of ELEMENT_NODE: return Element(node).style
  else: assert(false)

func displayed*(node: Node): bool =
  return node.rawtext.len > 0 and node.getStyle().display != DISPLAY_NONE

func isTextNode*(node: Node): bool =
  return node.nodeType == TEXT_NODE

func isElemNode*(node: Node): bool =
  return node.nodeType == ELEMENT_NODE

func isComment*(node: Node): bool =
  return node.nodeType == COMMENT_NODE

func isCData*(node: Node): bool =
  return node.nodeType == CDATA_SECTION_NODE

func isDocument*(node: Node): bool =
  return node.nodeType == DOCUMENT_NODE

func getFmtLen*(htmlNode: Node): int =
  return htmlNode.fmttext.join().runeLen()

func getRawLen*(htmlNode: Node): int =
  return htmlNode.rawtext.runeLen()

func firstNode*(htmlNode: Node): bool =
  return htmlNode.parentElement != nil and htmlNode.parentElement.childNodes[0] == htmlNode

func lastNode*(htmlNode: Node): bool =
  return htmlNode.parentElement != nil and htmlNode.parentElement.childNodes[^1] == htmlNode

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
    if not c.isDigit():
      return 20
  return str.parseInt()

func getFmtInput(inputElement: HtmlInputElement): seq[string] =
  case inputElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    let valueFit = fitValueToSize(inputElement.value, inputElement.size)
    return valueFit.ansiStyle(styleUnderscore).ansiReset().buttonFmt()
  of INPUT_SUBMIT:
    return inputElement.value.buttonFmt()
  else: discard

func getRawInput(inputElement: HtmlInputElement): string =
  case inputElement.itype
  of INPUT_TEXT, INPUT_SEARCH:
    return inputElement.value.fitValueToSize(inputElement.size).buttonRaw()
  of INPUT_SUBMIT:
    return inputElement.value.buttonRaw()
  else: discard

#TODO
func ancestor*(htmlNode: Node, tagType: TagType): HtmlElement =
  result = HtmlElement(htmlNode.parentElement)
  while result != nil and result.tagType != tagType:
    result = HtmlElement(result.parentElement)

proc getRawText*(htmlNode: Node): string =
  if htmlNode.isElemNode():
    case HtmlElement(htmlNode).tagType
    of TAG_INPUT: return HtmlInputElement(htmlNode).getRawInput()
    else: return ""
  elif htmlNode.isTextNode():
    let chardata = CharacterData(htmlNode)
    if htmlNode.parentElement != nil and htmlNode.parentElement.tagType != TAG_PRE:
      result = chardata.data.remove("\n")
      if unicode.strip(result).runeLen() > 0:
        if htmlNode.getStyle().display != DISPLAY_INLINE:
          result = unicode.strip(result)
      else:
        result = ""
    else:
      result = unicode.strip(chardata.data)
    if htmlNode.parentElement != nil and htmlNode.parentElement.tagType == TAG_OPTION:
      result = result.buttonRaw()
  else:
    assert(false)

func getFmtText*(htmlNode: Node): seq[string] =
  if htmlNode.isElemNode():
    case HtmlElement(htmlNode).tagType
    of TAG_INPUT: return HtmlInputElement(htmlNode).getFmtInput()
    else: return @[]
  elif htmlNode.isTextNode():
    let chardata = CharacterData(htmlNode)
    result &= chardata.data
    if htmlNode.parentElement != nil:
      if htmlNode.parentElement.style.islink:
        result = result.ansiFgColor(fgBlue).ansiReset()
        let anchor = htmlNode.ancestor(TAG_A)
        if anchor != nil and anchor.style.selected:
          result = result.ansiStyle(styleUnderscore).ansiReset()

      if htmlNode.parentElement.tagType == TAG_OPTION:
        result = result.ansiFgColor(fgRed).ansiReset()

      if htmlNode.parentElement.style.bold:
        result = result.ansiStyle(styleBright).ansiReset()
      if htmlNode.parentElement.style.italic:
        result = result.ansiStyle(styleItalic).ansiReset()
      if htmlNode.parentElement.style.underscore:
        result = result.ansiStyle(styleUnderscore).ansiReset()
    else:
      assert(false, "Uhhhh I'm pretty sure we should have parent elements for text nodes?" & htmlNode.rawtext)
  else:
    assert(false)

func newDocument*(): Document =
  new(result)
  result.nodeType = DOCUMENT_NODE

func newText*(): Text =
  new(result)
  result.nodeType = TEXT_NODE

func newComment*(): Comment =
  new(result)
  result.nodeType = COMMENT_NODE

func newHtmlElement*(tagType: TagType): HTMLElement =
  case tagType
  of TAG_INPUT:
    result = new(HTMLInputElement)
  of TAG_A:
    result = new(HTMLAnchorElement)
  of TAG_SELECT:
    result = new(HTMLSelectElement)
  of TAG_OPTION:
    result = new(HTMLOptionElement)
  of TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6:
    result = new(HTMLHeadingElement)
  of TAG_BR:
    result = new(HTMLBRElement)
  else:
    new(result)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.style = new(CSS2Properties)

func newAttr*(parent: Element, key: string, value: string): Attr =
  new(result)
  result.nodeType = ATTRIBUTE_NODE
  result.ownerElement = parent
  result.name = key
  result.value = value

func getAttrValue*(element: Element, s: string): string =
  let attr = element.attributes.getOrDefault(s, nil)
  if attr != nil:
    return attr.value
  return ""


#type
#  SelectorType = enum
#    TYPE_SELECTOR, ID_SELECTOR, ATTR_SELECTOR, CLASS_SELECTOR, CHILD_SELECTOR,
#    UNIVERSAL_SELECTOR
#
#  Selector = object
#    t: SelectorType
#    s0: string
#    s1: string
#
#proc querySelector*(document: Document, q: string): seq[Element] =
#  #let ss = newStringStream(q)
#  #let cvals = parseCSSListOfComponentValues(ss)
#  #var selectors: seq[Selector]
#  return
#
#  #for cval in cvals:
#  #  if cval of CSSToken:
#  #    case CSSToken(cval).tokenType
#  #    of CSS_DELIM_TOKEN:
#  #      if cval.rvalue == Rune('*'):
#  #        selectors.add(Selector(t))
#  #  printc(cval)
