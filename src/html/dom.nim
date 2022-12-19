import deques
import macros
import options
import sets
import streams
import strutils
import tables

import css/sheet
import data/charset
import encoding/decoderstream
import html/tags
import io/loader
import io/request
import js/javascript
import types/mime
import types/referer
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
    NO_NAMESPACE = "",
    HTML = "http://www.w3.org/1999/xhtml",
    MATHML = "http://www.w3.org/1998/Math/MathML",
    SVG = "http://www.w3.org/2000/svg",
    XLINK = "http://www.w3.org/1999/xlink",
    XML = "http://www.w3.org/XML/1998/namespace",
    XMLNS = "http://www.w3.org/2000/xmlns/"

  ScriptType = enum
    NO_SCRIPTTYPE, CLASSIC, MODULE, IMPORTMAP

  ParserMetadata = enum
    PARSER_INSERTED, NOT_PARSER_INSERTED

  ScriptResultType = enum
    RESULT_NULL, RESULT_UNINITIALIZED, RESULT_SCRIPT, RESULT_IMPORT_MAP_PARSE

type
  Script = object
    #TODO setings
    baseURL: URL
    options: ScriptOptions
    mutedErrors: bool
    #TODO parse error/error to rethrow
    record: string #TODO should be a record...

  ScriptOptions = object
    nonce: string
    integrity: string
    parserMetadata: ParserMetadata
    credentialsMode: CredentialsMode
    referrerPolicy: Option[ReferrerPolicy]
    renderBlocking: bool

  ScriptResult = object
    case t: ScriptResultType
    of RESULT_NULL, RESULT_UNINITIALIZED:
      discard
    of RESULT_SCRIPT:
      script: Script
    of RESULT_IMPORT_MAP_PARSE:
      discard #TODO

type
  Window* = ref object
    settings*: EnvironmentSettings
    loader*: Option[FileLoader]
    jsrt*: JSRuntime
    jsctx*: JSContext
    document* {.jsget.}: Document
    console* {.jsget.}: console

  # "For historical reasons, console is lowercased."
  # Also, for a more practical reason: so the javascript macros don't confuse
  # this and the Client console.
  # TODO: merge those two
  console* = ref object
    err: Stream

  NamedNodeMap = ref object
    element: Element
    attrlist: seq[Attr]

  EnvironmentSettings* = object
    scripting*: bool

  EventTarget* = ref object of RootObj

  #TODO this has caching, but invalidation is pretty expensive... not sure if
  # it's worth the trouble at all...
  Collection = ref CollectionObj
  CollectionObj = object of RootObj
    islive: bool
    invalid: bool
    childonly: bool
    root: Node
    match: proc(node: Node): bool {.noSideEffect.}
    snapshot: seq[Node]
    livelen: int

  NodeList = ref object of Collection

  HTMLCollection = ref object of Collection

  Node* = ref object of EventTarget
    nodeType* {.jsget.}: NodeType
    childList*: seq[Node]
    nextSibling* {.jsget.}: Node
    previousSibling* {.jsget.}: Node
    parentNode* {.jsget.}: Node
    parentElement* {.jsget.}: Element
    root: Node
    document*: Document
    # Live collection cache: if parentHasCollections is true, recursively
    # invalidate all of them on insert.
    parentHasCollections: bool
    liveCollections: seq[Collection]

  Attr* = ref object of Node
    namespace: Namespace
    prefix* {.jsget.}: string
    localName* {.jsget.}: string
    value* {.jsget.}: string
    ownerElement* {.jsget.}: Element

  Document* = ref object of Node
    charset*: Charset
    window*: Window
    url*: URL #TODO expose as URL (capitalized)
    location {.jsget.}: URL #TODO should be location
    mode*: QuirksMode
    currentScript: HTMLScriptElement
    isxml*: bool

    scriptsToExecSoon*: seq[HTMLScriptElement]
    scriptsToExecInOrder*: Deque[HTMLScriptElement]
    scriptsToExecOnLoad*: Deque[HTMLScriptElement]
    parserBlockingScript*: HTMLScriptElement

    parser_cannot_change_the_mode_flag*: bool
    is_iframe_srcdoc*: bool
    focus*: Element
    contentType*: string

    renderBlockingElements: seq[Element]

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
    namespacePrefix*: Option[string]
    prefix*: string
    localName*: string
    tagType*: TagType

    id* {.jsget.}: string
    classList* {.jsget.}: seq[string] #TODO should be DomTokenList
    attrs*: Table[string, string]
    attributes* {.jsget.}: NamedNodeMap
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
    checked*: bool
    xcoord*: int
    ycoord*: int
    file*: Option[Url]

  HTMLAnchorElement* = ref object of HTMLElement

  HTMLSelectElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement

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
    readyForParserExec*: bool
    alreadyStarted*: bool
    delayingTheLoadEvent: bool
    ctype: ScriptType
    internalNonce: string
    scriptResult*: ScriptResult
    onReady: (proc())

  HTMLBaseElement* = ref object of HTMLElement

  HTMLAreaElement* = ref object of HTMLElement

  HTMLButtonElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    ctype*: ButtonType
    value* {.jsget, jsset.}: string

  HTMLTextAreaElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    value* {.jsget.}: string

