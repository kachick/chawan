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
import display/winattrs
import html/catom
import html/chadombuilder
import html/dom
import html/enums
import html/env
import html/event
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
import loader/headers
import loader/loader
import render/renderdocument
import render/rendertext
import types/buffersource
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

import chakasu/charset

import chame/tags

type
  LoadInfo* = enum
    CONNECT, DOWNLOAD, RENDER, DONE

  BufferCommand* = enum
    LOAD, RENDER, WINDOW_CHANGE, FIND_ANCHOR, READ_SUCCESS, READ_CANCELED,
    CLICK, FIND_NEXT_LINK, FIND_PREV_LINK, FIND_NTH_LINK, FIND_REV_NTH_LINK,
    FIND_NEXT_MATCH, FIND_PREV_MATCH, GET_LINES, UPDATE_HOVER, CONNECT,
    CONNECT2, GOTO_ANCHOR, CANCEL, GET_TITLE, SELECT, REDIRECT_TO_FD,
    READ_FROM_FD, SET_CONTENT_TYPE, CLONE, FIND_PREV_PARAGRAPH,
    FIND_NEXT_PARAGRAPH

  # LOADING_PAGE: istream open
  # LOADING_RESOURCES: istream closed, resources open
  # LOADED: istream closed, resources closed
  BufferState* = enum
    LOADING_PAGE, LOADING_RESOURCES, LOADED

  HoverType* = enum
    HOVER_TITLE = "TITLE"
    HOVER_LINK = "URL"

  BufferMatch* = object
    success*: bool
    x*: int
    y*: int
    str*: string

  Buffer* = ref object
    rfd: int # file descriptor of command pipe
    fd: int # file descriptor of buffer source
    alive: bool
    lines: FlexibleGrid
    rendered: bool
    source: BufferSource
    width: int
    height: int
    attrs: WindowAttributes
    window: Window
    document: Document
    prevstyled: StyledNode
    selector: Selector[int]
    istream: SocketStream
    sstream: StringStream
    available: int
    pstream: SocketStream # pipe stream
    srenderer: StreamRenderer
    connected: bool
    state: BufferState
    prevnode: StyledNode
    loader: FileLoader
    config: BufferConfig
    userstyle: CSSStylesheet
    tasks: array[BufferCommand, int] #TODO this should have arguments
    savetask: bool
    hovertext: array[HoverType, string]
    estream: Stream # error stream
    ishtml: bool
    ssock: ServerSocket
    factory: CAtomFactory
    uastyle: CSSStylesheet
    quirkstyle: CSSStylesheet
    htmlParser: HTML5ParserWrapper

  InterfaceOpaque = ref object
    stream: Stream
    len: int

  BufferInterface* = ref object
    map: PromiseMap
    packetid: int
    opaque: InterfaceOpaque
    stream*: Stream

proc getFromOpaque[T](opaque: pointer, res: var T) =
  let opaque = cast[InterfaceOpaque](opaque)
  if opaque.len != 0:
    opaque.stream.sread(res)

proc newBufferInterface*(stream: Stream): BufferInterface =
  let opaque = InterfaceOpaque(stream: stream)
  result = BufferInterface(
    map: newPromiseMap(cast[pointer](opaque)),
    packetid: 1, # ids below 1 are invalid
    opaque: opaque,
    stream: stream
  )

# After cloning a buffer, we need a new interface to the new buffer process.
# Here we create a new interface for that clone.
proc cloneInterface*(stream: Stream): BufferInterface =
  let iface = newBufferInterface(stream)
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
  result = name.strVal.toScreamingSnakeCase()
  if result[^1] == '=':
    result = "SET_" & result[0..^2]

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
    `thisval`.stream.swrite(`thisval`.packetid))
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
  for i in 2 ..< params.len:
    let param = params[i]
    for i in 0 ..< param.len - 2:
      let id2 = newIdentDefs(ident(param[i].strVal), param[^2])
      params2.add(id2)
  for i in 2 ..< params2.len:
    let s = params2[i][0] # sym e.g. url
    body.add(quote do:
      when typeof(`s`) is FileHandle:
        SocketStream(`thisval`.stream).sendFileHandle(`s`)
      else:
        `thisval`.stream.swrite(`s`))
  body.add(quote do:
    `thisval`.stream.flush())
  body.add(quote do:
    let promise = `addfun`
    inc `thisval`.packetid
    return promise)
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

