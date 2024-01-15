import std/deques
import std/options
import std/streams

import html/catom
import html/dom
import html/enums
import js/error
import js/fromjs
import js/javascript
import types/url

import chakasu/charset
import chakasu/decoderstream
import chakasu/encoderstream

import chame/htmlparser
import chame/tags

# DOMBuilder implementation for Chawan.

type CharsetConfidence = enum
  CONFIDENCE_TENTATIVE, CONFIDENCE_CERTAIN, CONFIDENCE_IRRELEVANT

type
  ChaDOMBuilder = ref object of DOMBuilder[Node, CAtom]
    charset: Charset
    confidence: CharsetConfidence
    document: Document
    isFragment: bool
    factory: CAtomFactory
    poppedScript: HTMLScriptElement

type
  DOMBuilderImpl = ChaDOMBuilder
  HandleImpl = Node
  AtomImpl = CAtom

include chame/htmlparseriface

type DOMParser = ref object # JS interface

jsDestructor(DOMParser)

proc getDocumentImpl(builder: ChaDOMBuilder): Node =
  return builder.document

proc atomToTagTypeImpl(builder: ChaDOMBuilder, atom: CAtom): TagType =
  return builder.factory.toTagType(atom)

proc tagTypeToAtomImpl(builder: ChaDOMBuilder, tagType: TagType): CAtom =
  return builder.factory.toAtom(tagType)

proc strToAtomImpl(builder: ChaDOMBuilder, s: string): CAtom =
  return builder.factory.toAtom(s)

proc finish(builder: ChaDOMBuilder) =
  while builder.document.scriptsToExecOnLoad.len > 0:
    #TODO spin event loop
    let script = builder.document.scriptsToExecOnLoad.popFirst()
    script.execute()
  #TODO events

proc restart(builder: ChaDOMBuilder) =
  let document = newDocument(builder.factory)
  document.contentType = "text/html"
  let oldDocument = builder.document
  document.url = oldDocument.url
  let window = oldDocument.window
  if window != nil:
    document.window = window
    window.document = document
  builder.document = document
  assert document.factory != nil

proc setQuirksModeImpl(builder: ChaDOMBuilder, quirksMode: QuirksMode) =
  if not builder.document.parser_cannot_change_the_mode_flag:
    builder.document.mode = quirksMode

proc setEncodingImpl(builder: ChaDOMBuilder, encoding: string):
    SetEncodingResult =
  let charset = getCharset(encoding)
  if charset == CHARSET_UNKNOWN:
    return SET_ENCODING_CONTINUE
  if builder.charset in {CHARSET_UTF_16_LE, CHARSET_UTF_16_BE}:
    builder.confidence = CONFIDENCE_CERTAIN
    return SET_ENCODING_CONTINUE
  builder.confidence = CONFIDENCE_CERTAIN
  if charset == builder.charset:
    return SET_ENCODING_CONTINUE
  if charset == CHARSET_X_USER_DEFINED:
    builder.charset = CHARSET_WINDOWS_1252
  else:
    builder.charset = charset
  return SET_ENCODING_STOP

proc getTemplateContentImpl(builder: ChaDOMBuilder, handle: Node): Node =
  return HTMLTemplateElement(handle).content

proc getParentNodeImpl(builder: ChaDOMBuilder, handle: Node): Option[Node] =
  return option(handle.parentNode)

proc getLocalNameImpl(builder: ChaDOMBuilder, handle: Node): CAtom =
  return Element(handle).localName

proc getNamespaceImpl(builder: ChaDOMBuilder, handle: Node): Namespace =
  return Element(handle).namespace

proc createHTMLElementImpl(builder: ChaDOMBuilder): Node =
  return builder.document.newHTMLElement(TAG_HTML)

proc createElementForTokenImpl(builder: ChaDOMBuilder, localName: CAtom,
    namespace: Namespace, intendedParent: Node, htmlAttrs: Table[CAtom, string],
    xmlAttrs: seq[ParsedAttr[CAtom]]): Node =
  let document = builder.document
  let element = document.newHTMLElement(localName, namespace)
  for k, v in htmlAttrs:
    element.attr(k, v)
  for attr in xmlAttrs:
    element.attrns(attr.name, attr.prefix, attr.namespace, attr.value)
  if element.tagType in ResettableElements:
    element.resetElement()
  if element of HTMLScriptElement:
    let script = HTMLScriptElement(element)
    script.parserDocument = document
    script.forceAsync = false
    # Note: per standard, we could set already started to true here when we
    # are parsing from document.write, but that sounds like a horrible idea.
  return element

proc createCommentImpl(builder: ChaDOMBuilder, text: string): Node =
  return builder.document.createComment(text)

proc createDocumentTypeImpl(builder: ChaDOMBuilder, name, publicId,
    systemId: string): Node =
  return builder.document.newDocumentType(name, publicId, systemId)