proc `=destroy`(collection: var CollectionObj) =
  var i = -1
  for j in 0 ..< collection.root.liveCollections.len:
    if cast[pointer](collection.root.liveCollections[j]) == addr collection:
      i = j
      break
  assert i != -1
  collection.root.liveCollections.del(i)

const NamespaceMap = (func(): Table[string, Namespace] =
  for ns in Namespace:
    result[$ns] = ns
)()

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
  if node == nil: return "null" #TODO this isn't standard compliant but helps debugging
  case node.nodeType
  of ELEMENT_NODE:
    let element = Element(node)
    result = "<" & $element.tagType.tostr()
    for k, v in element.attrs:
      result &= ' ' & k & "=\"" & v.escapeText(true) & "\""
    result &= ">\n"
    for node in element.childList:
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

iterator elementList*(node: Node): Element {.inline.} =
  for child in node.childList:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator elementList_rev*(node: Node): Element {.inline.} =
  for i in countdown(node.childList.high, 0):
    let child = node.childList[i]
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

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
    for i in countdown(node.childList.high, 0):
      yield node.childList[i]
      stack.add(node.childList[i])

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
  for node in node.childList:
    if node.nodeType == TEXT_NODE:
      yield Text(node)
  
iterator options*(select: HTMLSelectElement): HTMLOptionElement {.inline.} =
  for child in select.elementList:
    if child.tagType == TAG_OPTION:
      yield HTMLOptionElement(child)
    elif child.tagType == TAG_OPTGROUP:
      for opt in child.elementList:
        if opt.tagType == TAG_OPTION:
          yield HTMLOptionElement(child)

iterator items(attributes: NamedNodeMap): Attr {.inline.} =
  for attr in attributes.attrlist:
    yield attr

proc populateCollection(collection: Collection) =
  if collection.childonly:
    for child in collection.root.childList:
      if collection.match == nil or collection.match(child):
        collection.snapshot.add(child)
  else:
    for desc in collection.root.descendants:
      if collection.match == nil or collection.match(desc):
        collection.snapshot.add(desc)

proc refreshCollection(collection: Collection) =
  if collection.invalid:
    collection.snapshot.setLen(0)
    collection.populateCollection()
    collection.invalid = false

func ownerDocument(node: Node): Document {.jsfget.} =
  if node.nodeType == DOCUMENT_NODE:
    return nil
  return node.document

func hasChildNodes(node: Node): bool {.jsfget.} =
  return node.childList.len > 0

func len(collection: Collection): int =
  collection.refreshCollection()
  return collection.snapshot.len

func newCollection[T: Collection](root: Node, match: proc(node: Node): bool {.noSideEffect.}, islive: bool): T =
  result = T(
    islive: islive,
    match: match,
    root: root
  )
  result.populateCollection()
  if islive:
    root.liveCollections.add(result)
    for desc in root.descendants:
      desc.parentHasCollections = true

func isElement(node: Node): bool =
  return node.nodeType == ELEMENT_NODE

func children*(node: Node): HTMLCollection {.jsfget.} =
  return newCollection[HTMLCollection](node, isElement, true)

func childNodes(node: Node): NodeList {.jsfget.} =
  return newCollection[NodeList](node, nil, true)

func length(nodeList: NodeList): int {.jsfget.} =
  return nodeList.len

func hasprop(nodeList: NodeList, i: int): bool {.jshasprop.} =
  return i < nodeList.len

func getter(nodeList: NodeList, i: int): Option[Node] {.jsgetprop.} =
  if i < nodeList.len:
    return some(nodeList.snapshot[i])

func length(collection: HTMLCollection): int {.jsfget.} =
  return collection.len

func hasprop(collection: HTMLCollection, i: int): bool {.jshasprop.} =
  return i < collection.len

func getter(collection: HTMLCollection, i: int): Option[Element] {.jsgetprop.} =
  if i < collection.len:
    return some(Element(collection.snapshot[i]))

func newAttr(parent: Element, localName, value: string, prefix = "", namespace = NO_NAMESPACE): Attr =
  return Attr(
    nodeType: ATTRIBUTE_NODE,
    document: parent.document,
    namespace: namespace,
    ownerElement: parent,
    localName: localName,
    prefix: prefix,
    value: value
  )

func name(attr: Attr): string {.jsfget.} =
  if attr.prefix == "":
    return attr.localName
  return attr.prefix & ':' & attr.localName

func namespaceURI(attr: Attr): string {.jsfget.} =
  return $attr.namespace

func hasAttribute(element: Element, qualifiedName: string): bool {.jsfunc.} =
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  if qualifiedName in element.attrs:
    return true

func hasAttributeNS(element: Element, namespace, localName: string): bool {.jsfunc.} =
  if namespace == "":
    return localName in element.attrs
  if namespace notin NamespaceMap:
    return false
  let ns = NamespaceMap[namespace]
  for attr in element.attributes:
    if attr.namespace == ns and attr.localName == localName:
      return true

func getAttribute(element: Element, qualifiedName: string): Option[string] {.jsfunc.} =
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  element.attrs.withValue(qualifiedName, val):
    return some(val[])

