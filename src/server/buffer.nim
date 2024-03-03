from std/strutils import split, toUpperAscii

import std/macros
import std/nativesockets
import std/net
import std/options
import std/os
import std/posix
import std/selectors
import std/streams
import std/tables
import std/unicode

import bindings/quickjs
import config/config
import css/cascade
import css/cssparser
import css/mediaquery
import css/sheet
import css/stylednode
import css/values
import display/term
import html/catom
import html/chadombuilder
import html/dom
import html/enums
import html/env
import html/event
import io/bufstream
import io/posixstream
import io/promise
import io/serialize
import io/serversocket
import io/socketstream
import js/fromjs
import js/javascript
import js/regex
import js/timeout
import js/tojs
import layout/renderdocument
import loader/headers
import loader/loader
import types/cell
import types/color
import types/cookie
import types/formdata
import types/opt
import types/referer
import types/url
import utils/strwidth
import utils/twtstr
import xhr/formdata as formdata_impl

from chagashi/decoder import newTextDecoder
import chagashi/charset
import chagashi/decodercore
import chagashi/validatorcore

import chame/tags

type
  BufferCommand* = enum
    bcLoad, bcForceRender, bcWindowChange, bcFindAnchor, bcReadSuccess,
    bcReadCanceled, bcClick, bcFindNextLink, bcFindPrevLink, bcFindNthLink,
    bcFindRevNthLink, bcFindNextMatch, bcFindPrevMatch, bcGetLines,
    bcUpdateHover, bcConnect, bcConnect2, bcGotoAnchor, bcCancel, bcGetTitle,
    bcSelect, bcRedirectToFd, bcReadFromFd, bcClone, bcFindPrevParagraph,
    bcFindNextParagraph

  BufferState = enum
    bsConnecting, bsLoadingPage, bsLoadingResources, bsLoaded

  HoverType* = enum
    htTitle = "TITLE"
    htLink = "URL"
    htImage = "IMAGE"

  BufferMatch* = object
    success*: bool
    x*: int
    y*: int
    str*: string

  Buffer* = ref object
    rfd: int # file descriptor of command pipe
    fd: int # file descriptor of buffer source
    url: URL # URL before readFromFd
    pstream: SocketStream # control stream
    savetask: bool
    ishtml: bool
    firstBufferRead: bool
    lines: FlexibleGrid
    request: Request # source request
    attrs: WindowAttributes
    window: Window
    document: Document
    prevStyled: StyledNode
    selector: Selector[int]
    istream: SocketStream
    bytesRead: int
    reportedBytesRead: int
    state: BufferState
    prevnode: StyledNode
    loader: FileLoader
    config: BufferConfig
    tasks: array[BufferCommand, int] #TODO this should have arguments
    hoverText: array[HoverType, string]
    estream: Stream # error stream
    ssock: ServerSocket
    factory: CAtomFactory
    uastyle: CSSStylesheet
    quirkstyle: CSSStylesheet
    userstyle: CSSStylesheet
    htmlParser: HTML5ParserWrapper
    bgcolor: CellColor
    needsBOMSniff: bool
    decoder: TextDecoder
    validator: ref TextValidatorUTF8
    validateBuf: seq[char]
    charsetStack: seq[Charset]
    charset: Charset
    tmpCacheFlag: bool

  InterfaceOpaque = ref object
    stream: Stream
    len: int

  BufferInterface* = ref object
    map: PromiseMap
    packetid: int
    opaque: InterfaceOpaque
    stream*: BufStream

proc getFromOpaque[T](opaque: pointer, res: var T) =
  let opaque = cast[InterfaceOpaque](opaque)
  if opaque.len != 0:
    opaque.stream.sread(res)

proc newBufferInterface*(stream: SocketStream, registerFun: proc(fd: int)):
    BufferInterface =
  let opaque = InterfaceOpaque(stream: stream)
  result = BufferInterface(
    map: newPromiseMap(cast[pointer](opaque)),
    packetid: 1, # ids below 1 are invalid
    opaque: opaque,
    stream: newBufStream(stream, registerFun)
  )

# After cloning a buffer, we need a new interface to the new buffer process.
# Here we create a new interface for that clone.
proc cloneInterface*(stream: SocketStream, registerFun: proc(fd: int)):
    BufferInterface =
  let iface = newBufferInterface(stream, registerFun)
  #TODO buffered data should probably be copied here
  # We have just fork'ed the buffer process inside an interface function,
  # from which the new buffer is going to return as well. So we must also
  # consume the return value of the clone function, which is the pid 0.
  var len: int
  var pid: Pid
  stream.sread(len)
  stream.sread(iface.packetid)
  stream.sread(pid)
  return iface

proc resolve*(iface: BufferInterface, packetid, len: int) =
  iface.opaque.len = len
  iface.map.resolve(packetid)

proc hasPromises*(iface: BufferInterface): bool =
  return not iface.map.empty()

# get enum identifier of proxy function
func getFunId(fun: NimNode): string =
  let name = fun[0] # sym
  return "bc" & name.strVal[0].toUpperAscii() & name.strVal.substr(1)

proc buildInterfaceProc(fun: NimNode, funid: string): tuple[fun, name: NimNode] =
  let name = fun[0] # sym
  let params = fun[3] # formalparams
  let retval = params[0] # sym
  var body = newStmtList()
  assert params.len >= 2 # return type, this value
  let nup = ident(funid) # add this to enums
  let this2 = newIdentDefs(ident("iface"), ident("BufferInterface"))
  let thisval = this2[0]
  body.add(quote do:
    `thisval`.stream.swrite(BufferCommand.`nup`)
    `thisval`.stream.swrite(`thisval`.packetid)
  )
  var params2: seq[NimNode]
  var retval2: NimNode
  var addfun: NimNode
  if retval.kind == nnkEmpty:
    addfun = quote do:
      `thisval`.map.addEmptyPromise(`thisval`.packetid)
    retval2 = ident("EmptyPromise")
  else:
    addfun = quote do:
      addPromise[`retval`](`thisval`.map, `thisval`.packetid, getFromOpaque[`retval`])
    retval2 = newNimNode(nnkBracketExpr).add(
      ident("Promise"),
      retval)
  params2.add(retval2)
  params2.add(this2)
  # flatten args
  for i in 2 ..< params.len:
    let param = params[i]
    for i in 0 ..< param.len - 2:
      let id2 = newIdentDefs(ident(param[i].strVal), param[^2])
      params2.add(id2)
  for i in 2 ..< params2.len:
    let s = params2[i][0] # sym e.g. url
    body.add(quote do:
      when typeof(`s`) is FileHandle:
        #TODO flush or something
        SocketStream(`thisval`.stream.source).sendFileHandle(`s`)
      else:
        `thisval`.stream.swrite(`s`)
    )
  body.add(quote do:
    let promise = `addfun`
    inc `thisval`.packetid
    return promise
  )
  var pragmas: NimNode
  if retval.kind == nnkEmpty:
    pragmas = newNimNode(nnkPragma).add(ident("discardable"))
  else:
    pragmas = newEmptyNode()
  return (newProc(name, params2, body, pragmas = pragmas), nup)

type
  ProxyFunction = ref object
    iname: NimNode # internal name
    ename: NimNode # enum name
    params: seq[NimNode]
    istask: bool
  ProxyMap = Table[string, ProxyFunction]

# Name -> ProxyFunction
var ProxyFunctions {.compileTime.}: ProxyMap

proc getProxyFunction(funid: string): ProxyFunction =
  if funid notin ProxyFunctions:
    ProxyFunctions[funid] = ProxyFunction()
  return ProxyFunctions[funid]

macro proxy0(fun: untyped) =
  fun[0] = ident(fun[0].strVal & "_internal")
  return fun

