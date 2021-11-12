import uri
import unicode
import strutils
import tables
import streams
import sequtils
import sugar
import algorithm

import css/style
import css/parser
import css/selector
import types/enums

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
    cssvalues*: CSSComputedValues
    cssvalues_before*: CSSComputedValues
    cssvalues_after*: CSSComputedValues

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

func toInputSize*(str: string): int =
  if str.len == 0:
    return 20
  for c in str:
    if not c.isDigit():
      return 20
  return str.parseInt()

#TODO
func ancestor*(htmlNode: Node, tagType: TagType): HtmlElement =
  result = HtmlElement(htmlNode.parentElement)
  while result != nil and result.tagType != tagType:
    result = HtmlElement(result.parentElement)

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


type SelectResult = object
  success: bool
  pseudo: PseudoElem

func selectres(s: bool, p: PseudoElem = PSEUDO_NONE): SelectResult =
  return SelectResult(success: s, pseudo: p)

func psuccess(s: SelectResult): bool =
  return s.pseudo == PSEUDO_NONE and s.success

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

func pseudoElemSelectorMatches(elem: Element, sel: Selector, pseudo: PseudoElem = PSEUDO_NONE): SelectResult =
  case sel.elem
  of "after": return selectres(true, PSEUDO_AFTER)
  of "before": return selectres(true, PSEUDO_AFTER)
  else: return selectres(false)

func selectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.t
  of TYPE_SELECTOR:
    return selectres(elem.tagType == sel.tag)
  of CLASS_SELECTOR:
    return selectres(sel.class in elem.classList)
  of ID_SELECTOR:
    return selectres(sel.id == elem.id)
  of ATTR_SELECTOR:
    return selectres(elem.attrSelectorMatches(sel))
  of PSEUDO_SELECTOR:
    return selectres(pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return pseudoElemSelectorMatches(elem, sel)
  of UNIVERSAL_SELECTOR:
    return selectres(true)
  of FUNC_SELECTOR:
    return selectres(false)

func selectorsMatch(elem: Element, selectors: SelectorList): SelectResult =
  for sel in selectors.sels:
    let res = selectorMatches(elem, sel)
    if not res.success:
      return selectres(false)
    if res.pseudo != PSEUDO_NONE:
      if result.pseudo != PSEUDO_NONE:
        return selectres(false)
      result.pseudo = res.pseudo
  result.success = true

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
      return document.all_elements.filter((elem) => not selectorsMatch(elem, sel.selectors).psuccess)
    of "is", "where":
      return document.all_elements.filter((elem) => selectorsMatch(elem, sel.selectors).psuccess)
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
        result = result.filter((elem) => not selectorsMatch(elem, sellist[i].selectors).psuccess)
      of "is", "where":
        result = result.filter((elem) => selectorsMatch(elem, sellist[i].selectors).psuccess)
      else: discard
    else:
      result = result.filter((elem) => selectorMatches(elem, sellist[i]).psuccess)
    inc i

proc querySelector*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseCSSListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))


proc applyProperty(elem: Element, decl: CSSDeclaration, pseudo: PseudoElem = PSEUDO_NONE) =
  var parentprops: CSSComputedValues
  if elem.parentElement != nil:
    parentprops = elem.parentElement.cssvalues

  let cval = getComputedValue(decl, parentprops)
  case pseudo
  of PSEUDO_NONE:
    elem.cssvalues[cval.t] = cval
  of PSEUDO_BEFORE:
    elem.cssvalues_before[cval.t] = cval
  of PSEUDO_AFTER:
    elem.cssvalues_after[cval.t] = cval

type ParsedRule = tuple[sels: seq[SelectorList], oblock: CSSSimpleBlock]
type ParsedStylesheet = seq[ParsedRule]

