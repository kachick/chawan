import uri
import tables

import css/values
import types/enums

type
  EventTarget* = ref EventTargetObj
  EventTargetObj = object of RootObj

  Node* = ref NodeObj
  NodeObj = object of EventTargetObj
    nodeType*: NodeType
    childNodes*: seq[Node]
    children*: seq[Element]
    isConnected*: bool
    nextSibling*: Node
    previousSibling*: Node
    parentNode*: Node
    parentElement*: Element
    ownerDocument*: Document

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
    type_elements*: array[low(TagType)..high(TagType), seq[Element]]
    id_elements*: Table[string, seq[Element]]
    class_elements*: Table[string, seq[Element]]
    all_elements*: seq[Element]
    head*: HTMLElement
    body*: HTMLElement
    root*: Element

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
    attributes*: Table[string, string]
    cssvalues*: CSSComputedValues
    cssvalues_before*: CSSComputedValues
    cssvalues_after*: CSSComputedValues
    hover*: bool
    cssapplied*: bool
    rendered*: bool

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

  HTMLSpanElement* = ref HTMLSpanElementObj
  HTMLSpanElementObj = object of HTMLElementObj

  HTMLOptionElement* = ref HTMLOptionElementObj
  HTMLOptionElementObj = object of HTMLElementObj
    value*: string
  
  HTMLHeadingElement* = ref HTMLHeadingElementObj
  HTMLHeadingElementObj = object of HTMLElementObj
    rank*: uint16

  HTMLBRElement* = ref HTMLBRElementObj
  HTMLBRElementObj = object of HTMLElementObj

func firstChild(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[0]

func lastChild(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[^1]

func firstElementChild*(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[0]

func lastElementChild*(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[^1]

func previousElementSibling*(elem: Element): Element =
  var e = elem.previousSibling
  while e != nil:
    if e.nodeType == ELEMENT_NODE:
      return Element(e)
    e = e.previousSibling
  return nil

func nextElementSibling*(elem: Element): Element =
  var e = elem.nextSibling
  while e != nil:
    if e.nodeType == ELEMENT_NODE:
      return Element(e)
    e = e.nextSibling
  return nil

func `$`*(element: Element): string =
  return "Element of " & $element.tagType

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
  of TAG_SPAN:
    result = new(HTMLSpanElement)
  else:
    result = new(HTMLElement)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.cssvalues.rootProperties()

func newDocument*(): Document =
  new(result)
  result.root = newHtmlElement(TAG_HTML)
  result.head = newHtmlElement(TAG_HEAD)
  result.body = newHtmlElement(TAG_BODY)
  result.nodeType = DOCUMENT_NODE

func newAttr*(parent: Element, key: string, value: string): Attr =
  new(result)
  result.nodeType = ATTRIBUTE_NODE
  result.ownerElement = parent
  result.name = key
  result.value = value

func attr*(element: Element, s: string): string =
  return element.attributes.getOrDefault(s, "")