macro proxy1(fun: typed) =
  let funid = getFunId(fun)
  let iproc = buildInterfaceProc(fun, funid)
  let pfun = getProxyFunction(funid)
  pfun.iname = ident(fun[0].strVal & "_internal")
  pfun.ename = iproc[1]
  pfun.params.add(fun[3][0])
  var params2: seq[NimNode]
  params2.add(fun[3][0])
  for i in 1 ..< fun[3].len:
    let param = fun[3][i]
    pfun.params.add(param)
    for i in 0 ..< param.len - 2:
      let id2 = newIdentDefs(ident(param[i].strVal), param[^2])
      params2.add(id2)
  ProxyFunctions[funid] = pfun
  return iproc[0]

macro proxy(fun: typed) =
  quote do:
    proxy0(`fun`)
    proxy1(`fun`)

macro task(fun: typed) =
  let funid = getFunId(fun)
  let pfun = getProxyFunction(funid)
  pfun.istask = true
  fun

func getTitleAttr(node: StyledNode): string =
  if node == nil:
    return ""
  if node.t == STYLED_ELEMENT and node.node != nil:
    let element = Element(node.node)
    if element.attrb(atTitle):
      return element.attr(atTitle)
  if node.node != nil:
    var node = node.node
    for element in node.ancestors:
      if element.attrb(atTitle):
        return element.attr(atTitle)
  #TODO pseudo-elements
  return ""

const ClickableElements = {
  TAG_A, TAG_INPUT, TAG_OPTION, TAG_BUTTON, TAG_TEXTAREA, TAG_LABEL
}

func isClickable(styledNode: StyledNode): bool =
  if styledNode.t != STYLED_ELEMENT or styledNode.node == nil:
    return false
  if styledNode.computed{"visibility"} != VISIBILITY_VISIBLE:
    return false
  let element = Element(styledNode.node)
  if element of HTMLAnchorElement:
    return HTMLAnchorElement(element).href != ""
  return element.tagType in ClickableElements

func getClickable(styledNode: StyledNode): Element =
  var styledNode = styledNode
  while styledNode != nil:
    if styledNode.isClickable():
      return Element(styledNode.node)
    styledNode = styledNode.parent

proc submitForm(form: HTMLFormElement, submitter: Element): Option[Request]

func canSubmitOnClick(fae: FormAssociatedElement): bool =
  if fae.form == nil:
    return false
  if fae.form.canSubmitImplicitly():
    return true
  if fae of HTMLButtonElement and HTMLButtonElement(fae).ctype == BUTTON_SUBMIT:
    return true
  if fae of HTMLInputElement and
      HTMLInputElement(fae).inputType in {INPUT_SUBMIT, INPUT_BUTTON}:
    return true
  return false

proc getClickHover(styledNode: StyledNode): string =
  let clickable = styledNode.getClickable()
  if clickable != nil:
    if clickable of HTMLAnchorElement:
      return HTMLAnchorElement(clickable).href
    elif clickable of FormAssociatedElement:
      #TODO this is inefficient and also quite stupid
      let fae = FormAssociatedElement(clickable)
      if fae.canSubmitOnClick():
        let req = fae.form.submitForm(fae)
        if req.isSome:
          return $req.get.url
      return "<" & $clickable.tagType & ">"
    elif clickable of HTMLOptionElement:
      return "<option>"
  ""

proc getImageHover(styledNode: StyledNode): string =
  var styledNode = styledNode
  while styledNode != nil:
    if styledNode.t == STYLED_ELEMENT and styledNode.node of HTMLImageElement:
      let image = HTMLImageElement(styledNode.node)
      let src = image.attr(atSrc)
      if src != "":
        let url = image.document.parseURL(src)
        if url.isSome:
          return $url.get
    styledNode = styledNode.parent
  ""

func getCursorStyledNode(buffer: Buffer, cursorx, cursory: int): StyledNode =
  let i = buffer.lines[cursory].findFormatN(cursorx) - 1
  if i >= 0:
    return buffer.lines[cursory].formats[i].node
  nil

func getCursorElement(buffer: Buffer, cursorx, cursory: int): Element =
  let styledNode = buffer.getCursorStyledNode(cursorx, cursory)
  if styledNode == nil or styledNode.node == nil:
    return nil
  if styledNode.t == STYLED_ELEMENT:
    return Element(styledNode.node)
  return styledNode.node.parentElement

func getCursorClickable(buffer: Buffer, cursorx, cursory: int): Element =
  let styledNode = buffer.getCursorStyledNode(cursorx, cursory)
  if styledNode != nil:
    return styledNode.getClickable()

func cursorBytes(buffer: Buffer, y: int, cc: int): int =
  let line = buffer.lines[y].str
  var w = 0
  var i = 0
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.twidth(w)
  return i

proc navigate(buffer: Buffer, url: URL) =
  #TODO how?
  stderr.write("navigate to " & $url & "\n")

proc findPrevLink*(buffer: Buffer, cursorx, cursory, n: int):
    tuple[x, y: int] {.proxy.} =
  if cursory >= buffer.lines.len: return (-1, -1)
  var found = 0
  let line = buffer.lines[cursory]
  var i = line.findFormatN(cursorx) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getClickable()
  dec i

  var ly = 0 #last y
  var lx = 0 #last x
  template link_beginning() =
    #go to beginning of link
    ly = y #last y
    lx = format.pos #last x

    #on the current line
    let line = buffer.lines[y]
    while i >= 0:
      let format = line.formats[i]
      let nl = format.node.getClickable()
      if nl == fl:
        lx = format.pos
      dec i

    #on previous lines
    for iy in countdown(ly - 1, 0):
      let line = buffer.lines[iy]
      i = line.formats.len - 1
      let oly = iy
      let olx = lx
      while i >= 0:
        let format = line.formats[i]
        let nl = format.node.getClickable()
        if nl == fl:
          ly = iy
          lx = format.pos
        dec i
      if iy == oly and olx == lx:
        # Assume multiline anchors are always placed on consecutive lines.
        # This is not true, but otherwise we would have to loop through
        # the entire document, which would be rather inefficient. TODO: find
        # an efficient and correct way to do this.
        break

  template found_pos(x, y: int, fl: Element) =
    inc found
    link = fl
    if found == n:
      return (x, y)

  while i >= 0:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      let y = cursory
      link_beginning
      found_pos lx, ly, fl
    dec i

  for y in countdown(cursory - 1, 0):
    let line = buffer.lines[y]
    i = line.formats.len - 1
    while i >= 0:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        link_beginning
        found_pos lx, ly, fl
      dec i
  return (-1, -1)

proc findNextLink*(buffer: Buffer, cursorx, cursory, n: int):
    tuple[x, y: int] {.proxy.} =
  if cursory >= buffer.lines.len: return (-1, -1)
  let line = buffer.lines[cursory]
  var i = line.findFormatN(cursorx) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getClickable()
  inc i

  var found = 0
  template found_pos(x, y: int, fl: Element) =
    inc found
    link = fl
    if found == n:
      return (x, y)

  while i < line.formats.len:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      found_pos format.pos, cursory, fl
    inc i

  for y in (cursory + 1)..(buffer.lines.len - 1):
    let line = buffer.lines[y]
    for i in 0 ..< line.formats.len:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        found_pos format.pos, y, fl
  return (-1, -1)

proc findPrevParagraph*(buffer: Buffer, cursory, n: int): int {.proxy.} =
  var y = cursory
  for i in 0 ..< n:
    while y >= 0 and buffer.lines[y].str.onlyWhitespace():
      dec y
    while y >= 0 and not buffer.lines[y].str.onlyWhitespace():
      dec y
  return y

proc findNextParagraph*(buffer: Buffer, cursory, n: int): int {.proxy.} =
  var y = cursory
  for i in 0 ..< n:
    while y < buffer.lines.len and buffer.lines[y].str.onlyWhitespace():
      inc y
    while y < buffer.lines.len and not buffer.lines[y].str.onlyWhitespace():
      inc y
  return y

