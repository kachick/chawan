import terminal
import uri
import unicode
import strutils
import tables
import streams
import sequtils
import sugar
import algorithm

import css/style
import css/cssparser
import css/selector
import types/enums
import utils/twtstr

const css = staticRead"res/default.css"
let stylesheet = parseCSS(newStringStream(css))

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
    attributes*: Table[string, Attr]
    style*: CSS2Properties
    cssvalues*: seq[CSSComputedValue]

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

func firstElementChild(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[0]

func lastElementChild(node: Node): Element =
  if node.children.len == 0:
    return nil
  return node.children[^1]

func `$`*(element: Element): string =
  return "Element of " & $element.tagType

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
    else:
      result = unicode.strip(chardata.data)
    if htmlNode.parentElement != nil and htmlNode.parentElement.tagType == TAG_OPTION:
      result = result.buttonRaw()
  else:
    assert(false)

func getFmtText*(node: Node): seq[string] =
  if node.isElemNode():
    case HtmlElement(node).tagType
    of TAG_INPUT: return HtmlInputElement(node).getFmtInput()
    else: return @[]
  elif node.isTextNode():
    let chardata = CharacterData(node)
    result &= chardata.data
    if node.parentElement != nil:
      let style = node.getStyle()
      if style.hasColor():
        result = result.ansiFgColor(style.termColor())

      if node.parentElement.tagType == TAG_OPTION:
        result = result.ansiFgColor(fgRed).ansiReset()

      if style.bold:
        result = result.ansiStyle(styleBright).ansiReset()
      if style.fontStyle == FONTSTYLE_ITALIC or style.fontStyle == FONTSTYLE_OBLIQUE:
        result = result.ansiStyle(styleItalic).ansiReset()
      if style.underscore:
        result = result.ansiStyle(styleUnderscore).ansiReset()
    else:
      assert(false, node.rawtext)
  else:
    assert(false)

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
    new(result)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.style = CSS2Properties()

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

func getAttrValue*(element: Element, s: string): string =
  let attr = element.attributes.getOrDefault(s, nil)
  if attr != nil:
    return attr.value
  return ""

#TODO case sensitivity
func attrSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.rel
  of ' ': return sel.attr in elem.attributes
  of '=': return elem.getAttrValue(sel.attr) == sel.value
  of '~': return sel.value in unicode.split(elem.getAttrValue(sel.attr))
  of '|':
    let val = elem.getAttrValue(sel.attr)
    return val == sel.value or sel.value.startsWith(val & '-')
  of '^': return elem.getAttrValue(sel.attr).startsWith(sel.value)
  of '$': return elem.getAttrValue(sel.attr).endsWith(sel.value)
  of '*': return elem.getAttrValue(sel.attr).contains(sel.value)
  else: return false

func pseudoSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.pseudo
  of "first-child": return elem.parentNode.firstElementChild == elem
  of "last-child": return elem.parentNode.lastElementChild == elem
  else: return false

func pseudoElemSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.elem
  of "after": return false
  of "before": return false
  else: return false

func selectorMatches(elem: Element, sel: Selector): bool =
  case sel.t
  of TYPE_SELECTOR:
    return elem.tagType == sel.tag
  of CLASS_SELECTOR:
    return sel.class in elem.classList
  of ID_SELECTOR:
    return sel.id == elem.id
  of ATTR_SELECTOR:
    return elem.attrSelectorMatches(sel)
  of PSEUDO_SELECTOR:
    return pseudoSelectorMatches(elem, sel)
  of PSELEM_SELECTOR:
    return pseudoElemSelectorMatches(elem, sel)
  of UNIVERSAL_SELECTOR:
    return true
  of FUNC_SELECTOR:
    return false

func selectorsMatch(elem: Element, selectors: SelectorList): bool =
  for sel in selectors.sels:
    if not selectorMatches(elem, sel):
      return false
  return true

func selectElems(document: Document, sel: Selector): seq[Element] =
  case sel.t
  of TYPE_SELECTOR:
    return document.type_elements[sel.tag]
  of ID_SELECTOR:
    return document.id_elements[sel.id]
  of CLASS_SELECTOR:
    return document.class_elements[sel.class]
  of UNIVERSAL_SELECTOR:
    return document.all_elements
  of ATTR_SELECTOR:
    return document.all_elements.filter((elem) => attrSelectorMatches(elem, sel))
  of PSEUDO_SELECTOR:
    return document.all_elements.filter((elem) => pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return document.all_elements.filter((elem) => pseudoElemSelectorMatches(elem, sel))
  of FUNC_SELECTOR:
    case sel.name
    of "not":
      return document.all_elements.filter((elem) => not selectorsMatch(elem, sel.selectors))
    of "is", "where":
      return document.all_elements.filter((elem) => selectorsMatch(elem, sel.selectors))
    return newSeq[Element]()

func selectElems(document: Document, selectors: SelectorList): seq[Element] =
  assert(selectors.len > 0)
  let sellist = optimizeSelectorList(selectors)
  result = document.selectElems(selectors[0])
  var i = 1

  while i < sellist.len:
    if sellist[i].t == FUNC_SELECTOR:
      case sellist[i].name
      of "not":
        result = result.filter((elem) => not selectorsMatch(elem, sellist[i].selectors))
      of "is", "where":
        result = result.filter((elem) => selectorsMatch(elem, sellist[i].selectors))
      else: discard
    else:
      result = result.filter((elem) => selectorMatches(elem, sellist[i]))
    inc i

proc querySelector*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseCSSListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))

func calcRules(elem: Element, rules: CSSStylesheet): seq[CSSSimpleBlock] =
  var tosort: seq[tuple[s:int,b:CSSSimpleBlock]]
  for rule in rules.value:
    let selectors = parseSelectors(rule.prelude) #TODO perf: compute this once
    for sel in selectors:
      if elem.selectorsMatch(sel):
        let spec = getSpecificity(sel)
        tosort.add((spec,rule.oblock))

  tosort.sort((x, y) => cmp(x.s,y.s))
  return tosort.map((x) => x.b)

proc applyRules*(document: Document, rules: CSSStylesheet): seq[tuple[e:Element,d:CSSDeclaration]] =
  var stack: seq[Element]

  stack.add(document.root)

  while stack.len > 0:
    let elem = stack.pop()
    for oblock in calcRules(elem, rules):
      let decls = parseCSSListOfDeclarations(oblock.value)
      for item in decls:
        if item of CSSDeclaration:
          let decl = CSSDeclaration(item)
          if decl.important:
            result.add((elem, decl))
          else:
            elem.style.applyProperty(decl)
            elem.cssvalues.add(getComputedValue(decl))

    for child in elem.children:
      stack.add(child)


proc applyDefaultStylesheet*(document: Document) =
  let important = document.applyRules(stylesheet)
  for rule in important:
    rule.e.style.applyProperty(rule.d)
    rule.e.cssvalues.add(getComputedValue(rule.d))