func getAttributeNS(element: Element, namespace, localName: string): Option[string] {.jsfunc.} =
  if namespace == "":
    return element.getAttribute(localName)
  if namespace == $Namespace.HTML:
    return element.getAttribute(localName)
  if namespace notin NamespaceMap:
    return
  let ns = NamespaceMap[namespace]
  for attr in element.attributes:
    if attr.namespace == ns and attr.localName == localName:
      return some(attr.value)

func findAttr(map: NamedNodeMap, name: string): int =
  for i in 0 ..< map.attrlist.len:
    if map.attrlist[i].name == name:
      return i
  return -1

func getNamedItem(map: NamedNodeMap, qualifiedName: string): Option[Attr] {.jsfunc.} =
  if map.element.hasAttribute(qualifiedName):
    let i = map.findAttr(qualifiedName)
    if i != -1:
      return some(map.attrlist[i])

func getNamedItemNS(map: NamedNodeMap, namespace, localName: string): Option[Attr] {.jsfunc.} =
  if map.element.hasAttributeNS(namespace, localName):
    if namespace in NamespaceMap:
      let ns = NamespaceMap[namespace]
      for attr in map:
        if attr.namespace == ns and attr.localName == localName:
          return some(attr)

func length(map: NamedNodeMap): int {.jsfget.} =
  return map.element.attrs.len

func item(map: NamedNodeMap, i: int): Option[Attr] {.jsfunc.} =
  if i < map.attrlist.len:
    return some(map.attrlist[i])

func hasprop[T: int|string](map: NamedNodeMap, i: T): bool {.jshasprop.} =
  when T is int:
    return i < map.attrlist.len
  else:
    return map.getNamedItem(i).isSome

func getter[T: int|string](map: NamedNodeMap, i: T): Option[Attr] {.jsgetprop.} =
  when T is int:
    return map.item(i)
  else:
    return map.getNamedItem(i)

func scriptingEnabled*(element: Element): bool =
  if element.document == nil:
    return false
  if element.document.window == nil:
    return false
  return element.document.window.settings.scripting

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
  for element in document.elements(TAG_HTML):
    return HTMLElement(element)

func head*(document: Document): HTMLElement =
  let html = document.html
  if html != nil:
    for element in html.elements(TAG_HEAD):
      return HTMLElement(element)

func body*(document: Document): HTMLElement =
  let html = document.html
  if html != nil:
    for element in html.elements(TAG_BODY):
      return HTMLElement(element)

func select*(option: HTMLOptionElement): HTMLSelectElement =
  for anc in option.ancestors:
    if anc.tagType == TAG_SELECT:
      return HTMLSelectElement(anc)
  return nil

func countChildren(node: Node, nodeType: NodeType): int =
  for child in node.childList:
    if child.nodeType == nodeType:
      inc result

func hasChild(node: Node, nodeType: NodeType): bool =
  for child in node.childList:
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

func nodeValue(node: Node): Option[string] {.jsfget.} =
  case node.nodeType
  of CharacterDataNodes:
    return some(CharacterData(node).data)
  of ATTRIBUTE_NODE:
    return some(Attr(node).value)
  else: discard

func textContent*(node: Node): string {.jsfget.} =
  case node.nodeType
  of DOCUMENT_NODE, DOCUMENT_TYPE_NODE:
    return "" #TODO null
  of CharacterDataNodes:
    return CharacterData(node).data
  else:
    for child in node.childList:
      if child.nodeType != COMMENT_NODE:
        result &= child.textContent

func childTextContent*(node: Node): string =
  for child in node.childList:
    if child.nodeType == TEXT_NODE:
      result &= Text(child).data

func rootNode*(node: Node): Node =
  if node.root == nil: return node
  return node.root

func isConnected*(node: Node): bool {.jsfget.} =
  return node.rootNode.nodeType == DOCUMENT_NODE #TODO shadow root

func inSameTree*(a, b: Node): bool =
  a.rootNode == b.rootNode

# a == b or b in a's ancestors
func contains*(a, b: Node): bool =
  for node in a.branch:
    if node == b: return true
  return false

func firstChild*(node: Node): Node {.jsfget.} =
  if node.childList.len == 0:
    return nil
  return node.childList[0]

func lastChild*(node: Node): Node {.jsfget.} =
  if node.childList.len == 0:
    return nil
  return node.childList[^1]

func firstElementChild*(node: Node): Element {.jsfget.} =
  for child in node.elementList:
    return child
  return nil

func lastElementChild*(node: Node): Element {.jsfget.} =
  for child in node.elementList:
    return child
  return nil

func findAncestor*(node: Node, tagTypes: set[TagType]): Element =
  for element in node.ancestors:
    if element.tagType in tagTypes:
      return element
  return nil

func getElementById*(node: Node, id: string): Element {.jsfunc.} =
  if id.len == 0:
    return nil
  for child in node.elements:
    if child.id == id:
      return child

func getElementsByTag*(node: Node, tag: TagType): seq[Element] =
  for element in node.elements(tag):
    result.add(element)

func getElementsByTagName(node: Node, tagName: string): HTMLCollection {.jsfunc.} =
  if tagName == "*":
    return newCollection[HTMLCollection](node, func(node: Node): bool = node.isElement, true)
  let t = tagType(tagName)
  if t != TAG_UNKNOWN:
    return newCollection[HTMLCollection](node, func(node: Node): bool = node.isElement and Element(node).tagType == t, true)