proc findNthLink*(buffer: Buffer, i: int): tuple[x, y: int] {.proxy.} =
  if i == 0:
    return (-1, -1)
  var k = 0
  var link: Element
  for y in 0 .. buffer.lines.high:
    let line = buffer.lines[y]
    for j in 0 ..< line.formats.len:
      let format = line.formats[j]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        inc k
        if k == i:
          return (format.pos, y)
        link = fl
  return (-1, -1)

proc findRevNthLink*(buffer: Buffer, i: int): tuple[x, y: int] {.proxy.} =
  if i == 0:
    return (-1, -1)
  var k = 0
  var link: Element
  for y in countdown(buffer.lines.high, 0):
    let line = buffer.lines[y]
    for j in countdown(line.formats.high, 0):
      let format = line.formats[j]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        inc k
        if k == i:
          return (format.pos, y)
        link = fl
  return (-1, -1)

proc findPrevMatch*(buffer: Buffer, regex: Regex, cursorx, cursory: int,
    wrap: bool, n: int): BufferMatch {.proxy.} =
  if cursory >= buffer.lines.len: return
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx)
  let res = regex.exec(buffer.lines[y].str, 0, b)
  var numfound = 0
  if res.success and res.captures.len > 0:
    let cap = res.captures[^1]
    let x = buffer.lines[y].str.width(0, cap.s)
    let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
    inc numfound
    if numfound >= n:
      return BufferMatch(success: true, x: x, y: y, str: str)
  dec y
  while true:
    if y < 0:
      if wrap:
        y = buffer.lines.high
      else:
        break
    let res = regex.exec(buffer.lines[y].str)
    if res.success and res.captures.len > 0:
      let cap = res.captures[^1]
      let x = buffer.lines[y].str.width(0, cap.s)
      let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
      inc numfound
      if numfound >= n:
        return BufferMatch(success: true, x: x, y: y, str: str)
    if y == cursory:
      break
    dec y

proc findNextMatch*(buffer: Buffer, regex: Regex, cursorx, cursory: int,
    wrap: bool, n: int): BufferMatch {.proxy.} =
  if cursory >= buffer.lines.len: return
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx + 1)
  let res = regex.exec(buffer.lines[y].str, b, buffer.lines[y].str.len)
  var numfound = 0
  if res.success and res.captures.len > 0:
    let cap = res.captures[0]
    let x = buffer.lines[y].str.width(0, cap.s)
    let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
    inc numfound
    if numfound >= n:
      return BufferMatch(success: true, x: x, y: y, str: str)
  inc y
  while true:
    if y > buffer.lines.high:
      if wrap:
        y = 0
      else:
        break
    let res = regex.exec(buffer.lines[y].str)
    if res.success and res.captures.len > 0:
      let cap = res.captures[0]
      let x = buffer.lines[y].str.width(0, cap.s)
      let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
      inc numfound
      if numfound >= n:
        return BufferMatch(success: true, x: x, y: y, str: str)
    if y == cursory:
      break
    inc y

proc gotoAnchor*(buffer: Buffer): Opt[tuple[x, y: int]] {.proxy.} =
  if buffer.document == nil:
    return err()
  let anchor = buffer.document.findAnchor(buffer.url.anchor)
  if anchor == nil:
    return err()
  for y in 0 ..< buffer.lines.len:
    let line = buffer.lines[y]
    for i in 0 ..< line.formats.len:
      let format = line.formats[i]
      if format.node != nil and format.node.node in anchor:
        return ok((format.pos, y))
  return err()

proc do_reshape(buffer: Buffer) =
  if buffer.document == nil:
    return # not parsed yet, nothing to render
  let uastyle = if buffer.document.mode != QUIRKS:
    buffer.uastyle
  else:
    buffer.quirkstyle
  if buffer.document.cachedSheetsInvalid:
    buffer.prevStyled = nil
  let styledRoot = buffer.document.applyStylesheets(uastyle,
    buffer.userstyle, buffer.prevStyled)
  buffer.lines.renderDocument(buffer.bgcolor, styledRoot, addr buffer.attrs)
  buffer.prevStyled = styledRoot

proc processData0(buffer: Buffer, data: openArray[char]): bool =
  if buffer.ishtml:
    if buffer.htmlParser.parseBuffer(data) == PRES_STOP:
      buffer.charsetStack = @[buffer.htmlParser.builder.charset]
      return false
  else:
    var plaintext = buffer.document.findFirst(TAG_PLAINTEXT)
    if plaintext == nil:
      const s = "<plaintext>"
      doAssert buffer.htmlParser.parseBuffer(s) != PRES_STOP
      plaintext = buffer.document.findFirst(TAG_PLAINTEXT)
    if data.len > 0:
      let lastChild = plaintext.lastChild
      var text = newString(data.len)
      copyMem(addr text[0], unsafeAddr data[0], data.len)
      if lastChild != nil and lastChild of Text:
        Text(lastChild).data &= text
      else:
        plaintext.insert(buffer.document.createTextNode(text), nil)
      plaintext.invalid = true
  true

func canSwitch(buffer: Buffer): bool {.inline.} =
  return buffer.htmlParser.builder.confidence == ccTentative and
    buffer.charsetStack.len > 0

proc initDecoder(buffer: Buffer) =
  if buffer.charset != CHARSET_UTF_8:
    buffer.decoder = newTextDecoder(buffer.charset)
  else:
    buffer.validator = (ref TextValidatorUTF8)()

proc switchCharset(buffer: Buffer) =
  buffer.charset = buffer.charsetStack.pop()
  buffer.initDecoder()
  buffer.htmlParser.restart(buffer.charset)
  buffer.document = buffer.htmlParser.builder.document
  buffer.prevStyled = nil

const BufferSize = 16384

proc decodeData(buffer: Buffer, iq: openArray[uint8]): bool =
  var oq {.noinit.}: array[BufferSize, char]
  var n = 0
  while true:
    case buffer.decoder.decode(iq, oq.toOpenArrayByte(0, oq.high), n)
    of tdrDone:
      if not buffer.processData0(oq.toOpenArray(0, n - 1)):
        buffer.switchCharset()
        return false
      break
    of tdrReqOutput:
      # flush output buffer
      if not buffer.processData0(oq.toOpenArray(0, n - 1)):
        buffer.switchCharset()
        return false
      n = 0
    of tdrError:
      if buffer.canSwitch:
        buffer.switchCharset()
        return false
      doAssert buffer.processData0("\uFFFD")
  true

proc validateData(buffer: Buffer, iq: openArray[char]): bool =
  var pi = 0
  var n = 0
  while true:
    case buffer.validator[].validate(iq.toOpenArrayByte(0, iq.high), n)
    of tvrDone:
      if n == -1:
        return true
      if buffer.validateBuf.len > 0:
        doAssert buffer.processData0(buffer.validateBuf)
        buffer.validateBuf.setLen(0)
      if not buffer.processData0(iq.toOpenArray(pi, n)):
        buffer.switchCharset()
        return false
      buffer.validateBuf.add(iq.toOpenArray(n + 1, iq.high))
      break
    of tvrError:
      buffer.validateBuf.setLen(0)
      if buffer.canSwitch:
        buffer.switchCharset()
        return false
      if n > pi:
        doAssert buffer.processData0(iq.toOpenArray(pi, n - 1))
      doAssert buffer.processData0("\uFFFD")
      pi = buffer.validator.i
  true

proc bomSniff(buffer: Buffer, iq: openArray[char]): int =
  if iq[0] == '\xFE' and iq[1] == '\xFF':
    buffer.charsetStack = @[CHARSET_UTF_16_BE]
    buffer.switchCharset()
    return 2
  if iq[0] == '\xFF' and iq[1] == '\xFE':
    buffer.charsetStack = @[CHARSET_UTF_16_LE]
    buffer.switchCharset()
    return 2
  if iq[0] == '\xEF' and iq[1] == '\xBB' and iq[2] == '\xBF':
    buffer.charsetStack = @[CHARSET_UTF_8]
    buffer.switchCharset()
    return 3
  return 0

