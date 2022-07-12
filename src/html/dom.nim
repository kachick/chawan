import tables
import options
import streams
import strutils

import css/values
import css/sheet
import html/tags
import types/url
import utils/twtstr

type
  FormMethod* = enum
    FORM_METHOD_GET, FORM_METHOD_POST, FORM_METHOD_DIALOG

  FormEncodingType* = enum
    FORM_ENCODING_TYPE_URLENCODED = "application/x-www-form-urlencoded",
    FORM_ENCODING_TYPE_MULTIPART = "multipart/form-data",
    FORM_ENCODING_TYPE_TEXT_PLAIN = "text/plain"

  QuirksMode* = enum
    NO_QUIRKS, QUIRKS, LIMITED_QUIRKS

  Namespace* = enum
    HTML = "http://www.w3.org/1999/xhtml",
    MATHML = "http://www.w3.org/1998/Math/MathML",
    SVG = "http://www.w3.org/2000/svg",
    XLINK = "http://www.w3.org/1999/xlink",
    XML = "http://www.w3.org/XML/1998/namespace",
    XMLNS = "http://www.w3.org/2000/xmlns/"

type
  EventTarget* = ref object of RootObj

  Node* = ref object of EventTarget
    nodeType*: NodeType
    childNodes*: seq[Node]
    nextSibling*: Node
    previousSibling*: Node
    parentNode*: Node
    parentElement*: Element
    rootNode: Node
    document*: Document

  Attr* = ref object of Node
    namespaceURI*: string
    prefix*: string
    localName*: string
    name*: string
    value*: string
    ownerElement*: Element

  Document* = ref object of Node
    location*: Url
    mode*: QuirksMode

    parser_cannot_change_the_mode_flag*: bool
    is_iframe_srcdoc*: bool

  CharacterData* = ref object of Node
    data*: string
    length*: int

  Text* = ref object of CharacterData

  Comment* = ref object of CharacterData

  DocumentFragment* = ref object of Node
    host*: Element

  DocumentType* = ref object of Node
    name*: string
    publicId*: string
    systemId*: string

  Element* = ref object of Node
    namespace*: Namespace
    namespacePrefix*: Option[string] #TODO namespaces
    prefix*: string
    localName*: string
    tagType*: TagType

    id*: string
    classList*: seq[string]
    attributes*: Table[string, string]
    css*: CSSComputedValues
    pseudo*: array[PSEUDO_BEFORE..PSEUDO_AFTER, CSSComputedValues]
    hover*: bool
    cssapplied*: bool
    rendered*: bool

  HTMLElement* = ref object of Element

  HTMLInputElement* = ref object of HTMLElement
    inputType*: InputType
    autofocus*: bool
    required*: bool
    value*: string
    size*: int
    checked*: bool
    xcoord*: int
    ycoord*: int
    file*: Option[Url]
    form*: HTMLFormElement

  HTMLAnchorElement* = ref object of HTMLElement

  HTMLSelectElement* = ref object of HTMLElement
    name*: string
    value*: string
    valueSet*: bool

  HTMLSpanElement* = ref object of HTMLElement

  HTMLOptionElement* = ref object of HTMLElement
    value*: string
  
  HTMLHeadingElement* = ref object of HTMLElement
    rank*: uint16

  HTMLBRElement* = ref object of HTMLElement

  HTMLMenuElement* = ref object of HTMLElement
    ordinalcounter*: int

  HTMLUListElement* = ref object of HTMLElement
    ordinalcounter*: int

  HTMLOListElement* = ref object of HTMLElement
    start*: Option[int]
    ordinalcounter*: int

  HTMLLIElement* = ref object of HTMLElement
    value*: Option[int]
    ordinalvalue*: int

  HTMLStyleElement* = ref object of HTMLElement
    sheet*: CSSStylesheet
    sheet_invalid*: bool

  HTMLLinkElement* = ref object of HTMLElement
    sheet*: CSSStylesheet

  HTMLFormElement* = ref object of HTMLElement
    name*: string
    smethod*: string
    enctype*: string
    target*: string
    novalidate*: bool
    constructingentrylist*: bool
    inputs*: seq[HTMLInputElement]

  HTMLTemplateElement* = ref object of HTMLElement
    content*: DocumentFragment

  HTMLUnknownElement* = ref object of HTMLElement

  HTMLScriptElement* = ref object of HTMLElement
    parserDocument*: Document
    preparationTimeDocument*: Document
    forceAsync*: bool
    fromAnExternalFile*: bool
    readyToBeParser*: bool
    alreadyStarted*: bool
    delayingTheLoadEvent*: bool
    ctype*: bool
    #TODO result