func getElementsByClassName(node: Node, classNames: string): HTMLCollection {.jsfunc.} =
  var classes = classNames.split(AsciiWhitespace)
  let isquirks = node.document.mode == QUIRKS
  if isquirks:
    for i in 0 .. classes.high:
      classes[i].mtoLowerAscii()
  return newCollection[HTMLCollection](node,
    func(node: Node): bool =
      if node.nodeType == ELEMENT_NODE:
        if isquirks:
          var cl = Element(node).classList
          for i in 0 .. cl.high:
            cl[i].mtoLowerAscii()
          for class in classes:
            if class notin cl:
              return false
        else:
          for class in classes:
            if class notin Element(node).classList:
              return false
        return true, true)

func filterDescendants*(element: Element, predicate: (proc(child: Element): bool)): seq[Element] =
  var stack: seq[Element]
  for child in element.elementList_rev:
    stack.add(child)
  while stack.len > 0:
    let child = stack.pop()
    if predicate(child):
      result.add(child)
    for child in element.elementList_rev:
      stack.add(child)

func all_descendants*(element: Element): seq[Element] =
  var stack: seq[Element]
  for child in element.elementList_rev:
    stack.add(child)
  while stack.len > 0:
    let child = stack.pop()
    result.add(child)
    for child in element.elementList_rev:
      stack.add(child)

func previousElementSibling*(elem: Element): Element {.jsfget.} =
  if elem.parentNode == nil: return nil
  var i = elem.parentNode.childList.find(elem)
  dec i
  while i >= 0:
    if elem.parentNode.childList[i].nodeType == ELEMENT_NODE:
      return elem
    dec i
  return nil

func nextElementSibling*(elem: Element): Element {.jsfget.} =
  if elem.parentNode == nil: return nil
  var i = elem.parentNode.childList.find(elem)
  inc i
  while i < elem.parentNode.childList.len:
    if elem.parentNode.childList[i].nodeType == ELEMENT_NODE:
      return elem
    inc i
  return nil

func documentElement(document: Document): Element {.jsfget.} =
  document.firstElementChild()

func attr*(element: Element, s: string): string {.inline.} =
  return element.attrs.getOrDefault(s, "")

func attri*(element: Element, s: string): Option[int] =
  let a = element.attr(s)
  try:
    return some(parseInt(a))
  except ValueError:
    return none(int)

func attrigz*(element: Element, s: string): Option[int] =
  let a = element.attr(s)
  try:
    let i = parseInt(a)
    if i > 0:
      return some(i)
  except ValueError:
    discard

func attrb*(element: Element, s: string): bool =
  if s in element.attrs:
    return true
  return false

# Element attribute reflection (getters)
func className(element: Element): string {.jsfget.} =
  element.attr("class")

#TODO implement JS union types for ref object...
func size*(element: HTMLInputElement): int {.jsfget.} =
  element.attrigz("size").get(20)

func size*(element: HTMLSelectElement): int {.jsfget.} =
  element.attrigz("size").get(20)

func cols*(element: HTMLTextAreaElement): int {.jsfget.} =
  element.attrigz("cols").get(20)

func rows*(element: HTMLTextAreaElement): int {.jsfget.} =
  element.attrigz("rows").get(1)

func innerHTML*(element: Element): string {.jsfget.} =
  for child in element.childList:
    result &= $child

func outerHTML*(element: Element): string {.jsfget.} =
  return $element

func crossorigin(element: HTMLScriptElement): CORSAttribute =
  if not element.attrb("crossorigin"):
    return NO_CORS
  case element.attr("crossorigin")
  of "anonymous", "":
    return ANONYMOUS
  of "use-credentials":
    return USE_CREDENTIALS
  return ANONYMOUS

func referrerpolicy(element: HTMLScriptElement): Option[ReferrerPolicy] =
  getReferrerPolicy(element.attr("referrerpolicy"))

proc sheets*(element: Element): seq[CSSStylesheet] =
  for child in element.elementList:
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

proc attr*(element: Element, name, value: string)

#TODO custom elements
func newHTMLElement*(document: Document, tagType: TagType, namespace = Namespace.HTML, prefix = none[string](), attrs = Table[string, string]()): HTMLElement =
  case tagType
  of TAG_INPUT:
    result = new(HTMLInputElement)
  of TAG_A:
    result = new(HTMLAnchorElement)
  of TAG_SELECT:
    result = new(HTMLSelectElement)
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
  result.attributes = NamedNodeMap(element: result)
  {.cast(noSideEffect).}:
    for k, v in attrs:
      result.attr(k, v)
  if tagType == TAG_SCRIPT:
    HTMLScriptElement(result).internalNonce = result.attr("nonce")

func newHTMLElement*(document: Document, localName: string, namespace = Namespace.HTML, prefix = none[string](), tagType = tagType(localName), attrs = Table[string, string]()): Element =
  result = document.newHTMLElement(tagType, namespace, prefix, attrs)
  if tagType == TAG_UNKNOWN:
    result.localName = localName