proc processData(buffer: Buffer, iq: openArray[char]): bool =
  var start = 0
  if buffer.needsBOMSniff:
    if iq.len >= 3: # ehm... TODO
      start += buffer.bomSniff(iq)
    buffer.needsBOMSniff = false
  if buffer.decoder != nil:
    return buffer.decodeData(iq.toOpenArrayByte(start, iq.high))
  return buffer.validateData(iq.toOpenArray(start, iq.high))

proc windowChange*(buffer: Buffer, attrs: WindowAttributes) {.proxy.} =
  buffer.attrs = attrs
  buffer.prevStyled = nil
  if buffer.window != nil:
    buffer.window.attrs = attrs
  buffer.do_reshape()

type UpdateHoverResult* = object
  hover*: seq[tuple[t: HoverType, s: string]]
  repaint*: bool

const HoverFun = [
  htTitle: getTitleAttr,
  htLink: getClickHover,
  htImage: getImageHover
]
proc updateHover*(buffer: Buffer, cursorx, cursory: int): UpdateHoverResult
    {.proxy.} =
  if cursory >= buffer.lines.len:
    return UpdateHoverResult()
  var thisnode: StyledNode
  let i = buffer.lines[cursory].findFormatN(cursorx) - 1
  if i >= 0:
    thisnode = buffer.lines[cursory].formats[i].node
  var hover: seq[tuple[t: HoverType, s: string]] = @[]
  var repaint = false
  let prevnode = buffer.prevnode
  if thisnode != prevnode and (thisnode == nil or prevnode == nil or
      thisnode.node != prevnode.node):
    for styledNode in thisnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if not elem.hover:
          elem.hover = true
          repaint = true
    for ht in HoverType:
      let s = HoverFun[ht](thisnode)
      if buffer.hoverText[ht] != s:
        hover.add((ht, s))
        buffer.hoverText[ht] = s
    for styledNode in prevnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if elem.hover:
          elem.hover = false
          repaint = true
  if repaint:
    buffer.do_reshape()
  buffer.prevnode = thisnode
  return UpdateHoverResult(repaint: repaint, hover: hover)

proc loadResources(buffer: Buffer): EmptyPromise =
  return buffer.window.loadingResourcePromises.all()

type ConnectResult* = object
  invalid*: bool
  code*: int
  errorMessage*: string # if empty, use getLoaderErrorMessage
  needsAuth*: bool
  redirect*: Request
  contentType*: string
  cookies*: seq[Cookie]
  referrerPolicy*: Option[ReferrerPolicy]
  charset*: Charset

proc rewind(buffer: Buffer): bool =
  let request = newRequest(buffer.request.url, fromcache = true)
  let response = buffer.loader.doRequest(request)
  if response.body == nil:
    return false
  buffer.selector.unregister(buffer.fd)
  buffer.loader.unregistered.add(buffer.fd)
  buffer.istream.close()
  buffer.istream = response.body
  buffer.fd = response.body.fd
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)
  return true

proc setHTML(buffer: Buffer, ishtml: bool) =
  buffer.ishtml = ishtml
  buffer.initDecoder()
  let factory = newCAtomFactory()
  buffer.factory = factory
  let navigate = if buffer.config.scripting:
    proc(url: URL) = buffer.navigate(url)
  else:
    nil
  buffer.window = newWindow(
    buffer.config.scripting,
    buffer.config.images,
    buffer.selector,
    buffer.attrs,
    factory,
    navigate,
    some(buffer.loader)
  )
  let confidence = if buffer.config.charsetOverride == CHARSET_UNKNOWN:
    ccTentative
  else:
    ccCertain
  buffer.htmlParser = newHTML5ParserWrapper(
    buffer.window,
    buffer.url,
    buffer.factory,
    confidence,
    buffer.charset
  )
  assert buffer.htmlParser.builder.document != nil
  const css = staticRead"res/ua.css"
  const quirk = css & staticRead"res/quirk.css"
  buffer.uastyle = css.parseStylesheet(factory)
  buffer.quirkstyle = quirk.parseStylesheet(factory)
  buffer.userstyle = parseStylesheet(buffer.config.userstyle, factory)
  buffer.document = buffer.htmlParser.builder.document

proc extractCookies(response: Response): seq[Cookie] =
  result = @[]
  if "Set-Cookie" in response.headers.table:
    for s in response.headers.table["Set-Cookie"]:
      let cookie = newCookie(s, response.url)
      if cookie.isOk:
        result.add(cookie.get)

proc extractReferrerPolicy(response: Response): Option[ReferrerPolicy] =
  if "Referrer-Policy" in response.headers:
    return getReferrerPolicy(response.headers["Referrer-Policy"])
  return none(ReferrerPolicy)

proc connect*(buffer: Buffer): ConnectResult {.proxy.} =
  if buffer.state > bsConnecting:
    return ConnectResult(invalid: true)
  buffer.state = bsLoadingPage
  buffer.request.canredir = true #TODO set somewhere else?
  let response = buffer.loader.doRequest(buffer.request)
  if response.body == nil:
    return ConnectResult(
      code: response.res,
      errorMessage: response.internalMessage
    )
  buffer.istream = response.body
  buffer.fd = response.body.fd
  let cookies = response.extractCookies()
  let referrerPolicy = response.extractReferrerPolicy()
  if referrerPolicy.isSome:
    buffer.loader.setReferrerPolicy(referrerPolicy.get)
  # setup charsets:
  # * override charset
  # * network charset
  # * default charset guesses
  # HTML may override the last two (but not the override charset).
  if buffer.config.charsetOverride != CHARSET_UNKNOWN:
    buffer.charsetStack = @[buffer.config.charsetOverride]
  elif response.charset != CHARSET_UNKNOWN:
    buffer.charsetStack = @[response.charset]
  else:
    for i in countdown(buffer.config.charsets.high, 0):
      buffer.charsetStack.add(buffer.config.charsets[i])
    if buffer.charsetStack.len == 0:
      buffer.charsetStack.add(DefaultCharset)
  buffer.charset = buffer.charsetStack.pop()
  return ConnectResult(
    charset: buffer.charset,
    needsAuth: response.status == 401, # Unauthorized
    redirect: response.redirect,
    cookies: cookies,
    contentType: response.contentType,
    referrerPolicy: referrerPolicy
  )

# After connect, pager will call one of the following:
# * connect2, telling loader to load at last (we block loader until then)
# * redirectToFd, telling loader to load into the passed fd
proc connect2*(buffer: Buffer, ishtml: bool) {.proxy.} =
  if buffer.request.canredir:
    # Notify loader that we can proceed with loading the input stream.
    buffer.istream.swrite(false)
    buffer.istream.swrite(true)
  buffer.setHTML(ishtml)
  buffer.istream.setBlocking(false)
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)

proc redirectToFd*(buffer: Buffer, fd: FileHandle, wait, cache: bool)
    {.proxy.} =
  buffer.istream.swrite(true)
  buffer.istream.swrite(cache)
  buffer.istream.sendFileHandle(fd)
  if wait:
    #TODO this is kind of dumb
    # Basically, after redirect the network process keeps the socket open,
    # and writes a boolean after transfer has been finished. This way,
    # we can block this promise so it only returns after e.g. the whole
    # file has been saved.
    var dummy: bool
    buffer.istream.sread(dummy)
  discard close(fd)
  buffer.istream.close()