proc insertBeforeImpl(builder: ChaDOMBuilder, parent, child: Node,
    before: Option[Node]) =
  discard parent.insertBefore(child, before.get(nil))

proc insertTextImpl(builder: ChaDOMBuilder, parent: Node, text: string,
    before: Option[Node]) =
  let prevSibling = if before.isSome:
    before.get.previousSibling
  else:
    parent.lastChild
  if prevSibling != nil and prevSibling of Text:
    Text(prevSibling).data &= text
  else:
    let text = builder.document.createTextNode(text)
    discard parent.insertBefore(text, before.get(nil))

proc removeImpl(builder: ChaDOMBuilder, child: Node) =
  child.remove(suppressObservers = true)

proc moveChildrenImpl(builder: ChaDOMBuilder, fromNode, toNode: Node) =
  var tomove = fromNode.childList
  for node in tomove:
    node.remove(suppressObservers = true)
  for child in tomove:
    toNode.insert(child, nil)

proc addAttrsIfMissingImpl(builder: ChaDOMBuilder, handle: Node,
    attrs: Table[CAtom, string]) =
  let element = Element(handle)
  for k, v in attrs:
    if not element.attrb(k):
      element.attr(k, v)

proc setScriptAlreadyStartedImpl(builder: ChaDOMBuilder, script: Node) =
  HTMLScriptElement(script).alreadyStarted = true

proc associateWithFormImpl(builder: ChaDOMBuilder, element, form,
    intendedParent: Node) =
  if form.inSameTree(intendedParent):
    #TODO remove following test eventually
    if Element(element).tagType in SupportedFormAssociatedElements:
      let element = FormAssociatedElement(element)
      element.setForm(HTMLFormElement(form))
      element.parserInserted = true

proc elementPoppedImpl(builder: ChaDOMBuilder, element: Node) =
  let element = Element(element)
  if element of HTMLTextAreaElement:
    element.resetElement()
  elif element of HTMLScriptElement:
    assert builder.poppedScript == nil or not builder.document.scriptingEnabled
    builder.poppedScript = HTMLScriptElement(element)

proc newChaDOMBuilder(url: URL, window: Window, factory: CAtomFactory,
    isFragment = false): ChaDOMBuilder =
  let document = newDocument(factory)
  document.contentType = "text/html"
  document.url = url
  if window != nil:
    document.window = window
    window.document = document
  return ChaDOMBuilder(
    document: document,
    isFragment: isFragment,
    factory: factory
  )

# https://html.spec.whatwg.org/multipage/parsing.html#parsing-html-fragments
proc parseHTMLFragment*(element: Element, s: string): seq[Node] =
  let url = parseURL("about:blank").get
  let factory = element.document.factory
  let builder = newChaDOMBuilder(url, nil, factory)
  let inputStream = newStringStream(s)
  builder.isFragment = true
  let document = builder.document
  document.mode = element.document.mode
  let state = case element.tagType
  of TAG_TITLE, TAG_TEXTAREA: RCDATA
  of TAG_STYLE, TAG_XMP, TAG_IFRAME, TAG_NOEMBED, TAG_NOFRAMES: RAWTEXT
  of TAG_SCRIPT: SCRIPT_DATA
  of TAG_NOSCRIPT:
    if element.document != nil and element.document.scriptingEnabled:
      RAWTEXT
    else:
      DATA
  of TAG_PLAINTEXT:
    PLAINTEXT
  else: DATA
  let root = document.newHTMLElement(TAG_HTML)
  document.append(root)
  let opts = HTML5ParserOpts[Node, CAtom](
    isIframeSrcdoc: false, #TODO?
    scripting: false,
    ctx: some((Node(element), element.localName)),
    initialTokenizerState: state,
    openElementsInit: @[(Node(root), root.localName)],
    pushInTemplate: element.tagType == TAG_TEMPLATE
  )
  var parser = initHTML5Parser(builder, opts)
  var buffer: array[4096, char]
  while true:
    let n = inputStream.readData(addr buffer[0], buffer.len)
    if n == 0: break
    let res = parser.parseChunk(buffer.toOpenArray(0, n - 1))
    assert res == PRES_CONTINUE # scripting is false, so this must be continue
  parser.finish()
  builder.finish()
  return root.childList

#TODO this should be handled by decoderstream
proc bomSniff(inputStream: Stream): Charset =
  let bom = inputStream.readStr(2)
  if bom == "\xFE\xFF":
    return CHARSET_UTF_16_BE
  if bom == "\xFF\xFE":
    return CHARSET_UTF_16_LE
  if bom == "\xEF\xBB":
    if inputStream.readChar() == '\xBF':
      return CHARSET_UTF_8
  inputStream.setPosition(0)
  return CHARSET_UNKNOWN

