import macros
import options
import streams
import strutils
import tables

import css/sheet
import html/tags
import js/javascript
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
    NO_NAMESPACE,
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
    childNodes* {.jsget.}: seq[Node]
    nextSibling*: Node
    previousSibling*: Node
    parentNode* {.jsget.}: Node
    parentElement* {.jsget.}: Element
    root: Node
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
    focus*: Element

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
    attributes* {.jsget, jsset.}: Table[string, string]
    hover*: bool
    invalid*: bool

  HTMLElement* = ref object of Element

  FormAssociatedElement* = ref object of HTMLElement
    parserInserted*: bool

  HTMLInputElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    inputType*: InputType
    autofocus*: bool
    required*: bool
    value* {.jsget.}: string
    size*: int
    checked*: bool
    xcoord*: int
    ycoord*: int
    file*: Option[Url]

  HTMLAnchorElement* = ref object of HTMLElement

  HTMLSelectElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    size*: int

  HTMLSpanElement* = ref object of HTMLElement

  HTMLOptGroupElement* = ref object of HTMLElement

  HTMLOptionElement* = ref object of HTMLElement
    selected*: bool
  
  HTMLHeadingElement* = ref object of HTMLElement
    rank*: uint16

  HTMLBRElement* = ref object of HTMLElement

  HTMLMenuElement* = ref object of HTMLElement

  HTMLUListElement* = ref object of HTMLElement

  HTMLOListElement* = ref object of HTMLElement
    start*: Option[int]

  HTMLLIElement* = ref object of HTMLElement
    value* {.jsget.}: Option[int]

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
    controls*: seq[FormAssociatedElement]

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

  HTMLBaseElement* = ref object of HTMLElement

  HTMLAreaElement* = ref object of HTMLElement

  HTMLButtonElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    ctype*: ButtonType
    value* {.jsget, jsset.}: string

  HTMLTextAreaElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    rows*: int
    cols*: int
    value* {.jsget.}: string

proc tostr(ftype: enum): string =
  return ($ftype).split('_')[1..^1].join("-").tolower()

func escapeText(s: string, attribute_mode = false): string =
  var nbsp_mode = false
  var nbsp_prev: char
  for c in s:
    if nbsp_mode:
      if c == char(0xA0):
        result &= "&nbsp;"
      else:
        result &= nbsp_prev & c
      nbsp_mode = false
    elif c == '&':
      result &= "&amp;"
    elif c == char(0xC2):
      nbsp_mode = true
      nbsp_prev = c
    elif attribute_mode and c == '"':
      result &= "&quot;"
    elif not attribute_mode and c == '<':
      result &= "&lt;"
    elif not attribute_mode and c == '>':
      result &= "&gt;"
    else:
      result &= c

func `$`*(node: Node): string =
  if node == nil: return "nil" #TODO this isn't standard compliant but helps debugging
  case node.nodeType
  of ELEMENT_NODE:
    let element = Element(node)
    result = "<" & $element.tagType.tostr()
    for k, v in element.attributes:
      result &= ' ' & k & "=\"" & v.escapeText(true) & "\""
    result &= ">\n"
    for node in element.childNodes:
      for line in ($node).split('\n'):
        result &= "\t" & line & "\n"
    result &= "</" & $element.tagType.tostr() & ">"
  of TEXT_NODE:
    let text = Text(node)
    result = text.data.escapeText()
  of COMMENT_NODE:
    result = "<!-- " & Comment(node).data & "-->"
  of PROCESSING_INSTRUCTION_NODE:
    result = "" #TODO
  of DOCUMENT_TYPE_NODE:
    result = "<!DOCTYPE" & ' ' & DocumentType(node).name & ">"
  else:
    result = "Node of " & $node.nodeType

iterator children*(node: Node): Element {.inline.} =
  for child in node.childNodes:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator children_rev*(node: Node): Element {.inline.} =
  for i in countdown(node.childNodes.high, 0):
    let child = node.childNodes[i]
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

#TODO TODO TODO this should return a live view instead
proc children*(node: Node): seq[Element] {.jsfget.} =
  for child in node.children:
    result.add(child)

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

# Returns the node's descendants
iterator descendants*(node: Node): Node {.inline.} =
  var stack: seq[Node]
  stack.add(node)
  while stack.len > 0:
    let node = stack.pop()
    for i in countdown(node.childNodes.high, 0):
      yield node.childNodes[i]
      stack.add(node.childNodes[i])