proc readFromFd*(buffer: Buffer, url: URL, ishtml: bool) {.proxy.} =
  let request = newRequest(url, canredir = true)
  buffer.request = request
  buffer.setHTML(ishtml)
  let response = buffer.loader.doRequest(request)
  buffer.istream = response.body
  buffer.istream.swrite(false) # no redir
  buffer.istream.swrite(true) # cache on
  buffer.istream.setBlocking(false)
  buffer.tmpCacheFlag = true
  buffer.fd = response.body.fd
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)

# As defined in std/selectors: this determines whether kqueue is being used.
# On these platforms, we must not close the selector after fork, since kqueue
# fds are not inherited after a fork.
const bsdPlatform = defined(macosx) or defined(freebsd) or defined(netbsd) or
  defined(openbsd) or defined(dragonfly)

# Create an exact clone of the current buffer.
# This clone will share the loader process with the previous buffer.
proc clone*(buffer: Buffer, newurl: URL): Pid {.proxy.} =
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    buffer.estream.write("Failed to open pipe.\n")
    return -1
  # We have to solve the problem of splitting up open input streams here.
  # To "split up" all open streams, we request a new handle to all open streams
  # (possibly including buffer.istream) from the FileLoader process.
  let needsPipe = not buffer.istream.atEnd
  var fds: seq[int]
  for fd in buffer.loader.connecting.keys:
    fds.add(fd)
  for fd in buffer.loader.ongoing.keys:
    fds.add(fd)
  #TODO maybe we still have some data in sockets... we should probably split
  # this up to be executed after the main loop is finished...
  buffer.loader.suspend(fds)
  if needsPipe:
    buffer.loader.suspend(@[buffer.fd])
  buffer.loader.addref()
  let pid = fork()
  if pid == -1:
    buffer.estream.write("Failed to clone buffer.\n")
    return -1
  if pid == 0: # child
    discard close(pipefd[0]) # close read
    let ps = newPosixStream(pipefd[1])
    # We must allocate a new selector for this new process. (Otherwise we
    # would interfere with operation of the other one.)
    # Closing seems to suffice here.
    when not bsdPlatform:
      buffer.selector.close()
    buffer.selector = newSelector[int]()
    let parentPid = buffer.loader.clientPid
    # We have a new process ID.
    buffer.loader.clientPid = getCurrentProcessId()
    #TODO set buffer.window.timeouts.selector
    var cfds: seq[int]
    for fd in buffer.loader.connecting.keys:
      cfds.add(fd)
    for fd in cfds:
      let stream = buffer.loader.tee((parentPid, fd))
      var success: bool
      stream.sread(success)
      if success:
        switchStream(buffer.loader.connecting[fd], stream)
        buffer.loader.connecting[stream.fd] = buffer.loader.connecting[fd]
      else:
        # Unlikely, but theoretically possible: our SUSPEND connection
        # finished before the connection could have been completed.
        #TODO for now, we get an fd even if the connection has already been
        # finished. there should be a better way to do this.
        buffer.loader.reconnect(buffer.loader.connecting[fd])
      buffer.loader.connecting.del(fd)
    var ofds: seq[int]
    for fd in buffer.loader.ongoing.keys:
      ofds.add(fd)
    for fd in ofds:
      let stream = buffer.loader.tee((parentPid, fd))
      var success: bool
      stream.sread(success)
      if success:
        buffer.loader.switchStream(buffer.loader.ongoing[fd], stream)
        buffer.loader.ongoing[stream.fd] = buffer.loader.ongoing[fd]
      else:
        # Already finished.
        #TODO what to do?
        discard
    if needsPipe:
      let ofd = int(buffer.istream.fd)
      buffer.istream = buffer.loader.tee((parentPid, ofd))
      buffer.fd = buffer.istream.fd
      buffer.selector.registerHandle(buffer.fd, {Read}, 0)
    buffer.pstream.close()
    let ssock = initServerSocket(buffered = false)
    buffer.ssock = ssock
    ps.write(char(0))
    buffer.url = newurl
    for it in buffer.tasks.mitems:
      it = 0
    let socks = ssock.acceptSocketStream()
    buffer.pstream = socks
    buffer.rfd = socks.fd
    buffer.selector.registerHandle(buffer.rfd, {Read}, 0)
    return 0
  else: # parent
    discard close(pipefd[1]) # close write
    # We must wait for child to tee its ongoing streams.
    let ps = newPosixStream(pipefd[0])
    let c = ps.readChar()
    assert c == char(0)
    ps.close()
    buffer.loader.resume(fds)
    return pid

proc dispatchDOMContentLoadedEvent(buffer: Buffer) =
  let window = buffer.window
  if window == nil or not buffer.config.scripting:
    return
  let ctx = window.jsctx
  let document = buffer.document
  let event = newEvent(ctx, "DOMContentLoaded", document)
  var called = false
  for el in document.eventListeners:
    if el.ctype == "DOMContentLoaded":
      let e = el.callback(event)
      if e.isErr:
        ctx.writeException(buffer.estream)
      called = true
  if called:
    buffer.do_reshape()

proc dispatchLoadEvent(buffer: Buffer) =
  let window = buffer.window
  if window == nil or not buffer.config.scripting:
    return
  let ctx = window.jsctx
  let event = newEvent(ctx, "load", window)
  var called = false
  for el in window.eventListeners:
    if el.ctype == "load":
      let e = el.callback(event)
      if e.isErr:
        ctx.writeException(buffer.estream)
      called = true
  let jsWindow = toJS(ctx, window)
  let jsonload = JS_GetPropertyStr(ctx, jsWindow, "onload")
  var jsEvent = toJS(ctx, event)
  if JS_IsFunction(ctx, jsonload):
    JS_FreeValue(ctx, JS_Call(ctx, jsonload, jsWindow, 1, addr jsEvent))
    called = true
  JS_FreeValue(ctx, jsEvent)
  JS_FreeValue(ctx, jsonload)
  JS_FreeValue(ctx, jsWindow)
  if called:
    buffer.do_reshape()

proc dispatchEvent(buffer: Buffer, ctype: string, elem: Element): tuple[
      called: bool,
      canceled: bool
    ] =
  var called = false
  var canceled = false
  let ctx = buffer.window.jsctx
  let event = newEvent(ctx, ctype, elem)
  for a in elem.branch:
    event.currentTarget = a
    var stop = false
    for el in a.eventListeners:
      if el.ctype == ctype:
        let e = el.callback(event)
        called = true
        if e.isErr:
          ctx.writeException(buffer.estream)
        if FLAG_STOP_IMMEDIATE_PROPAGATION in event.flags:
          stop = true
          break
        if FLAG_STOP_PROPAGATION in event.flags:
          stop = true
        if FLAG_CANCELED in event.flags:
          canceled = true
    if stop:
      break
  return (called, canceled)

proc finishLoad(buffer: Buffer): EmptyPromise =
  if buffer.state != bsLoadingPage:
    let p = EmptyPromise()
    p.resolve()
    return p
  buffer.state = bsLoadingResources
  if buffer.decoder != nil and buffer.decoder.finish() == tdfrError or
      buffer.validator != nil and buffer.validator[].finish() == tvrError:
    doAssert buffer.processData0("\uFFFD")
  buffer.htmlParser.finish()
  buffer.document.readyState = rsInteractive
  buffer.dispatchDOMContentLoadedEvent()
  buffer.selector.unregister(buffer.fd)
  buffer.loader.unregistered.add(buffer.fd)
  buffer.fd = -1
  buffer.istream.close()
  if buffer.tmpCacheFlag:
    buffer.loader.removeCachedURL($buffer.request.url)
  return buffer.loadResources()

# Returns:
# * -1 if loading is done
# * a positive number for reporting the number of bytes loaded and that the page
#   has been partially rendered.
proc load*(buffer: Buffer): int {.proxy, task.} =
  if buffer.state == bsLoaded:
    return -1
  elif buffer.bytesRead > buffer.reportedBytesRead:
    buffer.do_reshape()
    buffer.reportedBytesRead = buffer.bytesRead
    return buffer.bytesRead
  else:
    # will be resolved in onload
    buffer.savetask = true
    return -2 # unused