func newDocument*(): Document {.jsctor.} =
  new(result)
  result.nodeType = DOCUMENT_NODE
  result.document = result
  result.contentType = "text/html"

func newDocumentType*(document: Document, name: string, publicId = "", systemId = ""): DocumentType {.jsctor.} =
  new(result)
  result.nodeType = DOCUMENT_TYPE_NODE
  result.document = document
  result.name = name
  result.publicId = publicId
  result.systemId = systemId

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

func baseURL*(document: Document): Url =
  #TODO frozen base url...
  var href = ""
  for base in document.elements(TAG_BASE):
    if base.attrb("href"):
      href = base.attr("href")
  if href == "":
    return document.url
  if document.url == nil:
    return newURL("about:blank") #TODO ???
  let url = parseURL(href, some(document.url))
  if url.isNone:
    return document.url
  return url.get

func parseURL*(document: Document, s: string): Option[URL] =
  #TODO encodings
  return parseURL(s, some(document.baseURL))

func href*[T: HTMLAnchorElement|HTMLLinkElement|HTMLBaseElement](element: T): string =
  if element.attrb("href"):
    let url = parseUrl(element.attr("href"), some(element.document.url))
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

proc invalidateCollections(node: Node): bool {.discardable.} =
  for collection in node.liveCollections:
    collection.invalid = true
  if node.parentHasCollections:
    if not node.parentNode.invalidateCollections():
      node.parentHasCollections = false
  return node.liveCollections.len != 0 or node.parentHasCollections

proc delAttr(element: Element, i: int) =
  if i != -1:
    let attr = element.attributes.attrlist[i]
    element.attrs.del(attr.name)
    element.attributes.attrlist.delete(i)
    element.invalidateCollections()
    element.invalid = true

proc delAttr(element: Element, name: string) =
  let i = element.attributes.findAttr(name)
  if i != -1:
    element.attributes.attrlist.delete(i)
    element.invalidateCollections()
    element.invalid = true

proc reflectAttrs(element: Element, name, value: string) =
  template reflect_str(element: Element, n: static string, val: untyped) =
    if name == n:
      element.val = value
      return
  template reflect_str(element: Element, n: static string, val, fun: untyped) =
    if name == n:
      element.val = fun(value)
  template reflect_bool(element: Element, name: static string, val: untyped) =
    if name in element.attrs:
      element.val = true
  element.reflect_str "id", id
  if name == "class":
    element.classList.setLen(0)
    let classList = value.split(AsciiWhitespace)
    for x in classList:
      if x != "" and x notin element.classList:
        element.classList.add(x)
    return
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    input.reflect_str "value", value
    input.reflect_str "type", inputType, inputType
    input.reflect_bool "checked", checked
  of TAG_OPTION:
    let option = HTMLOptionElement(element)
    option.reflect_bool "selected", selected
  of TAG_BUTTON:
    let button = HTMLButtonElement(element)
    button.reflect_str "type", ctype, (func(s: string): ButtonType =
      case s
      of "submit": return BUTTON_SUBMIT
      of "reset": return BUTTON_RESET
      of "button": return BUTTON_BUTTON)
  else: discard

proc attr0(element: Element, name, value: string) =
  element.attrs.withValue(name, val):
    val[] = value
    element.invalidateCollections()
    element.invalid = true
  do: # else
    element.attrs[name] = value
  element.reflectAttrs(name, value)

proc attr*(element: Element, name, value: string) =
  let i = element.attributes.findAttr(name)
  if i != -1:
    element.attributes.attrlist[i].value = value
  else:
    element.attributes.attrlist.add(element.newAttr(name, value))
  element.attr0(name, value)

proc attrigz(element: Element, name: string, value: int) =
  if value > 0:
    element.attr(name, $value)

proc setAttribute(element: Element, qualifiedName, value: string) {.jsfunc.} =
  element.attr(qualifiedName, value)

proc setAttributeNS(element: Element, namespace, qualifiedName, value: string) {.jsfunc.} =
  if namespace == "" or namespace == $Namespace.HTML:
    element.attr(qualifiedName, value)
  if namespace notin NamespaceMap:
    return
  #TODO validate and extract
  element.attr0(qualifiedName, value)
  let ns = NamespaceMap[namespace]
  let i = element.attributes.findAttr(qualifiedName)
  if i == -1:
    let s = qualifiedName.until(':')
    if s.len < qualifiedName.len:
      element.attributes.attrlist.add(element.newAttr(qualifiedName.substr(s.len), value, s, ns))
    else:
      element.attributes.attrlist.add(element.newAttr(qualifiedName, value, "", ns))
  else:
    element.attributes.attrlist[i].value = value

proc removeAttribute(element: Element, qualifiedName: string) {.jsfunc.} =
  element.delAttr(qualifiedName)

proc removeAttributeNS(element: Element, namespace, localName: string) {.jsfunc.} =
  #TODO use namespace
  element.delAttr(localName)

proc value(attr: Attr, s: string) {.jsfset.} =
  attr.value = s
  if attr.ownerElement != nil:
    attr.ownerElement.attr0(attr.name, s)

# Element attribute reflection (setters)
proc className(element: Element, s: string) {.jsfset.} =
  element.attr("class", s)

proc size(element: HTMLInputElement, n: int) {.jsfset.} =
  element.attrigz("size", n)