func url(buffer: Buffer): URL =
  return buffer.source.request.url

func charsets(buffer: Buffer): seq[Charset] =
  if buffer.source.charset != CHARSET_UNKNOWN:
    return @[buffer.source.charset]
  return buffer.config.charsets

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
  return ""

func getCursorStyledNode(buffer: Buffer, cursorx, cursory: int): StyledNode =
  let i = buffer.lines[cursory].findFormatN(cursorx) - 1
  if i >= 0:
    return buffer.lines[cursory].formats[i].node

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
  if buffer.ishtml:
    if buffer.document == nil:
      return # not parsed yet, nothing to render
    let uastyle = if buffer.document.mode != QUIRKS:
      buffer.uastyle
    else:
      buffer.quirkstyle
    let styledRoot = buffer.document.applyStylesheets(uastyle,
      buffer.userstyle, buffer.prevstyled)
    buffer.lines = renderDocument(styledRoot, buffer.attrs)
    buffer.prevstyled = styledRoot
  else:
    buffer.lines.renderStream(buffer.srenderer)

proc processData(buffer: Buffer) =
  if buffer.ishtml:
    buffer.htmlParser.parseAll()
    buffer.document = buffer.htmlParser.builder.document
  else:
    buffer.lines.renderStream(buffer.srenderer)

proc windowChange*(buffer: Buffer, attrs: WindowAttributes) {.proxy.} =
  buffer.attrs = attrs
  buffer.width = buffer.attrs.width
  buffer.height = buffer.attrs.height - 1
  buffer.prevstyled = nil
  if buffer.window != nil:
    buffer.window.attrs = attrs

type UpdateHoverResult* = object
  link*: Option[string]
  title*: Option[string]
  repaint*: bool

proc updateHover*(buffer: Buffer, cursorx, cursory: int): UpdateHoverResult {.proxy.} =
  if cursory >= buffer.lines.len:
    return
  var thisnode: StyledNode
  let i = buffer.lines[cursory].findFormatN(cursorx) - 1
  if i >= 0:
    thisnode = buffer.lines[cursory].formats[i].node
  let prevnode = buffer.prevnode

  if thisnode != prevnode and (thisnode == nil or prevnode == nil or thisnode.node != prevnode.node):
    for styledNode in thisnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if not elem.hover:
          elem.hover = true
          result.repaint = true

    let title = thisnode.getTitleAttr()
    if buffer.hovertext[HOVER_TITLE] != title:
      result.title = some(title)
      buffer.hovertext[HOVER_TITLE] = title
    let click = thisnode.getClickHover()
    if buffer.hovertext[HOVER_LINK] != click:
      result.link = some(click)
      buffer.hovertext[HOVER_LINK] = click

    for styledNode in prevnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if elem.hover:
          elem.hover = false
          result.repaint = true
  if result.repaint:
    buffer.do_reshape()

  buffer.prevnode = thisnode

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
  referrerpolicy*: Option[ReferrerPolicy]
  charset*: Charset

proc rewind(buffer: Buffer): bool =
  if buffer.loader.rewind(buffer.fd):
    return true
  let request = newRequest(buffer.url, fromcache = true)
  let response = buffer.loader.doRequest(request)
  if response.body != nil:
    buffer.selector.unregister(buffer.fd)
    buffer.loader.unregistered.add(buffer.fd)
    buffer.istream.close()
    buffer.istream = response.body
    buffer.fd = response.body.fd
    buffer.selector.registerHandle(buffer.fd, {Read}, 0)
    return true
  return false