proc resolveTask[T](buffer: Buffer, cmd: BufferCommand, res: T) =
  let packetid = buffer.tasks[cmd]
  if packetid == 0:
    return # no task to resolve (TODO this is kind of inefficient)
  let len = slen(buffer.tasks[cmd]) + slen(res)
  buffer.pstream.swrite(len)
  buffer.pstream.swrite(packetid)
  buffer.tasks[cmd] = 0
  buffer.pstream.swrite(res)
  buffer.pstream.flush()

proc onload(buffer: Buffer) =
  case buffer.state
  of bsConnecting:
    assert false
  of bsLoadingResources, bsLoaded:
    buffer.resolveTask(bcLoad, -1)
    return
  of bsLoadingPage:
    discard
  var reprocess = false
  var iq {.noinit.}: array[BufferSize, char]
  var n = 0
  while true:
    try:
      if not reprocess:
        n = buffer.istream.recvData(addr iq[0], iq.len)
        buffer.bytesRead += n
      if n != 0:
        if not buffer.processData(iq.toOpenArray(0, n - 1)):
          if not buffer.firstBufferRead:
            reprocess = true
            continue
          if buffer.rewind():
            continue
        buffer.firstBufferRead = true
        reprocess = false
      else: # EOF
        buffer.finishLoad().then(proc() =
          buffer.do_reshape()
          buffer.state = bsLoaded
          buffer.document.readyState = rsComplete
          buffer.dispatchLoadEvent()
          buffer.resolveTask(bcLoad, -1)
        )
        return # skip incr render
    except ErrorAgain:
      break
  # incremental rendering: only if we cannot read the entire stream in one
  # pass
  if not buffer.config.isdump and buffer.tasks[bcLoad] != 0:
    # only makes sense when not in dump mode (and the user has requested a load)
    buffer.do_reshape()
    buffer.reportedBytesRead = buffer.bytesRead
    buffer.resolveTask(bcLoad, buffer.bytesRead)

proc getTitle*(buffer: Buffer): string {.proxy.} =
  if buffer.document != nil:
    return buffer.document.title

proc forceRender*(buffer: Buffer) {.proxy.} =
  buffer.prevStyled = nil
  buffer.do_reshape()

proc cancel*(buffer: Buffer): int {.proxy.} =
  if buffer.state == bsLoaded:
    return
  buffer.state = bsLoaded
  for fd, data in buffer.loader.connecting:
    buffer.selector.unregister(fd)
    buffer.loader.unregistered.add(fd)
    data.stream.close()
  buffer.loader.connecting.clear()
  for fd, data in buffer.loader.ongoing:
    data.response.unregisterFun()
  buffer.loader.ongoing.clear()
  buffer.selector.unregister(buffer.fd)
  buffer.loader.unregistered.add(buffer.fd)
  buffer.fd = -1
  buffer.istream.close()
  buffer.htmlParser.finish()
  buffer.document.readyState = rsInteractive
  buffer.state = bsLoaded
  buffer.do_reshape()
  return buffer.lines.len

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc serializeMultipartFormData(entries: seq[FormDataEntry]): FormData =
  let formData = newFormData0()
  for entry in entries:
    let name = makeCRLF(entry.name)
    if entry.isstr:
      let value = makeCRLF(entry.svalue)
      formData.append(name, value)
    else:
      formData.append(name, entry.value, opt(entry.filename))
  return formData

proc serializePlainTextFormData(kvs: seq[(string, string)]): string =
  for it in kvs:
    let (name, value) = it
    result &= name
    result &= '='
    result &= value
    result &= "\r\n"

func getOutputEncoding(charset: Charset): Charset =
  if charset in {CHARSET_REPLACEMENT, CHARSET_UTF_16_BE, CHARSET_UTF_16_LE}:
    return CHARSET_UTF_8
  return charset

func pickCharset(form: HTMLFormElement): Charset =
  if form.attrb(atAcceptCharset):
    let input = form.attr(atAcceptCharset)
    for label in input.split(AsciiWhitespace):
      let charset = label.getCharset()
      if charset != CHARSET_UNKNOWN:
        return charset.getOutputEncoding()
    return CHARSET_UTF_8
  return form.document.charset.getOutputEncoding()

# https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-algorithm
proc submitForm(form: HTMLFormElement, submitter: Element): Option[Request] =
  if form.constructingEntryList:
    return none(Request)
  #TODO submit()
  let charset = form.pickCharset()
  discard charset #TODO pass to constructEntryList
  let entrylist = form.constructEntryList(submitter)

  let subAction = submitter.action()
  let action = if subAction != "":
    subAction
  else:
    $form.document.url

  #TODO encoding-parse
  let url = submitter.document.parseURL(action)
  if url.isNone:
    return none(Request)

  var parsedaction = url.get
  let scheme = parsedaction.scheme
  let enctype = submitter.enctype()
  let formmethod = submitter.formmethod()
  if formmethod == FORM_METHOD_DIALOG:
    #TODO
    return none(Request)
  let httpmethod = if formmethod == FORM_METHOD_GET:
    HTTP_GET
  else:
    assert formmethod == FORM_METHOD_POST
    HTTP_POST

  #let target = if submitter.isSubmitButton() and submitter.attrb("formtarget"):
  #  submitter.attr("formtarget")
  #else:
  #  submitter.target()
  #let noopener = true #TODO

  template mutateActionUrl() =
    let kvlist = entrylist.toNameValuePairs()
    #TODO with charset
    let query = serializeApplicationXWWWFormUrlEncoded(kvlist)
    parsedaction.query = some(query)
    return some(newRequest(parsedaction, httpmethod))

  template submitAsEntityBody() =
    var mimetype: string
    var body: Opt[string]
    var multipart: Opt[FormData]
    case enctype
    of FORM_ENCODING_TYPE_URLENCODED:
      #TODO with charset
      let kvlist = entrylist.toNameValuePairs()
      body.ok(serializeApplicationXWWWFormUrlEncoded(kvlist))
      mimeType = $enctype
    of FORM_ENCODING_TYPE_MULTIPART:
      #TODO with charset
      multipart.ok(serializeMultipartFormData(entrylist))
      mimetype = $enctype
    of FORM_ENCODING_TYPE_TEXT_PLAIN:
      #TODO with charset
      let kvlist = entrylist.toNameValuePairs()
      body.ok(serializePlainTextFormData(kvlist))
      mimetype = $enctype
    let req = newRequest(parsedaction, httpmethod, @{"Content-Type": mimetype},
      body, multipart)
    return some(req) #TODO multipart

  template getActionUrl() =
    return some(newRequest(parsedaction))

  template mailWithHeaders() =
    let kvlist = entrylist.toNameValuePairs()
    #TODO with charset
    let headers = serializeApplicationXWWWFormUrlEncoded(kvlist,
      spaceAsPlus = false)
    parsedaction.query = some(headers)
    return some(newRequest(parsedaction, httpmethod))

  template mailAsBody() =
    let kvlist = entrylist.toNameValuePairs()
    let body = if enctype == FORM_ENCODING_TYPE_TEXT_PLAIN:
      let text = serializePlainTextFormData(kvlist)
      percentEncode(text, PathPercentEncodeSet)
    else:
      #TODO with charset
      serializeApplicationXWWWFormUrlEncoded(kvlist)
    if parsedaction.query.isNone:
      parsedaction.query = some("")
    if parsedaction.query.get != "":
      parsedaction.query.get &= '&'
    parsedaction.query.get &= "body=" & body
    return some(newRequest(parsedaction, httpmethod))

  case scheme
  of "ftp", "javascript":
    getActionUrl
  of "data":
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      getActionUrl
  of "mailto":
    if formmethod == FORM_METHOD_GET:
      mailWithHeaders
    else:
      assert formmethod == FORM_METHOD_POST
      mailAsBody
  else:
    # Note: only http & https are defined by the standard.
    # Assume an HTTP-like protocol.
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      submitAsEntityBody

