import deques
import options
import streams

import html/dom
import js/javascript
import types/url

import chakasu/charset

import chame/htmlparser
import chame/tags

# DOMBuilder implementation for Chawan.

type
  ChaDOMBuilder = ref object of DOMBuilder[Node]
    isFragment: bool

type DOMParser = ref object # JS interface

jsDestructor(DOMParser)

template getDocument(dombuilder: ChaDOMBuilder): Document =
  cast[Document](dombuilder.document)

proc finish(builder: DOMBuilder[Node]) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  while document.scriptsToExecOnLoad.len > 0:
    #TODO spin event loop
    let script = document.scriptsToExecOnLoad.popFirst()
    script.execute()
  #TODO events

proc parseError(builder: DOMBuilder[Node], message: string) =
  discard

proc setQuirksMode(builder: DOMBuilder[Node], quirksMode: QuirksMode) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  if not document.parser_cannot_change_the_mode_flag:
    document.mode = quirksMode

proc setCharacterSet(builder: DOMBuilder[Node], charset: Charset) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  document.charset = charset

proc getTemplateContent(builder: DOMBuilder[Node], handle: Node): Node =
  return HTMLTemplateElement(handle).content

proc getTagType(builder: DOMBuilder[Node], handle: Node): TagType =
  return Element(handle).tagType

proc getParentNode(builder: DOMBuilder[Node], handle: Node): Option[Node] =
  return option(handle.parentNode)

proc getLocalName(builder: DOMBuilder[Node], handle: Node): string =
  return Element(handle).localName

proc getNamespace(builder: DOMBuilder[Node], handle: Node): Namespace =
  return Element(handle).namespace

proc createElement(builder: DOMBuilder[Node], localName: string,
    namespace: Namespace, tagType: TagType,
    attrs: Table[string, string]): Node =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  let element = document.newHTMLElement(localName, namespace,
    tagType = tagType, attrs = attrs)
  if element.isResettable():
    element.resetElement()
  if tagType == TAG_SCRIPT:
    let script = HTMLScriptElement(element)
    script.parserDocument = document
    script.forceAsync = false
    if builder.isFragment:
      script.alreadyStarted = true
      #TODO document.write (?)
  return element

proc createComment(builder: DOMBuilder[Node], text: string): Node =
  let builder = cast[ChaDOMBuilder](builder)
  return builder.getDocument().createComment(text)

proc createDocumentType(builder: DOMBuilder[Node], name, publicId,
    systemId: string): Node =
  let builder = cast[ChaDOMBuilder](builder)
  return builder.getDocument().newDocumentType(name, publicId, systemId)

proc insertBefore(builder: DOMBuilder[Node], parent, child,
    before: Node) =
  discard parent.insertBefore(child, before)

proc insertText(builder: DOMBuilder[Node], parent: Node, text: string,
    before: Node) =
  let builder = cast[ChaDOMBuilder](builder)
  let prevSibling = if before != nil:
    before.previousSibling
  else:
    parent.lastChild
  if prevSibling != nil and prevSibling.nodeType == TEXT_NODE:
    Text(prevSibling).data &= text
  else:
    let text = builder.getDocument().createTextNode(text)
    discard parent.insertBefore(text, before)

proc remove(builder: DOMBuilder[Node], child: Node) =
  child.remove(true)

proc addAttrsIfMissing(builder: DOMBuilder[Node], element: Node,
    attrs: Table[string, string]) =
  let element = Element(element)
  for k, v in attrs:
    if not element.attrb(k):
      element.attr(k, v)

proc setScriptAlreadyStarted(builder: DOMBuilder[Node], script: Node) =
  HTMLScriptElement(script).alreadyStarted = true

proc associateWithForm(builder: DOMBuilder[Node], element, form,
    intendedParent: Node) =
  if form.inSameTree(intendedParent):
    #TODO remove following test eventually
    if Element(element).tagType in SupportedFormAssociatedElements:
      let element = FormAssociatedElement(element)
      element.setForm(HTMLFormElement(form))
      element.parserInserted = true

proc elementPopped(builder: DOMBuilder[Node], element: Node) =
  let builder = cast[ChaDOMBuilder](builder)
  let document = builder.getDocument()
  let element = Element(element)
  if element.tagType == TAG_TEXTAREA:
    element.resetElement()
  elif element.tagType == TAG_SCRIPT:
    #TODO microtask (maybe it works here too?)
    let script = HTMLScriptElement(element)
    #TODO document.write() (?)
    script.prepare()
    while document.parserBlockingScript != nil:
      let script = document.parserBlockingScript
      document.parserBlockingScript = nil
      #TODO style sheet
      script.execute()

proc newChaDOMBuilder(url: URL, window: Window): ChaDOMBuilder =
  let document = newDocument()
  document.contentType = "text/html"
  document.url = url
  if window != nil:
    document.window = window
    window.document = document
  return ChaDOMBuilder(
    document: document,
    finish: finish,
    setQuirksMode: setQuirksMode,
    setCharacterSet: setCharacterset,
    elementPopped: elementPopped,
    getTemplateContent: getTemplateContent,
    getTagType: getTagType,
    getParentNode: getParentNode,
    getLocalName: getLocalName,
    getNamespace: getNamespace,
    createElement: createElement,
    createComment: createComment,
    createDocumentType: createDocumentType,
    insertBefore: insertBefore,
    insertText: insertText,
    remove: remove,
    addAttrsIfMissing: addAttrsIfMissing,
    setScriptAlreadyStarted: setScriptAlreadyStarted,
    associateWithForm: associateWithForm,
    #TODO isSVGIntegrationPoint (SVG support)
  )

#TODO we shouldn't allow passing nil to window
proc parseHTML*(inputStream: Stream, window: Window, url: URL,
    charsets: seq[Charset] = @[], canReinterpret = true): Document =
  let builder = newChaDOMBuilder(url, window)
  let opts = HTML5ParserOpts[Node](
    isIframeSrcdoc: false, #TODO?
    scripting: window != nil and window.settings.scripting,
    canReinterpret: canReinterpret,
    charsets: charsets
  )
  builder.isFragment = opts.ctx.isSome
  parseHTML(inputStream, builder, opts)
  return Document(builder.document)

proc newDOMParser(): DOMParser {.jsctor.} =
  new(result)

proc parseFromString(parser: DOMParser, str: string, t: string):
    Result[Document, JSError] {.jsfunc.} =
  case t
  of "text/html":
    #TODO window should be stored in DOMParser somehow. Setting it to nil
    # is wrong.
    let url = newURL("about:blank").get
    let res = parseHTML(newStringStream(str), Window(nil), url)
    return ok(res)
  of "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml":
    return err(newInternalError("XML parsing is not supported yet"))
  else:
    return err(newTypeError("Invalid mime type"))

proc addHTMLModule*(ctx: JSContext) =
  ctx.registerType(DOMParser)