proc setHTML(buffer: Buffer, ishtml: bool) =
  buffer.ishtml = ishtml
  let rewindImpl = proc() =
    doAssert buffer.rewind()
  if ishtml:
    let factory = newCAtomFactory()
    buffer.factory = factory
    if buffer.config.scripting:
      buffer.window = newWindow(
        buffer.config.scripting,
        buffer.config.images,
        buffer.selector,
        buffer.attrs,
        factory,
        proc(url: URL) = buffer.navigate(url),
        some(buffer.loader)
      )
    else:
      buffer.window = newWindow(
        buffer.config.scripting,
        buffer.config.images,
        buffer.selector,
        buffer.attrs,
        factory,
        nil,
        some(buffer.loader)
      )
    buffer.htmlParser = newHTML5ParserWrapper(
      buffer.sstream,
      buffer.window,
      buffer.url,
      buffer.factory,
      rewindImpl = rewindImpl,
      buffer.charsets,
      seekable = true
    )
    const css = staticRead"res/ua.css"
    const quirk = css & staticRead"res/quirk.css"
    buffer.uastyle = css.parseStylesheet(factory)
    buffer.quirkstyle = quirk.parseStylesheet(factory)
    buffer.userstyle = parseStylesheet(buffer.config.userstyle, factory)
  else:
    buffer.srenderer = newStreamRenderer(buffer.sstream, buffer.charsets,
      rewindImpl)

proc connect*(buffer: Buffer): ConnectResult {.proxy.} =
  if buffer.connected:
    return ConnectResult(invalid: true)
  let source = buffer.source
  # Warning: source content type overrides received content types, but source
  # charset is just a fallback.
  var charset = source.charset
  var needsAuth = false
  var redirect: Request
  var cookies: seq[Cookie]
  var referrerpolicy: Option[ReferrerPolicy]
  let request = source.request
  request.canredir = true #TODO set somewhere else?
  let response = buffer.loader.doRequest(request)
  if response.body == nil:
    return ConnectResult(
      code: response.res,
      errorMessage: response.internalMessage
    )
  if response.charset != CHARSET_UNKNOWN:
    charset = charset
  if buffer.source.contentType.isNone:
    buffer.source.contentType = some(response.contentType)
  buffer.istream = response.body
  let fd = response.body.source.getFd()
  buffer.fd = int(fd)
  needsAuth = response.status == 401 # Unauthorized
  redirect = response.redirect
  if "Set-Cookie" in response.headers.table:
    for s in response.headers.table["Set-Cookie"]:
      let cookie = newCookie(s, response.url)
      if cookie.isOk:
        cookies.add(cookie.get)
  if "Referrer-Policy" in response.headers:
    referrerpolicy = getReferrerPolicy(response.headers["Referrer-Policy"])
    if referrerpolicy.isSome:
      buffer.loader.setReferrerPolicy(referrerpolicy.get)
  buffer.connected = true
  let contentType = buffer.source.contentType.get("")
  buffer.setHTML(contentType == "text/html")
  return ConnectResult(
    charset: charset,
    needsAuth: needsAuth,
    redirect: redirect,
    cookies: cookies,
    contentType: contentType
  )

# After connect, pager will call one of the following:
# * connect2, telling loader to load at last (we block loader until then)
# * redirectToFd, telling loader to load into the passed fd
proc connect2*(buffer: Buffer) {.proxy.} =
  if buffer.source.request.canredir:
    # Notify loader that we can proceed with loading the input stream.
    buffer.istream.swrite(false)
    buffer.istream.swrite(true)
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
  let contentType = if ishtml:
    "text/html"
  else:
    "text/plain"
  let request = newRequest(url)
  buffer.source = BufferSource(
    request: request,
    contentType: some(contentType),
    charset: buffer.source.charset
  )
  buffer.setHTML(ishtml)
  let response = buffer.loader.doRequest(request)
  buffer.istream = response.body
  buffer.fd = int(response.body.source.getFd())
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)