# For debugging
func `$`*(node: Node): string =
  case node.nodeType
  of ELEMENT_NODE:
    let element = Element(node)
    "Element of " & $element.tagType & ", children: {\n" & $element.childNodes & "\n}"
  of TEXT_NODE:
    let text = Text(node)
    "Text: " & text.data
  else:
    "Node of " & $node.nodeType

iterator children*(node: Node): Element {.inline.} =
  for child in node.childNodes:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator elements*(node: Node, tag: TagType): Element {.inline.} =
  var stack: seq[Element]
  for child in node.children:
    stack.add(child)
  while stack.len > 0:
    let element = stack.pop()
    if element.tagType == tag:
      yield element
    for i in countdown(element.childNodes.high, 0):
      let child = element.childNodes[i]
      if child.nodeType == ELEMENT_NODE:
        stack.add(Element(child))

iterator radiogroup(form: HTMLFormElement): HTMLInputElement {.inline.} =
  for input in form.inputs:
    if input.inputType == INPUT_RADIO:
      yield input

iterator radiogroup(document: Document): HTMLInputElement {.inline.} =
  for input in document.elements(TAG_INPUT):
    let input = HTMLInputElement(input)
    if input.form == nil and input.inputType == INPUT_RADIO:
      yield input

iterator radiogroup*(input: HTMLInputElement): HTMLInputElement {.inline.} =
  if input.form != nil:
    for input in input.form.radiogroup:
      yield input
  else:
    for input in input.document.radiogroup:
      yield input

iterator textNodes*(node: Node): Text {.inline.} =
  for node in node.childNodes:
    if node.nodeType == TEXT_NODE:
      yield Text(node)

# Returns the node's ancestors
iterator ancestors*(node: Node): Element {.inline.} =
  var element = node.parentElement
  while element != nil:
    yield element
    element = element.parentElement

# Returns the node itself and its ancestors
iterator branch*(node: Node): Node {.inline.} =
  var node = node
  while node != nil:
    yield node
    node = node.parentNode

func qualifiedName*(element: Element): string =
  if element.namespacePrefix.issome: element.namespacePrefix.get & ':' & element.localName
  else: element.localName

func html*(document: Document): HTMLElement =
  for element in document.children:
    if element.tagType == TAG_HTML:
      return HTMLElement(element)
  return nil

func head*(document: Document): HTMLElement =
  if document.html != nil:
    for element in document.html.children:
      if element.tagType == TAG_HEAD:
        return HTMLElement(element)
  return nil

func body*(document: Document): HTMLElement =
  if document.html != nil:
    for element in document.html.children:
      if element.tagType == TAG_BODY:
        return HTMLElement(element)
  return nil

func countChildren(node: Node, nodeType: NodeType): int =
  for child in node.childNodes:
    if child.nodeType == nodeType:
      inc result

func hasChild(node: Node, nodeType: NodeType): bool =
  for child in node.childNodes:
    if child.nodeType == nodeType:
      return false

func hasNextSibling(node: Node, nodeType: NodeType): bool =
  var node = node.nextSibling
  while node != nil:
    if node.nodeType == nodeType: return true
    node = node.nextSibling
  return false

func hasPreviousSibling(node: Node, nodeType: NodeType): bool =
  var node = node.previousSibling
  while node != nil:
    if node.nodeType == nodeType: return true
    node = node.previousSibling
  return false

func inSameTree*(a, b: Node): bool =
  a.rootNode == b.rootNode and (a.rootNode != nil or b.rootNode != nil)

func children*(node: Node): seq[Element] =
  for child in node.children:
    result.add(child)

func filterDescendants*(element: Element, predicate: (proc(child: Element): bool)): seq[Element] =
  var stack: seq[Element]
  stack.add(element.children)
  while stack.len > 0:
    let child = stack.pop()
    if predicate(child):
      result.add(child)
    stack.add(child.children)

func all_descendants*(element: Element): seq[Element] =
  var stack: seq[Element]
  stack.add(element.children)
  while stack.len > 0:
    let child = stack.pop()
    result.add(child)
    stack.add(child.children)