proc setFocus(buffer: Buffer, e: Element): bool =
  if buffer.document.focus != e:
    buffer.document.focus = e
    buffer.do_reshape()
    return true

proc restoreFocus(buffer: Buffer): bool =
  if buffer.document.focus != nil:
    buffer.document.focus = nil
    buffer.do_reshape()
    return true

type ReadSuccessResult* = object
  open*: Option[Request]
  repaint*: bool

proc implicitSubmit(input: HTMLInputElement): Option[Request] =
  let form = input.form
  if form != nil and form.canSubmitImplicitly():
    var defaultButton: Element
    for element in form.elements:
      if element.isSubmitButton():
        defaultButton = element
        break
    if defaultButton != nil:
      return submitForm(form, defaultButton)
    else:
      return submitForm(form, form)

proc readSuccess*(buffer: Buffer, s: string): ReadSuccessResult {.proxy.} =
  if buffer.document.focus != nil:
    case buffer.document.focus.tagType
    of TAG_INPUT:
      let input = HTMLInputElement(buffer.document.focus)
      case input.inputType
      of INPUT_SEARCH, INPUT_TEXT, INPUT_PASSWORD:
        input.value = s
        input.invalid = true
        buffer.do_reshape()
        result.repaint = true
        result.open = implicitSubmit(input)
      of INPUT_FILE:
        let cdir = parseURL("file://" & getCurrentDir() & DirSep)
        let path = parseURL(s, cdir)
        if path.isSome:
          input.file = path
          input.invalid = true
          buffer.do_reshape()
          result.repaint = true
          result.open = implicitSubmit(input)
      else: discard
    of TAG_TEXTAREA:
      let textarea = HTMLTextAreaElement(buffer.document.focus)
      textarea.value = s
      textarea.invalid = true
      buffer.do_reshape()
      result.repaint = true
    else: discard
    let r = buffer.restoreFocus()
    if not result.repaint:
      result.repaint = r

type ReadLineResult* = object
  prompt*: string
  value*: string
  hide*: bool
  area*: bool

type
  SelectResult* = object
    multiple*: bool
    options*: seq[string]
    selected*: seq[int]

  ClickResult* = object
    open*: Option[Request]
    readline*: Option[ReadLineResult]
    repaint*: bool
    select*: Option[SelectResult]

proc click(buffer: Buffer, clickable: Element): ClickResult

proc click(buffer: Buffer, label: HTMLLabelElement): ClickResult =
  let control = label.control
  if control != nil:
    return buffer.click(control)

proc click(buffer: Buffer, select: HTMLSelectElement): ClickResult =
  let repaint = buffer.setFocus(select)
  var options: seq[string]
  var selected: seq[int]
  var i = 0
  for option in select.options:
    options.add(option.textContent.stripAndCollapse())
    if option.selected:
      selected.add(i)
    inc i
  let select = SelectResult(
    multiple: select.attrb(atMultiple),
    options: options,
    selected: selected
  )
  return ClickResult(
    repaint: repaint,
    select: some(select)
  )

func baseURL(buffer: Buffer): URL =
  return buffer.document.baseURL

proc evalJSURL(buffer: Buffer, url: URL): Opt[string] =
  let encodedScriptSource = ($url)["javascript:".len..^1]
  let scriptSource = percentDecode(encodedScriptSource)
  let ctx = buffer.window.jsctx
  let ret = ctx.eval(scriptSource, $buffer.baseURL, JS_EVAL_TYPE_GLOBAL)
  if JS_IsException(ret):
    ctx.writeException(buffer.estream)
    return err() # error
  if JS_IsUndefined(ret):
    return err() # no need to navigate
  let s = ?fromJS[string](ctx, ret)
  JS_FreeValue(ctx, ret)
  # Navigate to result.
  return ok(s)

proc click(buffer: Buffer, anchor: HTMLAnchorElement): ClickResult =
  var repaint = buffer.restoreFocus()
  let url = parseURL(anchor.href, some(buffer.baseURL))
  if url.isSome:
    let url = url.get
    if url.scheme == "javascript":
      if buffer.config.scripting:
        let s = buffer.evalJSURL(url)
        buffer.do_reshape()
        repaint = true
        if s.isSome:
          let url = newURL("data:text/html," & s.get).get
          let req = newRequest(url, HTTP_GET)
          return ClickResult(
            repaint: repaint,
            open: some(req)
          )
      return ClickResult(
        repaint: repaint
      )
    return ClickResult(
      repaint: repaint,
      open: some(newRequest(url, HTTP_GET))
    )
  return ClickResult(
    repaint: repaint
  )

proc click(buffer: Buffer, option: HTMLOptionElement): ClickResult =
  let select = option.select
  if select != nil:
    return buffer.click(select)

proc click(buffer: Buffer, button: HTMLButtonElement): ClickResult =
  if button.form != nil:
    case button.ctype
    of BUTTON_SUBMIT: result.open = submitForm(button.form, button)
    of BUTTON_RESET:
      button.form.reset()
      buffer.do_reshape()
      return ClickResult(repaint: true)
    of BUTTON_BUTTON: discard
    result.repaint = buffer.setFocus(button)

proc click(buffer: Buffer, textarea: HTMLTextAreaElement): ClickResult =
  let repaint = buffer.setFocus(textarea)
  let readline = ReadLineResult(
    value: textarea.value,
    area: true,
  )
  return ClickResult(
    readline: some(readline),
    repaint: repaint
  )

proc click(buffer: Buffer, input: HTMLInputElement): ClickResult =
  result.repaint = buffer.restoreFocus()
  case input.inputType
  of INPUT_SEARCH:
    result.repaint = buffer.setFocus(input)
    result.readline = some(ReadLineResult(
      prompt: "SEARCH: ",
      value: input.value
    ))
  of INPUT_TEXT, INPUT_PASSWORD:
    result.repaint = buffer.setFocus(input)
    result.readline = some(ReadLineResult(
      prompt: "TEXT: ",
      value: input.value,
      hide: input.inputType == INPUT_PASSWORD
    ))
  of INPUT_FILE:
    result.repaint = buffer.setFocus(input)
    var path = if input.file.isSome:
      input.file.get.path.serialize_unicode()
    else:
      ""
    result.readline = some(ReadLineResult(
      prompt: "Filename: ",
      value: path
    ))
  of INPUT_CHECKBOX:
    input.checked = not input.checked
    input.invalid = true
    result.repaint = true
    buffer.do_reshape()
  of INPUT_RADIO:
    for radio in input.radiogroup:
      radio.checked = false
      radio.invalid = true
    input.checked = true
    input.invalid = true
    result.repaint = true
    buffer.do_reshape()
  of INPUT_RESET:
    if input.form != nil:
      input.form.reset()
      result.repaint = true
      buffer.do_reshape()
  of INPUT_SUBMIT, INPUT_BUTTON:
    if input.form != nil:
      result.open = submitForm(input.form, input)
  else:
    result.repaint = buffer.restoreFocus()

proc click(buffer: Buffer, clickable: Element): ClickResult =
  case clickable.tagType
  of TAG_LABEL:
    return buffer.click(HTMLLabelElement(clickable))
  of TAG_SELECT:
    return buffer.click(HTMLSelectElement(clickable))
  of TAG_A:
    return buffer.click(HTMLAnchorElement(clickable))
  of TAG_OPTION:
    return buffer.click(HTMLOptionElement(clickable))
  of TAG_BUTTON:
    return buffer.click(HTMLButtonElement(clickable))
  of TAG_TEXTAREA:
    return buffer.click(HTMLTextAreaElement(clickable))
  of TAG_INPUT:
    return buffer.click(HTMLInputElement(clickable))
  else:
    result.repaint = buffer.restoreFocus()