proc size(element: HTMLSelectElement, n: int) {.jsfset.} =
  element.attrigz("size", n)

proc cols(element: HTMLTextAreaElement, n: int) {.jsfset.} =
  element.attrigz("cols", n)

proc rows(element: HTMLTextAreaElement, n: int) {.jsfset.} =
  element.attrigz("rows", n)

proc setNamedItem*(map: NamedNodeMap, attr: Attr): Option[Attr] {.jserr, jsfunc.} =
  if attr.ownerElement != nil and attr.ownerElement != map.element:
    #TODO should be DOMException
    JS_ERR JS_TypeError, "InUseAttributeError"
  if attr.name in map.element.attrs:
    return some(attr)
  let i = map.findAttr(attr.name)
  if i != -1:
    result = some(map.attrlist[i])
    map.attrlist.delete(i)
  map.element.attrs[attr.name] = attr.value
  map.attrlist.add(attr)

proc setNamedItemNS*(map: NamedNodeMap, attr: Attr): Option[Attr] {.jsfunc.} =
  map.setNamedItem(attr)

proc removeNamedItem*(map: NamedNodeMap, qualifiedName: string): Attr {.jserr, jsfunc.} =
  let i = map.findAttr(qualifiedName)
  if i != -1:
    let attr = map.attrlist[i]
    map.element.delAttr(i)
    return attr
  #TODO should be DOMException
  JS_ERR JS_TypeError, "Not found"

proc removeNamedItemNS*(map: NamedNodeMap, namespace, localName: string): Attr =
  #TODO TODO TODO
  map.removeNamedItem(localName)

proc id(element: Element, id: string) {.jsfset.} =
  element.id = id
  element.attr("id", id)

# Pass an index to avoid searching for it.
proc remove*(node: Node, index: int, suppressObservers: bool) =
  let parent = node.parentNode
  assert parent != nil
  assert index != -1
  #TODO live ranges
  #TODO NodeIterator
  let oldPreviousSibling = node.previousSibling
  let oldNextSibling = node.nextSibling
  parent.childList.delete(index)
  if oldPreviousSibling != nil:
    oldPreviousSibling.nextSibling = oldNextSibling
  if oldNextSibling != nil:
    oldNextSibling.previousSibling = oldPreviousSibling
  discard node.parentNode.invalidateCollections()
  node.parentHasCollections = false
  node.parentNode = nil
  node.parentElement = nil
  node.root = nil

  #TODO assigned, shadow root, shadow root again, custom nodes, registered observers
  #TODO not suppress observers => queue tree mutation record

proc remove*(node: Node, suppressObservers = false) =
  let index = node.parentNode.childList.find(node)
  node.remove(index, suppressObservers)

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
    child.previousSibling = parent.childList[index - 1]
    child.previousSibling.nextSibling = child
  if index + 1 < parent.childList.len:
    child.nextSibling = parent.childList[index + 1]
    child.nextSibling.previousSibling = child
  child.invalidateCollections()
  child.parentHasCollections = parent.liveCollections.len > 0 or parent.parentHasCollections
  child.invalidateCollections()

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
  if element.tagType in ListedElements and element.attrb("form") and element.isConnected:
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
  if node.nodeType notin {DOCUMENT_FRAGMENT_NODE, DOCUMENT_TYPE_NODE, ELEMENT_NODE} + CharacterDataNodes:
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

# WARNING ditto
proc insert*(parent, node, before: Node) =
  let nodes = if node.nodeType == DOCUMENT_FRAGMENT_NODE: node.childList
  else: @[node]
  let count = nodes.len
  if count == 0:
    return
  if node.nodeType == DOCUMENT_FRAGMENT_NODE:
    for i in countdown(node.childList.high, 0):
      node.childList[i].remove(i, true)
    #TODO tree mutation record
  if before != nil:
    #TODO live ranges
    discard
  for node in nodes:
    parent.document.adopt(node)
    if before == nil:
      parent.childList.add(node)
      parent.applyChildInsert(node, parent.childList.high)
    else:
      let index = parent.childList.find(before)
      parent.childList.insert(node, index)
      parent.applyChildInsert(node, index)
    if node.nodeType == ELEMENT_NODE:
      #TODO shadow root
      insertionSteps(node)

proc insertBefore(parent, node, before: Node): Node {.jserr, jsfunc.} =
  if parent.preInsertionValidity(node, before):
    let referenceChild = if before == node:
      node.nextSibling
    else:
      before
    parent.insert(node, referenceChild)
    return node
  #TODO use preInsertionValidity result
  JS_ERR JS_TypeError, "Pre-insertion validity violated"

proc appendChild(parent, node: Node): Node {.jsfunc.} =
  return parent.insertBefore(node, nil)

proc append*(parent, node: Node) =
  discard parent.appendChild(node)

#TODO replaceChild

proc removeChild(parent, node: Node): Node {.jsfunc.} =
  #TODO should be DOMException
  if node.parentNode != parent:
    JS_ERR JS_TypeError, "NotFoundError"
  node.remove()

proc replaceAll(parent, node: Node) =
  for i in countdown(parent.childList.high, 0):
    parent.childList[i].remove(i, true)
  if node != nil:
    if node.nodeType == DOCUMENT_FRAGMENT_NODE:
      for child in node.childList:
        parent.append(child)
    else:
      parent.append(node)
  #TODO tree mutation record