iterator elements*(node: Node): Element {.inline.} =
  for child in node.descendants:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator elements*(node: Node, tag: TagType): Element {.inline.} =
  for desc in node.elements:
    if desc.tagType == tag:
      yield desc

iterator inputs(form: HTMLFormElement): HTMLInputElement {.inline.} =
  for control in form.controls:
    if control.tagType == TAG_INPUT:
      yield HTMLInputElement(control)

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
  
iterator options*(select: HTMLSelectElement): HTMLOptionElement {.inline.} =
  for child in select.children:
    if child.tagType == TAG_OPTION:
      yield HTMLOptionElement(child)
    elif child.tagType == TAG_OPTGROUP:
      for opt in child.children:
        if opt.tagType == TAG_OPTION:
          yield HTMLOptionElement(child)

func form*(element: FormAssociatedElement): HTMLFormElement =
  case element.tagType
  of TAG_INPUT: return HTMLInputElement(element).form
  of TAG_SELECT: return HTMLSelectElement(element).form
  of TAG_BUTTON: return HTMLButtonElement(element).form
  of TAG_TEXTAREA: return HTMLTextAreaElement(element).form
  else: assert false

func `form=`*(element: FormAssociatedElement, form: HTMLFormElement) =
  case element.tagType
  of TAG_INPUT: HTMLInputElement(element).form = form
  of TAG_SELECT:  HTMLSelectElement(element).form = form
  of TAG_BUTTON: HTMLButtonElement(element).form = form
  of TAG_TEXTAREA: HTMLTextAreaElement(element).form = form
  else: assert false

func canSubmitImplicitly*(form: HTMLFormElement): bool =
  const BlocksImplicitSubmission = {
    INPUT_TEXT, INPUT_SEARCH, INPUT_URL, INPUT_TEL, INPUT_EMAIL, INPUT_PASSWORD,
    INPUT_DATE, INPUT_MONTH, INPUT_WEEK, INPUT_TIME, INPUT_DATETIME_LOCAL,
    INPUT_NUMBER
  }
  var found = false
  for control in form.controls:
    if control.tagType == TAG_INPUT:
      let input = HTMLInputElement(control)
      if input.inputType in BlocksImplicitSubmission:
        if found:
          return false
        else:
          found = true
  return true

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

func select*(option: HTMLOptionElement): HTMLSelectElement =
  for anc in option.ancestors:
    if anc.tagType == TAG_SELECT:
      return HTMLSelectElement(anc)
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

func rootNode*(node: Node): Node =
  if node.root == nil: return node
  return node.root

func connected*(node: Node): bool =
  return node.rootNode.nodeType == DOCUMENT_NODE #TODO shadow root

func inSameTree*(a, b: Node): bool =
  a.rootNode == b.rootNode

func filterDescendants*(element: Element, predicate: (proc(child: Element): bool)): seq[Element] =
  var stack: seq[Element]
  for child in element.children_rev:
    stack.add(child)
  while stack.len > 0:
    let child = stack.pop()
    if predicate(child):
      result.add(child)
    for child in element.children_rev:
      stack.add(child)

func all_descendants*(element: Element): seq[Element] =
  var stack: seq[Element]
  for child in element.children_rev:
    stack.add(child)
  while stack.len > 0:
    let child = stack.pop()
    result.add(child)
    for child in element.children_rev:
      stack.add(child)

# a == b or b in a's ancestors
func contains*(a, b: Node): bool =
  for node in a.branch:
    if node == b: return true
  return false