proc click*(buffer: Buffer, cursorx, cursory: int): ClickResult {.proxy.} =
  if buffer.lines.len <= cursory: return
  var called = false
  var canceled = false
  let clickable = buffer.getCursorClickable(cursorx, cursory)
  if buffer.config.scripting:
    let elem = buffer.getCursorElement(cursorx, cursory)
    (called, canceled) = buffer.dispatchEvent("click", elem)
    if called:
      buffer.do_reshape()
  if not canceled:
    if clickable != nil:
      var res = buffer.click(clickable)
      res.repaint = called
      return res
  return ClickResult(repaint: called)

proc select*(buffer: Buffer, selected: seq[int]): ClickResult {.proxy.} =
  if buffer.document.focus != nil and
      buffer.document.focus of HTMLSelectElement:
    let select = HTMLSelectElement(buffer.document.focus)
    var i = 0
    var j = 0
    var repaint = false
    for option in select.options:
      var wasSelected = option.selected
      if i < selected.len and selected[i] == j:
        option.selected = true
        inc i
      else:
        option.selected = false
      if not repaint:
        repaint = wasSelected != option.selected
      inc j
    return ClickResult(repaint: buffer.restoreFocus())

proc readCanceled*(buffer: Buffer): bool {.proxy.} =
  return buffer.restoreFocus()

proc findAnchor*(buffer: Buffer, anchor: string): bool {.proxy.} =
  return buffer.document != nil and buffer.document.findAnchor(anchor) != nil

type GetLinesResult* = tuple[
  numLines: int,
  lines: seq[SimpleFlexibleLine],
  bgcolor: CellColor
]

proc getLines*(buffer: Buffer, w: Slice[int]): GetLinesResult {.proxy.} =
  var w = w
  if w.b < 0 or w.b > buffer.lines.high:
    w.b = buffer.lines.high
  #TODO this is horribly inefficient
  for y in w:
    var line = SimpleFlexibleLine(str: buffer.lines[y].str)
    for f in buffer.lines[y].formats:
      line.formats.add(SimpleFormatCell(format: f.format, pos: f.pos))
    result.lines.add(line)
  result.numLines = buffer.lines.len
  result.bgcolor = buffer.bgcolor

macro bufferDispatcher(funs: static ProxyMap, buffer: Buffer,
    cmd: BufferCommand, packetid: int) =
  let switch = newNimNode(nnkCaseStmt)
  switch.add(ident("cmd"))
  for k, v in funs:
    let ofbranch = newNimNode(nnkOfBranch)
    ofbranch.add(v.ename)
    let stmts = newStmtList()
    let call = newCall(v.iname, buffer)
    for i in 2 ..< v.params.len:
      let param = v.params[i]
      for i in 0 ..< param.len - 2:
        let id = ident(param[i].strVal)
        let typ = param[^2]
        stmts.add(quote do:
          when `typ` is FileHandle:
            let `id` = `buffer`.pstream.recvFileHandle()
          else:
            var `id`: `typ`
            `buffer`.pstream.sread(`id`))
        call.add(id)
    var rval: NimNode
    if v.params[0].kind == nnkEmpty:
      stmts.add(call)
    else:
      rval = ident("retval")
      stmts.add(quote do:
        let `rval` = `call`)
    var resolve = newStmtList()
    if rval == nil:
      resolve.add(quote do:
        let len = slen(`packetid`)
        buffer.pstream.swrite(len)
        buffer.pstream.swrite(`packetid`)
      )
    else:
      resolve.add(quote do:
        let len = slen(`packetid`) + slen(`rval`)
        buffer.pstream.swrite(len)
        buffer.pstream.swrite(`packetid`)
        buffer.pstream.swrite(`rval`)
      )
    if v.istask:
      let en = v.ename
      stmts.add(quote do:
        if buffer.savetask:
          buffer.savetask = false
          buffer.tasks[BufferCommand.`en`] = `packetid`
        else:
          `resolve`)
    else:
      stmts.add(resolve)
    ofbranch.add(stmts)
    switch.add(ofbranch)
  return switch

proc readCommand(buffer: Buffer) =
  var cmd: BufferCommand
  buffer.pstream.sread(cmd)
  var packetid: int
  buffer.pstream.sread(packetid)
  bufferDispatcher(ProxyFunctions, buffer, cmd, packetid)

proc handleRead(buffer: Buffer, fd: int): bool =
  if fd == buffer.rfd:
    try:
      buffer.readCommand()
    except ErrorConnectionReset, EOFError:
      #eprint "EOF error", $buffer.url & "\nMESSAGE:",
      #       getCurrentExceptionMsg() & "\n",
      #       getStackTrace(getCurrentException())
      return false
  elif fd == buffer.fd:
    buffer.onload()
  elif fd in buffer.loader.connecting:
    buffer.loader.onConnected(fd)
    buffer.loader.onRead(fd)
    if buffer.config.scripting:
      buffer.window.runJSJobs()
  elif fd in buffer.loader.ongoing:
    buffer.loader.onRead(fd)
    if buffer.config.scripting:
      buffer.window.runJSJobs()
  elif fd in buffer.loader.unregistered:
    discard # ignore
  else: assert false
  true

proc handleError(buffer: Buffer, fd: int, err: OSErrorCode): bool =
  if fd == buffer.rfd:
    # Connection reset by peer, probably. Close the buffer.
    return false
  elif fd == buffer.fd:
    buffer.onload()
  elif fd in buffer.loader.connecting:
    # probably shouldn't happen. TODO
    assert false, $fd & ": " & $err
  elif fd in buffer.loader.ongoing:
    buffer.loader.onError(fd)
    if buffer.config.scripting:
      buffer.window.runJSJobs()
  elif fd in buffer.loader.unregistered:
    discard # ignore
  else:
    assert false, $fd & ": " & $err
  true

proc runBuffer(buffer: Buffer) =
  var alive = true
  while alive:
    let events = buffer.selector.select(-1)
    for event in events:
      if Read in event.events:
        if not buffer.handleRead(event.fd):
          alive = false
          break
      if Error in event.events:
        if not buffer.handleError(event.fd, event.errorCode):
          alive = false
          break
      if selectors.Event.Timer in event.events:
        assert buffer.window != nil
        let r = buffer.window.timeouts.runTimeoutFd(event.fd)
        assert r
        buffer.window.runJSJobs()
        buffer.do_reshape()
    buffer.loader.unregistered.setLen(0)

proc cleanup(buffer: Buffer) =
  buffer.pstream.close()
  buffer.ssock.close()
  buffer.loader.unref()

proc launchBuffer*(config: BufferConfig, request: Request,
    attrs: WindowAttributes, loader: FileLoader, ssock: ServerSocket) =
  let socks = ssock.acceptSocketStream()
  let buffer = Buffer(
    url: request.url,
    attrs: attrs,
    config: config,
    loader: loader,
    request: request,
    selector: newSelector[int](),
    estream: newFileStream(stderr),
    pstream: socks,
    rfd: socks.fd,
    ssock: ssock,
    needsBOMSniff: config.charsetOverride == CHARSET_UNKNOWN
  )
  var gbuffer {.global.}: Buffer
  gbuffer = buffer
  onSignal SIGTERM:
    discard sig
    gbuffer.cleanup()
    exitnow(1)
  loader.registerFun = proc(fd: int) =
    buffer.selector.registerHandle(fd, {Read}, 0)
  loader.unregisterFun = proc(fd: int) =
    buffer.selector.unregister(fd)
  buffer.selector.registerHandle(buffer.rfd, {Read}, 0)
  buffer.runBuffer()
  buffer.cleanup()
  quit(0)