# a == b or b in a's ancestors
func contains*(a, b: Node): bool =
  for node in a.branch:
    if node == b: return true
  return false

func branch*(node: Node): seq[Node] =
  for node in node.branch:
    result.add(node)

func firstChild*(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[0]

func lastChild*(node: Node): Node =
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

func attr*(element: Element, s: string): string =
  return element.attributes.getOrDefault(s, "")

func attri*(element: Element, s: string): Option[int] =
  let a = element.attr(s)
  try:
    return some(parseInt(a))
  except ValueError:
    return none(int)

func attrb*(element: Element, s: string): bool =
  if s in element.attributes:
    return true
  return false

func textContent*(node: Node): string =
  case node.nodeType
  of DOCUMENT_NODE, DOCUMENT_TYPE_NODE:
    return "" #TODO null
  of CDATA_SECTION_NODE, COMMENT_NODE, PROCESSING_INSTRUCTION_NODE, TEXT_NODE:
    return CharacterData(node).data
  else:
    for child in node.childNodes:
      if child.nodeType != COMMENT_NODE:
        result &= child.textContent

func childTextContent*(node: Node): string =
  for child in node.childNodes:
    if child.nodeType == TEXT_NODE:
      result &= Text(child).data

proc sheets*(element: Element): seq[CSSStylesheet] =
  for child in element.children:
    if child.tagType == TAG_STYLE:
      let child = HTMLStyleElement(child)
      if child.sheet_invalid:
        child.sheet = parseStylesheet(newStringStream(child.textContent))
      result.add(child.sheet)
    elif child.tagType == TAG_LINK:
      let child = HTMLLinkElement(child)
      if child.sheet != nil:
        result.add(child.sheet)

func inputString*(input: HTMLInputElement): string =
  var text = case input.inputType
  of INPUT_CHECKBOX, INPUT_RADIO:
    if input.checked: "*"
    else: " "
  of INPUT_SEARCH, INPUT_TEXT:
    if input.size > 0: input.value.padToWidth(input.size)
    else: input.value
  of INPUT_PASSWORD:
    '*'.repeat(input.value.len).padToWidth(input.size)
  of INPUT_RESET:
    if input.value != "": input.value
    else: "RESET"
  of INPUT_SUBMIT, INPUT_BUTTON:
    if input.value != "": input.value
    else: "SUBMIT"
  of INPUT_FILE:
    if input.file.isnone: "".padToWidth(input.size)
    else: input.file.get.path.serialize_unicode().padToWidth(input.size)
  else:
    input.value
  return text

func isButton*(element: Element): bool =
  if element.tagType == TAG_BUTTON:
    return true
  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    return element.inputType in {INPUT_SUBMIT, INPUT_BUTTON, INPUT_RESET, INPUT_IMAGE}
  return false

func isSubmitButton*(element: Element): bool =
  if element.tagType == TAG_BUTTON:
    return element.attr("type") == "submit"
  elif element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    return element.inputType in {INPUT_SUBMIT, INPUT_IMAGE}
  return false

func action*(element: Element): string =
  if element.isSubmitButton():
    if element.attrb("formaction"):
      return element.attr("formaction")
  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    if element.form != nil:
      if element.form.attrb("action"):
        return element.form.attr("action")
  return ""

func enctype*(element: Element): FormEncodingType =
  if element.isSubmitButton():
    if element.attrb("formenctype"):
      return case element.attr("formenctype").tolower()
      of "application/x-www-form-urlencoded": FORM_ENCODING_TYPE_URLENCODED
      of "multipart/form-data": FORM_ENCODING_TYPE_MULTIPART
      of "text/plain": FORM_ENCODING_TYPE_TEXT_PLAIN
      else: FORM_ENCODING_TYPE_URLENCODED

  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    if element.form != nil:
      if element.form.attrb("enctype"):
        return case element.attr("enctype").tolower()
        of "application/x-www-form-urlencoded": FORM_ENCODING_TYPE_URLENCODED
        of "multipart/form-data": FORM_ENCODING_TYPE_MULTIPART
        of "text/plain": FORM_ENCODING_TYPE_TEXT_PLAIN
        else: FORM_ENCODING_TYPE_URLENCODED

  return FORM_ENCODING_TYPE_URLENCODED

func formmethod*(element: Element): FormMethod =
  if element.isSubmitButton():
    if element.attrb("formmethod"):
      return case element.attr("formmethod").tolower()
      of "get": FORM_METHOD_GET
      of "post": FORM_METHOD_POST
      of "dialog": FORM_METHOD_DIALOG
      else: FORM_METHOD_GET

  # has form (TODO not only input should be included)
  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    if element.form != nil:
      if element.form.attrb("method"):
        return case element.form.attr("method").tolower()
        of "get": FORM_METHOD_GET
        of "post": FORM_METHOD_POST
        of "dialog": FORM_METHOD_DIALOG
        else: FORM_METHOD_GET

  return FORM_METHOD_GET

func target*(element: Element): string =
  if element.attrb("target"):
    return element.attr("target")
  for base in element.document.elements(TAG_BASE):
    if base.attrb("target"):
      return base.attr("target")
  return ""

func findAncestor*(node: Node, tagTypes: set[TagType]): Element =
  for element in node.ancestors:
    if element.tagType in tagTypes:
      return element
  return nil

func newText*(document: Document, data: string = ""): Text =
  new(result)
  result.nodeType = TEXT_NODE
  result.document = document
  result.data = data
  result.rootNode = result

func newComment*(document: Document, data: string = ""): Comment =
  new(result)
  result.nodeType = COMMENT_NODE
  result.document = document
  result.data = data
  result.rootNode = result

func namespace(s: string): Option[Namespace] =
  for n in Namespace:
    if s == $n:
      return some(n)

# note: we do not implement custom elements
func newHTMLElement*(document: Document, tagType: TagType, namespace = Namespace.HTML, prefix = Option[string]): HTMLElement =
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
  of TAG_OL:
    result = new(HTMLOListElement)
  of TAG_UL:
    result = new(HTMLUListElement)
    HTMLUListElement(result).ordinalcounter = 1
  of TAG_MENU:
    result = new(HTMLMenuElement)
    HTMLMenuElement(result).ordinalcounter = 1
  of TAG_LI:
    result = new(HTMLLIElement)
  of TAG_STYLE:
    result = new(HTMLStyleElement)
    HTMLStyleElement(result).sheet_invalid = true
  of TAG_LINK:
    result = new(HTMLLinkElement)
  of TAG_FORM:
    result = new(HTMLFormElement)
  of TAG_TEMPLATE:
    result = new(HTMLTemplateElement)
    HTMLTemplateElement(result).content = DocumentFragment(document: document, host: result)
  of TAG_UNKNOWN:
    result = new(HTMLUnknownElement)
  of TAG_SCRIPT:
    result = new(HTMLScriptElement)
    HTMLScriptElement(result).forceAsync = true
  else:
    result = new(HTMLElement)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.css = rootProperties()
  result.rootNode = result
  result.document = document

func newHTMLElement*(document: Document, localName: string, namespace = "", prefix = none[string](), tagType = tagType(localName)): Element =
  result = document.newHTMLElement(tagType, namespace(namespace).get(HTML))
  result.namespacePrefix = prefix

func newDocument*(): Document =
  new(result)
  result.nodeType = DOCUMENT_NODE
  result.rootNode = result
  result.document = result

func newDocumentType*(document: Document, name: string, publicId = "", systemId = ""): DocumentType =
  new(result)
  result.document = document
  result.name = name
  result.publicId = publicId
  result.systemId = systemId
  result.rootNode = result

func newAttr*(parent: Element, key, value: string): Attr =
  new(result)
  result.document = parent.document
  result.nodeType = ATTRIBUTE_NODE
  result.ownerElement = parent
  result.name = key
  result.value = value
  result.rootNode = result

func getElementById*(document: Document, id: string): Element =
  if id.len == 0:
    return nil
  var stack = document.children
  while stack.len > 0:
    let element = stack.pop()
    if element.id == id:
      return element
    for i in countdown(element.childNodes.high, 0):
      let child = element.childNodes[i]
      if child.nodeType == ELEMENT_NODE:
        stack.add(Element(child))
  return nil

func getElementsByTag*(document: Document, tag: TagType): seq[Element] =
  for element in document.elements(tag):
    result.add(element)

func inHTMLNamespace*(element: Element): bool = element.namespace == Namespace.HTML
func inMathMLNamespace*(element: Element): bool = element.namespace == Namespace.MATHML
func inSVGNamespace*(element: Element): bool = element.namespace == Namespace.SVG
func inXLinkNamespace*(element: Element): bool = element.namespace == Namespace.XLINK
func inXMLNamespace*(element: Element): bool = element.namespace == Namespace.XML
func inXMLNSNamespace*(element: Element): bool = element.namespace == Namespace.XMLNS

func isResettable*(element: Element): bool =
  return element.tagType in {TAG_INPUT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA}

func isHostIncludingInclusiveAncestor*(a, b: Node): bool =
  for parent in b.branch:
    if parent == a:
      return true
  if b.rootNode.nodeType == DOCUMENT_FRAGMENT_NODE and DocumentFragment(b.rootNode).host != nil:
    for parent in b.rootNode.branch:
      if parent == a:
        return true
  return false

func baseUrl*(document: Document): Url =
  var href = ""
  for base in document.elements(TAG_BASE):
    if base.attrb("href"):
      href = base.attr("href")
  if href == "":
    return document.location
  let url = parseUrl(href, document.location.some)
  if url.isnone:
    return document.location
  return url.get

func href*(element: Element): string =
  assert element.tagType in {TAG_A, TAG_LINK, TAG_BASE}
  if element.attrb("href"):
    let url = parseUrl(element.attr("href"), some(element.document.location))
    if url.issome:
      return $url.get
  return ""

func rel*(element: Element): string =
  assert element.tagType in {TAG_A, TAG_LINK, TAG_AREA}
  return element.attr("rel")

func title*(document: Document): string =
  for title in document.elements(TAG_TITLE):
    return title.childTextContent.stripAndCollapse()
  return ""

# WARNING the ordering of the arguments in the standard is whack so this doesn't match that
func preInsertionValidity*(parent, node, before: Node): bool =
  if parent.nodeType notin {DOCUMENT_NODE, DOCUMENT_FRAGMENT_NODE, ELEMENT_NODE}:
    # HierarchyRequestError
    return false
  if node.isHostIncludingInclusiveAncestor(parent):
    # HierarchyRequestError
    return false
  if before != nil and before.parentNode != parent:
    # NotFoundError
    return false
  if node.nodeType notin {DOCUMENT_FRAGMENT_NODE, DOCUMENT_TYPE_NODE, ELEMENT_NODE, CDATA_SECTION_NODE}:
    # HierarchyRequestError
    return false
  if (node.nodeType == TEXT_NODE and parent.nodeType == DOCUMENT_NODE) or
      (node.nodeType == DOCUMENT_TYPE_NODE and parent.nodeType != DOCUMENT_NODE):
    # HierarchyRequestError
    return false
  if parent.nodeType == DOCUMENT_NODE:
    case node.nodeType
    of DOCUMENT_FRAGMENT_NODE:
      let elems = node.countChildren(ELEMENT_NODE)
      if elems > 1 or node.hasChild(TEXT_NODE):
        # HierarchyRequestError
        return false
      elif elems == 1 and (parent.hasChild(ELEMENT_NODE) or before != nil and (before.nodeType == DOCUMENT_TYPE_NODE or before.hasNextSibling(DOCUMENT_TYPE_NODE))):
        # HierarchyRequestError
        return false
    of ELEMENT_NODE:
      if parent.hasChild(ELEMENT_NODE) or before != nil and (before.nodeType == DOCUMENT_TYPE_NODE or before.hasNextSibling(DOCUMENT_TYPE_NODE)):
        # HierarchyRequestError
        return false
    of DOCUMENT_TYPE_NODE:
      if parent.hasChild(DOCUMENT_TYPE_NODE) or before != nil and before.hasPreviousSibling(ELEMENT_NODE) or before == nil and parent.hasChild(ELEMENT_NODE):
        # HierarchyRequestError
        return false
    else: discard
  return true # no exception reached

proc remove*(node: Node) =
  let parent = node.parentNode
  assert parent != nil
  let index = parent.childNodes.find(node)
  assert index != -1
  #TODO live ranges
  #TODO NodeIterator
  let oldPreviousSibling = node.previousSibling
  let oldNextSibling = node.nextSibling
  parent.childNodes.del(index)
  if oldPreviousSibling != nil:
    oldPreviousSibling.nextSibling = oldNextSibling
  if oldNextSibling != nil:
    oldNextSibling.previousSibling = oldPreviousSibling
  node.parentNode = nil
  node.parentElement = nil

  #TODO assigned, shadow root, shadow root again, custom nodes, registered observers
  #TODO not surpress observers => queue tree mutation record

proc adopt(document: Document, node: Node) =
  if node.parentNode != nil:
    remove(node)
  #TODO shadow root

proc applyChildInsert(parent, child: Node, index: int) =
  if parent.rootNode != nil:
    child.rootNode = parent.rootNode
  else:
    child.rootNode = parent
  child.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    child.parentElement = Element(parent)
  if index - 1 >= 0:
    child.previousSibling = parent.childNodes[index - 1]
    child.previousSibling.nextSibling = child
  if index + 1 < parent.childNodes.len:
    child.nextSibling = parent.childNodes[index + 1]
    child.nextSibling.previousSibling = child

# WARNING ditto
proc insert*(parent, node, before: Node) =
  let nodes = if node.nodeType == DOCUMENT_FRAGMENT_NODE: node.childNodes
  else: @[node]
  let count = nodes.len
  if count == 0:
    return
  if node.nodeType == DOCUMENT_FRAGMENT_NODE:
    for child in node.childNodes:
      child.remove()
    #TODO tree mutation record
  if before != nil:
    #TODO live ranges
    discard
  #let previousSibling = if before == nil: parent.lastChild
  #else: before.previousSibling
  for node in nodes:
    parent.document.adopt(node)
    if before == nil:
      parent.childNodes.add(node)
      parent.applyChildInsert(node, parent.childNodes.high)
    else:
      let index = parent.childNodes.find(before)
      parent.childNodes.insert(node, index)
      parent.applyChildInsert(node, index)
    #TODO shadow root

# WARNING ditto
proc preInsert*(parent, node, before: Node) =
  if parent.preInsertionValidity(node, before):
    let referenceChild = if before == node: node.nextSibling
    else: before
    parent.insert(node, referenceChild)

proc append*(parent, node: Node) =
  parent.preInsert(node, nil)

proc applyOrdinal*(elem: HTMLLIElement) =
  let val = elem.attri("value")
  if val.issome:
    elem.ordinalvalue = val.get
  else:
    let owner = elem.findAncestor({TAG_OL, TAG_UL, TAG_MENU})
    if owner == nil:
      elem.ordinalvalue = 1
    else:
      case owner.tagType
      of TAG_OL:
        let ol = HTMLOListElement(owner)
        elem.ordinalvalue = ol.ordinalcounter
        inc ol.ordinalcounter
      of TAG_UL:
        let ul = HTMLUListElement(owner)
        elem.ordinalvalue = ul.ordinalcounter
        inc ul.ordinalcounter
      of TAG_MENU:
        let menu = HTMLMenuElement(owner)
        elem.ordinalvalue = menu.ordinalcounter
        inc menu.ordinalcounter
      else: discard

proc reset*(element: Element) = 
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputELement(element)
    case input.inputType
    of INPUT_SEARCH, INPUT_TEXT, INPUT_PASSWORD:
      input.value = input.attr("value")
    of INPUT_CHECKBOX, INPUT_RADIO:
      input.checked = input.attrb("checked")
    of INPUT_FILE:
      input.file = none(Url)
    else: discard
    input.rendered = false
  else: discard

proc reset*(form: HTMLFormElement) =
  for input in form.inputs:
    input.reset()
    input.rendered = false

proc appendAttribute*(element: Element, k, v: string) =
  case k
  of "id": element.id = v
  of "class":
    let classes = v.split(' ')
    for class in classes:
      if class != "" and class notin element.classList:
        element.classList.add(class)
  if element.tagType == TAG_INPUT:
    case k
    of "value": HTMLInputElement(element).value = v
    of "type": HTMLInputElement(element).inputType = inputType(v)
    of "size":
      var i = 20
      var fail = v.len > 0
      for c in v:
        if not c.isDigit:
          fail = true
          break
      if not fail:
        i = parseInt(v)
      HTMLInputElement(element).size = i
    of "checked": HTMLInputElement(element).checked = true
  element.attributes[k] = v

proc setForm*(element: Element, form: HTMLFormElement) =
  case element.tagType
  of TAG_INPUT:
    HTMLInputElement(element).form = form
  of TAG_BUTTON, TAG_FIELDSET, TAG_OBJECT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA, TAG_IMG:
    discard #TODO
  else: assert false