func firstChild*(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[0]

func lastChild*(node: Node): Node =
  if node.childNodes.len == 0:
    return nil
  return node.childNodes[^1]

func firstElementChild*(node: Node): Element =
  for child in node.children:
    return child
  return nil

func lastElementChild*(node: Node): Element =
  for child in node.children:
    return child
  return nil

func previousElementSibling*(elem: Element): Element =
  var i = elem.parentNode.childNodes.find(elem)
  dec i
  while i >= 0:
    if elem.parentNode.childNodes[i].nodeType == ELEMENT_NODE:
      return elem
    dec i
  return nil

func nextElementSibling*(elem: Element): Element =
  var i = elem.parentNode.childNodes.find(elem)
  inc i
  while i < elem.parentNode.childNodes.len:
    if elem.parentNode.childNodes[i].nodeType == ELEMENT_NODE:
      return elem
    inc i
  return nil

func attr*(element: Element, s: string): string {.inline.} =
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

func innerHTML*(element: Element): string {.jsfget.} =
  for child in element.childNodes:
    result &= $child

func outerHTML*(element: Element): string {.jsfget.} =
  return $element

func textContent*(node: Node): string {.jsfget.} =
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
  case input.inputType
  of INPUT_CHECKBOX, INPUT_RADIO:
    if input.checked: "*"
    else: " "
  of INPUT_SEARCH, INPUT_TEXT:
    input.value.padToWidth(input.size)
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
  else: input.value

func textAreaString*(textarea: HTMLTextAreaElement): string =
  let split = textarea.value.split('\n')
  for i in 0 ..< textarea.rows:
    if textarea.cols > 2:
      if i < split.len:
        result &= '[' & split[i].padToWidth(textarea.cols - 2) & "]\n"
      else:
        result &= '[' & ' '.repeat(textarea.cols - 2) & "]\n"
    else:
      result &= "[]\n"

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
  if element.tagType == TAG_FORM:
    return element.attr("action")
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

  if element.tagType in SupportedFormAssociatedElements:
    let element = FormAssociatedElement(element)
    if element.form != nil:
      if element.form.attrb("method"):
        return case element.form.attr("method").tolower()
        of "get": FORM_METHOD_GET
        of "post": FORM_METHOD_POST
        of "dialog": FORM_METHOD_DIALOG
        else: FORM_METHOD_GET

  return FORM_METHOD_GET

func target*(element: Element): string {.jsfunc.} =
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

func newText*(document: Document, data: string = ""): Text {.jsctor.} =
  new(result)
  result.nodeType = TEXT_NODE
  result.document = document
  result.data = data

func newComment*(document: Document = nil, data: string = ""): Comment {.jsctor.} =
  new(result)
  result.nodeType = COMMENT_NODE
  result.document = document
  result.data = data

#TODO custom elements
func newHTMLElement*(document: Document, tagType: TagType, namespace = Namespace.HTML, prefix = none[string]()): HTMLElement =
  case tagType
  of TAG_INPUT:
    result = new(HTMLInputElement)
    HTMLInputElement(result).size = 20
  of TAG_A:
    result = new(HTMLAnchorElement)
  of TAG_SELECT:
    result = new(HTMLSelectElement)
    HTMLSelectElement(result).size = 1
  of TAG_OPTGROUP:
    result = new(HTMLOptGroupElement)
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
  of TAG_MENU:
    result = new(HTMLMenuElement)
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
  of TAG_BASE:
    result = new(HTMLBaseElement)
  of TAG_BUTTON:
    result = new(HTMLButtonElement)
  of TAG_TEXTAREA:
    result = new(HTMLTextAreaElement)
  else:
    result = new(HTMLElement)

  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.namespace = namespace
  result.namespacePrefix = prefix
  result.document = document

func newHTMLElement*(document: Document, localName: string, namespace = Namespace.HTML, prefix = none[string](), tagType = tagType(localName)): Element =
  result = document.newHTMLElement(tagType, namespace, prefix)
  if tagType == TAG_UNKNOWN:
    result.localName = localName

func newDocument*(): Document {.jsctor.} =
  new(result)
  result.nodeType = DOCUMENT_NODE
  result.document = result

func newDocumentType*(document: Document, name: string, publicId = "", systemId = ""): DocumentType {.jsctor.} =
  new(result)
  result.document = document
  result.name = name
  result.publicId = publicId
  result.systemId = systemId

func newAttr*(parent: Element, key, value: string): Attr =
  new(result)
  result.document = parent.document
  result.nodeType = ATTRIBUTE_NODE
  result.ownerElement = parent
  result.name = key
  result.value = value

func getElementById*(node: Node, id: string): Element {.jsfunc.} =
  if id.len == 0:
    return nil
  for child in node.elements:
    if child.id == id:
      return child

func getElementById2*(node: Node, id: string): pointer =
  if id.len == 0:
    return nil
  for child in node.elements:
    if child.id == id:
      return cast[pointer](child)

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

func href*[T: HTMLAnchorElement|HTMLLinkElement|HTMLBaseElement](element: T): string =
  if element.attrb("href"):
    let url = parseUrl(element.attr("href"), some(element.document.location))
    if url.issome:
      return $url.get
  return ""

func rel*[T: HTMLAnchorElement|HTMLLinkElement|HTMLAreaElement](element: T): string =
  return element.attr("rel")

func media*[T: HTMLLinkElement|HTMLStyleElement](element: T): string =
  return element.attr("media")

func title*(document: Document): string =
  for title in document.elements(TAG_TITLE):
    return title.childTextContent.stripAndCollapse()
  return ""

func disabled*(option: HTMLOptionElement): bool =
  if option.parentElement.tagType == TAG_OPTGROUP and option.parentElement.attrb("disabled"):
    return true
  return option.attrb("disabled")

func text*(option: HTMLOptionElement): string =
  for child in option.descendants:
    if child.nodeType == TEXT_NODE:
      let child = Text(child)
      if child.parentElement.tagType != TAG_SCRIPT: #TODO svg
        result &= child.data.stripAndCollapse()

func value*(option: HTMLOptionElement): string {.jsfget.} =
  if option.attrb("value"):
    return option.attr("value")
  return option.childTextContent.stripAndCollapse()

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
  parent.childNodes.delete(index)
  if oldPreviousSibling != nil:
    oldPreviousSibling.nextSibling = oldNextSibling
  if oldNextSibling != nil:
    oldNextSibling.previousSibling = oldPreviousSibling
  node.parentNode = nil
  node.parentElement = nil
  node.root = nil

  #TODO assigned, shadow root, shadow root again, custom nodes, registered observers
  #TODO not surpress observers => queue tree mutation record

proc adopt(document: Document, node: Node) =
  if node.parentNode != nil:
    remove(node)
  #TODO shadow root

proc applyChildInsert(parent, child: Node, index: int) =
  child.root = parent.rootNode
  child.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    child.parentElement = Element(parent)
  if index - 1 >= 0:
    child.previousSibling = parent.childNodes[index - 1]
    child.previousSibling.nextSibling = child
  if index + 1 < parent.childNodes.len:
    child.nextSibling = parent.childNodes[index + 1]
    child.nextSibling.previousSibling = child

proc resetElement*(element: Element) = 
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
    input.invalid = true
  of TAG_SELECT:
    let select = HTMLSelectElement(element)
    if not select.attrb("multiple"):
      if select.size == 1:
        var i = 0
        var firstOption: HTMLOptionElement
        for option in select.options:
          if firstOption == nil:
            firstOption = option
          if option.selected:
            inc i
        if i == 0 and firstOption != nil:
          firstOption.selected = true
        elif i > 2:
          # Set the selectedness of all but the last selected option element to
          # false.
          var j = 0
          for option in select.options:
            if j == i: break
            if option.selected:
              option.selected = false
              inc j
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    textarea.value = textarea.childTextContent()
    textarea.invalid = true
  else: discard

proc setForm*(element: FormAssociatedElement, form: HTMLFormElement) =
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    input.form = form
    form.controls.add(input)
  of TAG_SELECT:
    let select = HTMLSelectElement(element)
    select.form = form
    form.controls.add(select)
  of TAG_BUTTON:
    let button = HTMLButtonElement(element)
    button.form = form
    form.controls.add(button)
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    textarea.form = form
    form.controls.add(textarea)
  of TAG_FIELDSET, TAG_OBJECT, TAG_OUTPUT, TAG_IMG:
    discard #TODO
  else: assert false

proc resetFormOwner(element: FormAssociatedElement) =
  element.parserInserted = false
  if element.form != nil and
      element.tagType notin ListedElements or not element.attrb("form") and
      element.findAncestor({TAG_FORM}) == element.form:
    return
  element.form = nil
  if element.tagType in ListedElements and element.attrb("form") and element.connected:
    let form = element.attr("form")
    for desc in element.elements(TAG_FORM):
      if desc.id == form:
        element.setForm(HTMLFormElement(desc))

proc insertionSteps(insertedNode: Node) =
  if insertedNode.nodeType == ELEMENT_NODE:
    let element = Element(insertedNode)
    let tagType = element.tagType
    case tagType
    of TAG_OPTION:
      if element.parentElement != nil:
        let parent = element.parentElement
        var select: HTMLSelectElement
        if parent.tagType == TAG_SELECT:
          select = HTMLSelectElement(parent)
        elif parent.tagType == TAG_OPTGROUP and parent.parentElement != nil and parent.parentElement.tagType == TAG_SELECT:
          select = HTMLSelectElement(parent.parentElement)
        if select != nil:
          select.resetElement()
    else: discard
    if tagType in SupportedFormAssociatedElements:
      let element = FormAssociatedElement(element)
      if element.parserInserted:
        return
      element.resetFormOwner()

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
    if node.nodeType == ELEMENT_NODE:
      #TODO shadow root
      insertionSteps(node)

# WARNING ditto
proc preInsert*(parent, node, before: Node) =
  if parent.preInsertionValidity(node, before):
    let referenceChild = if before == node: node.nextSibling
    else: before
    parent.insert(node, referenceChild)

proc append*(parent, node: Node) =
  parent.preInsert(node, nil)

proc reset*(form: HTMLFormElement) =
  for control in form.controls:
    control.resetElement()
    control.invalid = true

proc appendAttributes*(element: Element, attrs: Table[string, string]) =
  for k, v in attrs:
    element.attributes[k] = v
  template reflect_str(element: Element, name: static string, val: untyped) =
    element.attributes.withValue(name, val):
      element.val = val[]
  template reflect_str(element: Element, name: static string, val, fun: untyped) =
    element.attributes.withValue(name, val):
      element.val = fun(val[])
  template reflect_nonzero_int(element: Element, name: static string, val: untyped, default: int) =
    element.attributes.withValue(name, val):
      if val[].isValidNonZeroInt():
        element.val = parseInt(val[])
      else:
        element.val = default
    do:
      element.val = default
  template reflect_bool(element: Element, name: static string, val: untyped) =
    if name in element.attributes:
      element.val = true
  element.reflect_str "id", id
  element.attributes.withValue("class", val):
    let classList = val[].split(' ')
    for x in classList:
      if x != "" and x notin element.classList:
        element.classList.add(x)
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    input.reflect_str "value", value
    input.reflect_str "type", inputType, inputType
    input.reflect_nonzero_int "size", size, 20
    input.reflect_bool "checked", checked
  of TAG_OPTION:
    let option = HTMLOptionElement(element)
    option.reflect_bool "selected", selected
  of TAG_SELECT:
    let select = HTMLSelectElement(element)
    select.reflect_nonzero_int "size", size, (if "multiple" in element.attributes: 4 else: 1)
  of TAG_BUTTON:
    let button = HTMLButtonElement(element)
    button.reflect_str "type", ctype, (func(s: string): ButtonType =
      case s
      of "submit": return BUTTON_SUBMIT
      of "reset": return BUTTON_RESET
      of "button": return BUTTON_BUTTON)
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    textarea.reflect_nonzero_int "cols", cols, 20
    textarea.reflect_nonzero_int "rows", rows, 1
  else: discard

# Forward definition hack (these are set in selectors.nim)
var doqsa*: proc (node: Node, q: string): seq[Element]
var doqs*: proc (node: Node, q: string): Element

proc querySelectorAll*(node: Node, q: string): seq[Element] {.jsfunc.} =
  return doqsa(node, q)

proc querySelector*(node: Node, q: string): Element {.jsfunc.} =
  return doqs(node, q)

proc addDOMModule*(ctx: JSContext) =
  let eventTargetCID = ctx.registerType(EventTarget)
  let nodeCID = ctx.registerType(Node, parent = eventTargetCID)
  ctx.registerType(Document, parent = nodeCID)
  let characterDataCID = ctx.registerType(CharacterData, parent = nodeCID)
  ctx.registerType(Comment, parent = characterDataCID)
  ctx.registerType(Text, parent = characterDataCID)
  ctx.registerType(DocumentType, parent = nodeCID)
  let elementCID = ctx.registerType(Element, parent = nodeCID)
  let htmlElementCID = ctx.registerType(HTMLElement, parent = elementCID)
  ctx.registerType(HTMLInputElement, parent = htmlElementCID)
  ctx.registerType(HTMLAnchorElement, parent = htmlElementCID)
  ctx.registerType(HTMLSelectElement, parent = htmlElementCID)
  ctx.registerType(HTMLSpanElement, parent = htmlElementCID)
  ctx.registerType(HTMLOptGroupElement, parent = htmlElementCID)
  ctx.registerType(HTMLOptionElement, parent = htmlElementCID)
  ctx.registerType(HTMLHeadingElement, parent = htmlElementCID)
  ctx.registerType(HTMLBRElement, parent = htmlElementCID)
  ctx.registerType(HTMLMenuElement, parent = htmlElementCID)
  ctx.registerType(HTMLUListElement, parent = htmlElementCID)
  ctx.registerType(HTMLOListElement, parent = htmlElementCID)
  ctx.registerType(HTMLLIElement, parent = htmlElementCID)
  ctx.registerType(HTMLStyleElement, parent = htmlElementCID)
  ctx.registerType(HTMLLinkElement, parent = htmlElementCID)
  ctx.registerType(HTMLFormElement, parent = htmlElementCID)
  ctx.registerType(HTMLTemplateElement, parent = htmlElementCID)
  ctx.registerType(HTMLUnknownElement, parent = htmlElementCID)
  ctx.registerType(HTMLScriptElement, parent = htmlElementCID)
  ctx.registerType(HTMLButtonElement, parent = htmlElementCID)