proc textContent*(node: Node, data: Option[string]) {.jsfset.} =
  case node.nodeType
  of DOCUMENT_FRAGMENT_NODE, ELEMENT_NODE:
    let x = if data.isSome:
      node.document.newText(data.get)
    else:
      nil
    node.replaceAll(x)
  of ATTRIBUTE_NODE:
    value(Attr(node), data.get(""))
  of TEXT_NODE, COMMENT_NODE:
    CharacterData(node).data = data.get("")
  else: discard

proc reset*(form: HTMLFormElement) =
  for control in form.controls:
    control.resetElement()
    control.invalid = true

proc renderBlocking*(element: Element): bool =
  if "render" in element.attr("blocking").split(AsciiWhitespace):
    return true
  if element.tagType == TAG_SCRIPT:
    let element = HTMLScriptElement(element)
    if element.ctype == CLASSIC and element.parserDocument != nil and
        not element.attrb("async") and not element.attrb("defer"):
      return true
  return false

proc blockRendering*(element: Element) =
  let document = element.document
  if document != nil and document.contentType == "text/html" and document.body == nil:
    element.document.renderBlockingElements.add(element)

proc markAsReady(element: HTMLScriptElement, res: ScriptResult) =
  element.scriptResult = res
  if element.onReady != nil:
    element.onReady()
    element.onReady = nil
  element.delayingTheLoadEvent = false

proc createClassicScript(source: string, baseURL: URL, options: ScriptOptions, mutedErrors = false): Script =
  return Script(
    record: source,
    baseURL: baseURL,
    options: options,
    mutedErrors: mutedErrors
  )

#TODO settings object
proc fetchClassicScript(element: HTMLScriptElement, url: URL,
                        options: ScriptOptions, cors: CORSAttribute,
                        cs: Charset, onComplete: (proc(element: HTMLScriptElement,
                                                       res: ScriptResult))) =
  if not element.scriptingEnabled:
      element.onComplete(ScriptResult(t: RESULT_NULL))
  else:
    let loader = element.document.window.loader
    if loader.isSome:
      let request = createPotentialCORSRequest(url, RequestDestination.SCRIPT, cors)
      #TODO this should be async...
      let r = loader.get.doRequest(request)
      if r.res != 0 or r.body == nil:
        element.onComplete(ScriptResult(t: RESULT_NULL))
      else:
        #TODO use charset from content-type
        let cs = if cs == CHARSET_UNKNOWN: CHARSET_UTF_8 else: cs
        let source = newDecoderStream(r.body, cs = cs).readAll()
        #TODO use response url
        let script = createClassicScript(source, url, options, false)
        element.markAsReady(ScriptResult(t: RESULT_SCRIPT, script: script))

#TODO TODO TODO do something with this (redirect stderr?)
proc log*(console: console, ss: varargs[string]) {.jsfunc.} =
  var s = ""
  for i in 0..<ss.len:
    s &= ss[i]
    #console.err.write(ss[i])
    if i != ss.high:
      s &= ' '
      #console.err.write(' ')
  eprint s
  #console.err.write('\n')
  #console.err.flush()

proc execute*(element: HTMLScriptElement) =
  let document = element.document
  if document != element.preparationTimeDocument:
    return
  let i = document.renderBlockingElements.find(element)
  if i != -1:
    document.renderBlockingElements.delete(i)
  if element.scriptResult.t == RESULT_NULL:
    #TODO fire error event
    return
  case element.ctype
  of CLASSIC:
    let oldCurrentScript = document.currentScript
    #TODO not if shadow root
    document.currentScript = element
    if document.window != nil and document.window.jsctx != nil:
      let ret = document.window.jsctx.eval(element.scriptResult.script.record, "<script>", JS_EVAL_TYPE_GLOBAL)
      if JS_IsException(ret):
        let ss = newStringStream()
        document.window.jsctx.writeException(ss)
        ss.setPosition(0)
        document.window.console.log("Exception in document", $document.url, ss.readAll())
    document.currentScript = oldCurrentScript
  else: discard #TODO