proc setContentType*(buffer: Buffer, contentType: string) {.proxy.} =
  buffer.source.contentType = some(contentType)
  buffer.setHTML(contentType == "text/html")

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
      let sfd = int(stream.source.getFd())
      if success:
        switchStream(buffer.loader.connecting[fd], stream)
        buffer.loader.connecting[sfd] = buffer.loader.connecting[fd]
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
      let sfd = int(stream.source.getFd())
      if success:
        buffer.loader.switchStream(buffer.loader.ongoing[fd], stream)
        buffer.loader.ongoing[sfd] = buffer.loader.ongoing[fd]
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
    buffer.source.request.url = newurl
    for it in buffer.tasks.mitems:
      it = 0
    let socks = ssock.acceptSocketStream()
    buffer.pstream = socks
    buffer.rfd = int(socks.source.getFd())
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

const BufferSize = 16384

proc finishLoad(buffer: Buffer): EmptyPromise =
  if buffer.state != LOADING_PAGE:
    let p = EmptyPromise()
    p.resolve()
    return p
  var p: EmptyPromise
  if buffer.ishtml:
    buffer.htmlParser.finish()
    buffer.document = buffer.htmlParser.builder.document
    buffer.document.readyState = READY_STATE_INTERACTIVE
    buffer.state = LOADING_RESOURCES
    buffer.dispatchDOMContentLoadedEvent()
    p = buffer.loadResources()
  else:
    p = EmptyPromise()
    p.resolve()
  buffer.selector.unregister(buffer.fd)
  buffer.loader.unregistered.add(buffer.fd)
  buffer.fd = -1
  buffer.istream.close()
  return p

type LoadResult* = tuple[
  atend: bool,
  lines: int,
  bytes: int
]

proc load*(buffer: Buffer): LoadResult {.proxy, task.} =
  if buffer.state == LOADED:
    return (true, buffer.lines.len, -1)
  else:
    buffer.savetask = true

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
  var res: LoadResult = (false, buffer.lines.len, -1)
  case buffer.state
  of LOADING_RESOURCES:
    assert false
  of LOADED:
    buffer.resolveTask(LOAD, res)
    return
  of LOADING_PAGE:
    discard
  while true:
    buffer.sstream.setPosition(0)
    buffer.sstream.data.setLen(BufferSize)
    try:
      buffer.sstream.data.prepareMutation()
      let n = buffer.istream.readData(addr buffer.sstream.data[0], BufferSize)
      if n != buffer.sstream.data.len:
        buffer.sstream.data.setLen(n)
      if n != 0:
        buffer.available += n
        buffer.processData()
        res.bytes = buffer.available
      res.lines = buffer.lines.len
      if buffer.istream.atEnd():
        buffer.sstream = nil
        # EOF
        res.atend = true
        buffer.finishLoad().then(proc() =
          buffer.prevstyled = nil # for incremental rendering
          buffer.do_reshape()
          res.lines = buffer.lines.len
          buffer.state = LOADED
          if buffer.document != nil: # may be nil if not buffer.ishtml
            buffer.document.readyState = READY_STATE_COMPLETE
          buffer.dispatchLoadEvent()
          buffer.resolveTask(LOAD, res)
        )
        return # skip incr render
      buffer.resolveTask(LOAD, res)
    except ErrorAgain, ErrorWouldBlock:
      break
  if buffer.document != nil:
    # incremental rendering: only if we cannot read the entire stream in one
    # pass
    #TODO this is too simplistic to be really useful
    let uastyle = if buffer.document.mode != QUIRKS:
      buffer.uastyle
    else:
      buffer.quirkstyle
    let styledRoot = buffer.document.applyStylesheets(uastyle,
      buffer.userstyle, buffer.prevstyled)
    buffer.lines = renderDocument(styledRoot, buffer.attrs)
    buffer.prevstyled = styledRoot

proc getTitle*(buffer: Buffer): string {.proxy.} =
  if buffer.document != nil:
    return buffer.document.title

proc render*(buffer: Buffer): int {.proxy.} =
  buffer.do_reshape()
  return buffer.lines.len

proc cancel*(buffer: Buffer): int {.proxy.} =
  #TODO TODO TODO cancel resource loading too
  if buffer.state != LOADING_PAGE: return
  buffer.istream.close()
  buffer.state = LOADED
  if buffer.ishtml:
    buffer.htmlParser.finish()
    buffer.document = buffer.htmlParser.builder.document
    buffer.document.readyState = READY_STATE_INTERACTIVE
    buffer.state = LOADING_RESOURCES
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