proc parseHTML*(inputStream: Stream, window: Window, url: URL,
    factory: CAtomFactory, charsets: seq[Charset] = @[],
    seekable = true): Document =
  let opts = HTML5ParserOpts[Node, CAtom](
    isIframeSrcdoc: false, #TODO?
    scripting: window != nil and window.settings.scripting
  )
  let builder = newChaDOMBuilder(url, window, factory)
  var charsetStack: seq[Charset]
  for i in countdown(charsets.high, 0):
    charsetStack.add(charsets[i])
  var seekable = seekable
  var inputStream = inputStream
  if seekable:
    let scs = inputStream.bomSniff()
    if scs != CHARSET_UNKNOWN:
      charsetStack.add(scs)
      builder.confidence = CONFIDENCE_CERTAIN
      seekable = false
  if charsetStack.len == 0:
    charsetStack.add(DefaultCharset) # UTF-8
  while true:
    builder.charset = charsetStack.pop()
    if seekable:
      builder.confidence = CONFIDENCE_TENTATIVE # used in the next iteration
    else:
      builder.confidence = CONFIDENCE_CERTAIN
    let em = if charsetStack.len == 0 or not seekable:
      DECODER_ERROR_MODE_REPLACEMENT
    else:
      DECODER_ERROR_MODE_FATAL
    let decoder = newDecoderStream(inputStream, builder.charset, errormode = em)
    let encoder = newEncoderStream(decoder, CHARSET_UTF_8,
      errormode = ENCODER_ERROR_MODE_FATAL)
    var parser = initHTML5Parser(builder, opts)
    let document = builder.document
    var buffer: array[4096, char]
    while true:
      let n = encoder.readData(addr buffer[0], buffer.len)
      if n == 0: break
      var res = parser.parseChunk(buffer.toOpenArray(0, n - 1))
      # set insertion point for when it's needed
      var ip = parser.getInsertionPoint()
      while res == PRES_SCRIPT:
        if builder.poppedScript != nil:
          #TODO microtask
          document.writeBuffers.add(DocumentWriteBuffer())
          builder.poppedScript.prepare()
        while document.parserBlockingScript != nil:
          let script = document.parserBlockingScript
          document.parserBlockingScript = nil
          #TODO style sheet
          script.execute()
          assert document.parserBlockingScript != script
        builder.poppedScript = nil
        if document.writeBuffers.len == 0:
          if ip == n:
            # nothing left to re-parse.
            break
          # parse rest of input buffer
          res = parser.parseChunk(buffer.toOpenArray(ip, n - 1))
          ip += parser.getInsertionPoint() # move insertion point
        else:
          let writeBuffer = document.writeBuffers[^1]
          let p = writeBuffer.i
          let n = writeBuffer.data.len
          res = parser.parseChunk(writeBuffer.data.toOpenArray(p, n - 1))
          case res
          of PRES_CONTINUE:
            discard document.writeBuffers.pop()
            res = PRES_SCRIPT
          of PRES_SCRIPT:
            let pp = p + parser.getInsertionPoint()
            if pp == writeBuffer.data.len:
              discard document.writeBuffers.pop()
            else:
              writeBuffer.i = pp
          of PRES_STOP:
            break
            {.linearScanEnd.}
      # PRES_STOP is returned when we return SET_ENCODING_STOP from
      # setEncodingImpl. We immediately stop parsing in this case.
      if res == PRES_STOP:
        break
    parser.finish()
    if builder.confidence == CONFIDENCE_CERTAIN and seekable:
      # A meta tag describing the charset has been found; force use of this
      # charset.
      builder.restart()
      inputStream.setPosition(0)
      charsetStack.add(builder.charset)
      seekable = false
      continue
    if decoder.failed and seekable:
      # Retry with another charset.
      builder.restart()
      inputStream.setPosition(0)
      continue
    break
  builder.finish()
  return builder.document

proc newDOMParser(): DOMParser {.jsctor.} =
  return DOMParser()

proc parseFromString(ctx: JSContext, parser: DOMParser, str, t: string):
    JSResult[Document] {.jsfunc.} =
  case t
  of "text/html":
    let global = JS_GetGlobalObject(ctx)
    let window = if ctx.hasClass(Window):
      fromJS[Window](ctx, global).get(nil)
    else:
      Window(nil)
    JS_FreeValue(ctx, global)
    let url = if window != nil and window.document != nil:
      window.document.url
    else:
      newURL("about:blank").get
    #TODO this is probably broken in client (or at least sub-optimal)
    let factory = if window != nil: window.factory else: newCAtomFactory()
    let res = parseHTML(newStringStream(str), Window(nil), url, factory)
    return ok(res)
  of "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml":
    return err(newInternalError("XML parsing is not supported yet"))
  else:
    return err(newTypeError("Invalid mime type"))

proc addHTMLModule*(ctx: JSContext) =
  ctx.registerType(DOMParser)