func calcRules(elem: Element, rules: ParsedStylesheet):
    array[low(PseudoElem)..high(PseudoElem), seq[CSSSimpleBlock]] =
  var tosorts: array[low(PseudoElem)..high(PseudoElem), seq[tuple[s:int,b:CSSSimpleBlock]]]
  for rule in rules:
    for sel in rule.sels:
      let match = elem.selectorsMatch(sel)
      if match.success:
        let spec = getSpecificity(sel)
        tosorts[match.pseudo].add((spec,rule.oblock))

  for i in low(PseudoElem)..high(PseudoElem):
    tosorts[i].sort((x, y) => cmp(x.s,y.s))
    result[i] = tosorts[i].map((x) => x.b)

proc applyRules*(document: Document, rules: CSSStylesheet): seq[tuple[e:Element,d:CSSDeclaration]] =
  var stack: seq[Element]

  stack.add(document.head)
  stack.add(document.body)
  document.root.cssvalues = rootProperties()

  let parsed = rules.value.map((x) => (sels: parseSelectors(x.prelude), oblock: x.oblock))
  while stack.len > 0:
    let elem = stack.pop()
    elem.cssvalues = inheritProperties(elem.parentElement.cssvalues)
    let rules_pseudo = calcRules(elem, parsed)
    for pseudo in low(PseudoElem)..high(PseudoElem):
      let rules = rules_pseudo[pseudo]
      for rule in rules:
        let decls = parseCSSListOfDeclarations(rule.value)
        for item in decls:
          if item of CSSDeclaration:
            let decl = CSSDeclaration(item)
            if decl.important:
              result.add((elem, decl))
            else:
              elem.applyProperty(decl, pseudo)

    var i = elem.children.len - 1
    while i >= 0:
      let child = elem.children[i]
      stack.add(child)
      dec i

proc applyAuthorRules*(document: Document): seq[tuple[e:Element,d:CSSDeclaration]] =
  var stack: seq[Element]
  var embedded_rules: seq[ParsedStylesheet]

  stack.add(document.head)
  var rules_head = ""

  for child in document.head.children:
    if child.tagType == TAG_STYLE:
      for ct in child.childNodes:
        if ct.nodeType == TEXT_NODE:
          rules_head &= Text(ct).data

  
  stack.setLen(0)

  stack.add(document.body)

  if rules_head.len > 0:
    let parsed = parseCSS(newStringStream(rules_head)).value.map((x) => (sels: parseSelectors(x.prelude), oblock: x.oblock))
    embedded_rules.add(parsed)

  while stack.len > 0:
    let elem = stack.pop()
    var rules_local = ""
    for child in elem.children:
      if child.tagType == TAG_STYLE:
        for ct in child.childNodes:
          if ct.nodeType == TEXT_NODE:
            rules_local &= Text(ct).data

    if rules_local.len > 0:
      let parsed = parseCSS(newStringStream(rules_local)).value.map((x) => (sels: parseSelectors(x.prelude), oblock: x.oblock))
      embedded_rules.add(parsed)
    let this_rules = embedded_rules.concat()
    let rules_pseudo = calcRules(elem, this_rules)

    for pseudo in low(PseudoElem)..high(PseudoElem):
      let rules = rules_pseudo[pseudo]
      for rule in rules:
        let decls = parseCSSListOfDeclarations(rule.value)
        for item in decls:
          if item of CSSDeclaration:
            let decl = CSSDeclaration(item)
            if decl.important:
              result.add((elem, decl))
            else:
              elem.applyProperty(decl, pseudo)

    var i = elem.children.len - 1
    while i >= 0:
      let child = elem.children[i]
      stack.add(child)
      dec i

    if rules_local.len > 0:
      discard embedded_rules.pop()

proc applyStylesheets*(document: Document) =
  let important_ua = document.applyRules(stylesheet)
  let important_author = document.applyAuthorRules()
  for rule in important_author:
    rule.e.applyProperty(rule.d)
  for rule in important_ua:
    rule.e.applyProperty(rule.d)