# https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-algorithm
proc submitForm(form: HTMLFormElement, submitter: Element): Option[Request] =
  if form.constructingentrylist:
    return
  let entrylist = form.constructEntryList(submitter).get(@[])

  let subAction = submitter.action()
  let action = if subAction != "":
    subAction
  else:
    $form.document.url

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
    let query = serializeApplicationXWWWFormUrlEncoded(kvlist)
    parsedaction.query = some(query)
    return some(newRequest(parsedaction, httpmethod))

  template submitAsEntityBody() =
    var mimetype: string
    var body: Opt[string]
    var multipart: Opt[FormData]
    case enctype
    of FORM_ENCODING_TYPE_URLENCODED:
      let kvlist = entrylist.toNameValuePairs()
      body.ok(serializeApplicationXWWWFormUrlEncoded(kvlist))
      mimeType = $enctype
    of FORM_ENCODING_TYPE_MULTIPART:
      multipart.ok(serializeMultipartFormData(entrylist))
      mimetype = $enctype
    of FORM_ENCODING_TYPE_TEXT_PLAIN:
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
      serializeApplicationXWWWFormUrlEncoded(kvlist)
    if parsedaction.query.isNone:
      parsedaction.query = some("")
    if parsedaction.query.get != "":
      parsedaction.query.get &= '&'
    parsedaction.query.get &= "body=" & body
    return some(newRequest(parsedaction, httpmethod))

  case scheme
  of "http", "https", "gopher", "gophers", "cgi-bin":
    # Note: only http & https are defined by the standard.
    # We implement gopher, gophers & cgi-bin as HTTP-like protocols.
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      submitAsEntityBody
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
  lines: seq[SimpleFlexibleLine]
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
        buffer.pstream.flush())
    else:
      resolve.add(quote do:
        let len = slen(`packetid`) + slen(`rval`)
        buffer.pstream.swrite(len)
        buffer.pstream.swrite(`packetid`)
        buffer.pstream.swrite(`rval`)
        buffer.pstream.flush())
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

proc handleRead(buffer: Buffer, fd: int) =
  if fd == buffer.rfd:
    try:
      buffer.readCommand()
    except ErrorConnectionReset, EOFError:
      #eprint "EOF error", $buffer.url & "\nMESSAGE:",
      #       getCurrentExceptionMsg() & "\n",
      #       getStackTrace(getCurrentException())
      buffer.alive = false
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

proc handleError(buffer: Buffer, fd: int, err: OSErrorCode) =
  if fd == buffer.rfd:
    # Connection reset by peer, probably. Close the buffer.
    buffer.alive = false
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

proc runBuffer(buffer: Buffer) =
  while buffer.alive:
    let events = buffer.selector.select(-1)
    for event in events:
      if Read in event.events:
        buffer.handleRead(event.fd)
      if Error in event.events:
        buffer.handleError(event.fd, event.errorCode)
      if not buffer.alive:
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

var gbuffer: Buffer
proc launchBuffer*(config: BufferConfig, source: BufferSource,
    attrs: WindowAttributes, loader: FileLoader, ssock: ServerSocket) =
  let socks = ssock.acceptSocketStream()
  let buffer = Buffer(
    alive: true,
    attrs: attrs,
    config: config,
    loader: loader,
    source: source,
    sstream: newStringStream(),
    width: attrs.width,
    height: attrs.height - 1,
    selector: newSelector[int](),
    estream: newFileStream(stderr),
    pstream: socks,
    rfd: int(socks.source.getFd()),
    ssock: ssock
  )
  gbuffer = buffer
  onSignal SIGTERM:
    discard sig
    gbuffer.cleanup()
  loader.registerFun = proc(fd: int) =
    buffer.selector.registerHandle(fd, {Read}, 0)
  loader.unregisterFun = proc(fd: int) =
    buffer.selector.unregister(fd)
  buffer.selector.registerHandle(buffer.rfd, {Read}, 0)
  buffer.runBuffer()
  buffer.cleanup()
  quit(0)