# https://html.spec.whatwg.org/multipage/scripting.html#prepare-the-script-element
proc prepare*(element: HTMLScriptElement) =
  if element.alreadyStarted:
    return
  let parserDocument = element.parserDocument
  element.parserDocument = nil
  if parserDocument != nil and not element.attrb("async"):
    element.forceAsync = true
  let sourceText = element.childTextContent
  if not element.attrb("src") and sourceText == "":
    return
  if not element.isConnected:
    return
  let typeString = if element.attr("type") != "":
    element.attr("type").strip(chars = AsciiWhitespace).toLowerAscii()
  elif element.attr("language") != "":
    "text/" & element.attr("language").toLowerAscii()
  else:
    "text/javascript"
  if typeString.isJavaScriptType():
    element.ctype = CLASSIC
  elif typeString == "module":
    element.ctype = MODULE
  elif typeString == "importmap":
    element.ctype = IMPORTMAP
  else:
    return
  if parserDocument != nil:
    element.parserDocument = parserDocument
    element.forceAsync = false
  element.alreadyStarted = true
  element.preparationTimeDocument = element.document
  if parserDocument != nil and parserDocument != element.preparationTimeDocument:
    return
  if not element.scriptingEnabled:
    return
  if element.attrb("nomodule") and element.ctype == CLASSIC:
    return
  #TODO content security policy
  if element.ctype == CLASSIC and element.attrb("event") and element.attrb("for"):
    let f = element.attr("for").strip(chars = AsciiWhitespace)
    let event = element.attr("event").strip(chars = AsciiWhitespace)
    if not f.equalsIgnoreCase("window"):
      return
    if not event.equalsIgnoreCase("onload") and not event.equalsIgnoreCase("onload()"):
      return
  let cs = getCharset(element.attr("charset"))
  let encoding = if cs != CHARSET_UNKNOWN: cs else: element.document.charset
  let classicCORS = element.crossorigin
  var options = ScriptOptions(
    nonce: element.internalNonce,
    integrity: element.attr("integrity"),
    parserMetadata: if element.parserDocument != nil: PARSER_INSERTED else: NOT_PARSER_INSERTED,
    referrerpolicy: element.referrerpolicy
  )
  #TODO settings object
  if element.attrb("src"):
    if element.ctype == IMPORTMAP:
      #TODO fire error event
      return
    let src = element.attr("src")
    if src == "":
      #TODO fire error event
      return
    element.fromAnExternalFile = true
    let url = element.document.parseURL(src)
    if url.isNone:
      #TODO fire error event
      return
    if element.renderBlocking:
      element.blockRendering()
    element.delayingTheLoadEvent = true
    if element in element.document.renderBlockingElements:
      options.renderBlocking = true
    if element.ctype == CLASSIC:
      element.fetchClassicScript(url.get, options, classicCORS, encoding, markAsReady)
    else:
      #TODO MODULE
      element.markAsReady(ScriptResult(t: RESULT_NULL))
  else:
    let baseURL = element.document.baseURL
    if element.ctype == CLASSIC:
      let script = createClassicScript(sourceText, baseURL, options)
      element.markAsReady(ScriptResult(t: RESULT_SCRIPT, script: script))
    else:
      #TODO MODULE, IMPORTMAP
      element.markAsReady(ScriptResult(t: RESULT_NULL))
  if element.ctype == CLASSIC and element.attrb("src") or element.ctype == MODULE:
    let prepdoc = element.preparationTimeDocument 
    if element.attrb("async"):
      prepdoc.scriptsToExecSoon.add(element)
      element.onReady = (proc() =
        element.execute()
        let i = prepdoc.scriptsToExecSoon.find(element)
        element.preparationTimeDocument.scriptsToExecSoon.delete(i)
      )
    elif element.parserDocument == nil:
      prepdoc.scriptsToExecInOrder.addFirst(element)
      element.onReady = (proc() =
        if prepdoc.scriptsToExecInOrder.len > 0 and prepdoc.scriptsToExecInOrder[0] != element:
          while prepdoc.scriptsToExecInOrder.len > 0:
            let script = prepdoc.scriptsToExecInOrder[0]
            if script.scriptResult.t == RESULT_UNINITIALIZED:
              break
            script.execute()
            prepdoc.scriptsToExecInOrder.shrink(1)
      )
    elif element.ctype == MODULE or element.attrb("defer"):
      element.parserDocument.scriptsToExecOnLoad.addFirst(element)
      element.onReady = (proc() =
        element.readyForParserExec = true
      )
    else:
      element.parserDocument.parserBlockingScript = element
      element.blockRendering()
      element.onReady = (proc() =
        element.readyForParserExec = true
      )
  else:
    #TODO if CLASSIC, parserDocument != nil, parserDocument has a style sheet
    # that is blocking scripts, either the parser is an XML parser or a HTML
    # parser with a script level <= 1
    element.execute()

# Forward definition hack (these are set in selectors.nim)
var doqsa*: proc (node: Node, q: string): seq[Element]
var doqs*: proc (node: Node, q: string): Element

proc querySelectorAll*(node: Node, q: string): seq[Element] {.jsfunc.} =
  return doqsa(node, q)

proc querySelector*(node: Node, q: string): Element {.jsfunc.} =
  return doqs(node, q)

proc addconsoleModule*(ctx: JSContext) =
  #TODO console should not have a prototype
  ctx.registerType(console, nointerface = true)

proc addDOMModule*(ctx: JSContext) =
  let eventTargetCID = ctx.registerType(EventTarget)
  let nodeCID = ctx.registerType(Node, parent = eventTargetCID)
  ctx.registerType(NodeList)
  ctx.registerType(HTMLCollection)
  ctx.registerType(Document, parent = nodeCID)
  let characterDataCID = ctx.registerType(CharacterData, parent = nodeCID)
  ctx.registerType(Comment, parent = characterDataCID)
  ctx.registerType(Text, parent = characterDataCID)
  ctx.registerType(DocumentType, parent = nodeCID)
  let elementCID = ctx.registerType(Element, parent = nodeCID)
  ctx.registerType(Attr)
  ctx.registerType(NamedNodeMap)
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
  ctx.registerType(HTMLTextAreaElement, parent = htmlElementCID)
