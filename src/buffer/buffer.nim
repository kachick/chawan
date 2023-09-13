import macros
import nativesockets
import net
import options
import os
import posix
import selectors
import streams
import tables
import unicode

import bindings/quickjs
import buffer/cell
import config/config
import css/cascade
import css/cssparser
import css/mediaquery
import css/sheet
import css/stylednode
import css/values
import html/chadombuilder
import html/dom
import html/env
import html/event
import img/png
import io/connecterror
import io/loader
import io/posixstream
import io/promise
import io/teestream
import io/window
import ips/serialize
import ips/serversocket
import ips/socketstream
import js/error
import js/fromjs
import js/javascript
import js/regex
import js/timeout
import layout/box
import render/renderdocument
import render/rendertext
import types/buffersource
import types/color
import types/cookie
import types/formdata
import types/referer
import types/url
import utils/opt
import utils/twtstr
import xhr/formdata as formdata_impl

import chakasu/charset
import chakasu/decoderstream

import chame/tags

type
  LoadInfo* = enum
    CONNECT, DOWNLOAD, RENDER, DONE

  BufferCommand* = enum
    LOAD, RENDER, WINDOW_CHANGE, FIND_ANCHOR, READ_SUCCESS, READ_CANCELED,
    CLICK, FIND_NEXT_LINK, FIND_PREV_LINK, FIND_NEXT_MATCH, FIND_PREV_MATCH,
    GET_SOURCE, GET_LINES, UPDATE_HOVER, PASS_FD, CONNECT, CONNECT2,
    GOTO_ANCHOR, CANCEL, GET_TITLE, SELECT, REDIRECT_TO_FD, READ_FROM_FD,
    SET_CONTENT_TYPE

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
    readbufsize: int
    contenttype: string #TODO already stored in source
    lines: FlexibleGrid
    rendered: bool
    source: BufferSource
    width: int
    height: int
    attrs: WindowAttributes
    window: Window
    document: Document
    viewport: Viewport
    prevstyled: StyledNode
    selector: Selector[int]
    istream: Stream
    sstream: Stream
    available: int
    pstream: Stream # pipe stream
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
  return buffer.source.location

func charsets(buffer: Buffer): seq[Charset] =
  if buffer.source.charset != CHARSET_UNKNOWN:
    return @[buffer.source.charset]
  return buffer.config.charsets

func getTitleAttr(node: StyledNode): string =
  if node == nil:
    return ""
  if node.t == STYLED_ELEMENT and node.node != nil:
    let element = Element(node.node)
    if element.attrb("title"):
      return element.attr("title")
  if node.node != nil:
    var node = node.node
    for element in node.ancestors:
      if element.attrb("title"):
        return element.attr("title")
  #TODO pseudo-elements

const ClickableElements = {
  TAG_A, TAG_INPUT, TAG_OPTION, TAG_BUTTON, TAG_TEXTAREA, TAG_LABEL
}

func isClickable(styledNode: StyledNode): bool =
  if styledNode.t != STYLED_ELEMENT or styledNode.node == nil:
    return false
  if styledNode.computed{"visibility"} != VISIBILITY_VISIBLE:
    return false
  let element = Element(styledNode.node)
  if element.tagType == TAG_A:
    return HTMLAnchorElement(element).href != ""
  return element.tagType in ClickableElements

func getClickable(styledNode: StyledNode): Element =
  var styledNode = styledNode
  while styledNode != nil:
    if styledNode.isClickable():
      return Element(styledNode.node)
    styledNode = stylednode.parent

func submitForm(form: HTMLFormElement, submitter: Element): Option[Request]

func canSubmitOnClick(fae: FormAssociatedElement): bool =
  if fae.form == nil:
    return false
  if fae.form.canSubmitImplicitly():
    return true
  if fae.tagType == TAG_BUTTON:
    if HTMLButtonElement(fae).ctype == BUTTON_SUBMIT:
      return true
  if fae.tagType == TAG_INPUT:
    if HTMLInputElement(fae).inputType in {INPUT_SUBMIT, INPUT_BUTTON}:
      return true
  return false

func getClickHover(styledNode: StyledNode): string =
  let clickable = styledNode.getClickable()
  if clickable != nil:
    case clickable.tagType
    of TAG_A:
      return HTMLAnchorElement(clickable).href
    of TAG_INPUT:
      #TODO this is inefficient and also quite stupid
      if clickable.tagType in FormAssociatedElements:
        let fae = FormAssociatedElement(clickable)
        if fae.canSubmitOnClick():
          let req = fae.form.submitForm(fae)
          if req.isSome:
            return $req.get.url
      return "<input>"
    of TAG_OPTION:
      return "<option>"
    of TAG_BUTTON:
      return "<button>"
    of TAG_TEXTAREA:
      return "<textarea>"
    else: discard

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
  eprint "navigate to", url

proc findPrevLink*(buffer: Buffer, cursorx, cursory: int): tuple[x, y: int] {.proxy.} =
  if cursory >= buffer.lines.len: return (-1, -1)
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
      while i >= 0:
        let format = line.formats[i]
        let nl = format.node.getClickable()
        if nl == fl:
          ly = iy
          lx = format.pos
        dec i

  while i >= 0:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      let y = cursory
      link_beginning
      return (lx, ly)
    dec i

  for y in countdown(cursory - 1, 0):
    let line = buffer.lines[y]
    i = line.formats.len - 1
    while i >= 0:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        link_beginning
        return (lx, ly)
      dec i
  return (-1, -1)

proc findNextLink*(buffer: Buffer, cursorx, cursory: int): tuple[x, y: int] {.proxy.} =
  if cursory >= buffer.lines.len: return (-1, -1)
  let line = buffer.lines[cursory]
  var i = line.findFormatN(cursorx) - 1
  var link: Element = nil
  if i >= 0:
    link = line.formats[i].node.getClickable()
  inc i

  while i < line.formats.len:
    let format = line.formats[i]
    let fl = format.node.getClickable()
    if fl != nil and fl != link:
      return (format.pos, cursory)
    inc i

  for y in (cursory + 1)..(buffer.lines.len - 1):
    let line = buffer.lines[y]
    i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      let fl = format.node.getClickable()
      if fl != nil and fl != link:
        return (format.pos, y)
      inc i
  return (-1, -1)

proc findPrevMatch*(buffer: Buffer, regex: Regex, cursorx, cursory: int, wrap: bool): BufferMatch {.proxy.} =
  if cursory >= buffer.lines.len: return
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx)
  let res = regex.exec(buffer.lines[y].str, 0, b)
  if res.success and res.captures.len > 0:
    let cap = res.captures[^1]
    let x = buffer.lines[y].str.width(0, cap.s)
    let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
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
      return BufferMatch(success: true, x: x, y: y, str: str)
    if y == cursory:
      break
    dec y

proc findNextMatch*(buffer: Buffer, regex: Regex, cursorx, cursory: int, wrap: bool): BufferMatch {.proxy.} =
  if cursory >= buffer.lines.len: return
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx + 1)
  let res = regex.exec(buffer.lines[y].str, b, buffer.lines[y].str.len)
  if res.success and res.captures.len > 0:
    let cap = res.captures[0]
    let x = buffer.lines[y].str.width(0, cap.s)
    let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
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
      return BufferMatch(success: true, x: x, y: y, str: str)
    if y == cursory:
      break
    inc y

proc gotoAnchor*(buffer: Buffer): tuple[x, y: int] {.proxy.} =
  if buffer.document == nil: return (-1, -1)
  let anchor = buffer.document.getElementById(buffer.url.anchor)
  if anchor == nil: return
  for y in 0 ..< buffer.lines.len:
    let line = buffer.lines[y]
    for i in 0 ..< line.formats.len:
      let format = line.formats[i]
      if format.node != nil and anchor in format.node.node:
        return (format.pos, y)
  return (-1, -1)

proc do_reshape(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if buffer.viewport == nil:
      buffer.viewport = Viewport(window: buffer.attrs)
    let ret = renderDocument(buffer.document, buffer.userstyle,
      buffer.viewport, buffer.prevstyled)
    buffer.lines = ret.grid
    buffer.prevstyled = ret.styledRoot
  else:
    buffer.lines.renderStream(buffer.srenderer, buffer.available)
    buffer.available = 0

proc windowChange*(buffer: Buffer, attrs: WindowAttributes) {.proxy.} =
  buffer.attrs = attrs
  buffer.viewport = Viewport(window: buffer.attrs)
  buffer.width = buffer.attrs.width
  buffer.height = buffer.attrs.height - 1

type UpdateHoverResult* = object
  link*: Option[string]
  title*: Option[string]
  repaint*: bool

proc updateHover*(buffer: Buffer, cursorx, cursory: int): UpdateHoverResult {.proxy.} =
  if buffer.lines.len == 0: return
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

proc loadResource(buffer: Buffer, elem: HTMLLinkElement): EmptyPromise =
  let document = buffer.document
  let href = elem.attr("href")
  if href == "": return
  let url = parseURL(href, document.url.some)
  if url.isSome:
    let url = url.get
    let media = elem.media
    if media != "":
      let cvals = parseListOfComponentValues(newStringStream(media))
      let media = parseMediaQueryList(cvals)
      if not media.applies(document.window): return
    return buffer.loader.fetch(newRequest(url))
      .then(proc(res: JSResult[Response]): Promise[JSResult[string]] =
        if res.isOk:
          let res = res.get
          #TODO we should use ReadableStreams for this (which would allow us to
          # parse CSS asynchronously)
          if res.contenttype == "text/css":
            return res.text()
          res.unregisterFun()
      ).then(proc(s: JSResult[string]) =
        if s.isOk:
          #TODO this is extremely inefficient, and text() should return
          # utf8 anyways
          let ss = newStringStream(s.get)
          #TODO non-utf-8 css
          let source = newDecoderStream(ss, cs = CHARSET_UTF_8).readAll()
          let ss2 = newStringStream(source)
          elem.sheet = parseStylesheet(ss2))

proc loadResource(buffer: Buffer, elem: HTMLImageElement): EmptyPromise =
  let document = buffer.document
  let src = elem.attr("src")
  if src == "": return
  let url = parseURL(src, document.url.some)
  if url.isSome:
    let url = url.get
    return buffer.loader.fetch(newRequest(url))
      .then(proc(res: JSResult[Response]): Promise[JSResult[string]] =
        if res.isErr:
          return
        let res = res.get
        if res.contenttype == "image/png":
          #TODO using text() for PNG is wrong
          return res.text()
      ).then(proc(pngData: JSResult[string]) =
        if pngData.isErr:
          return
        let pngData = pngData.get
        elem.bitmap = fromPNG(toOpenArrayByte(pngData, 0, pngData.high)))

proc loadResources(buffer: Buffer): EmptyPromise =
  let document = buffer.document
  var promises: seq[EmptyPromise]
  if document.html != nil:
    var searchElems = {TAG_LINK}
    if buffer.config.images:
      searchElems.incl(TAG_IMG)
    for elem in document.html.elements(searchElems):
      var p: EmptyPromise = nil
      case elem.tagType
      of TAG_LINK:
        let elem = HTMLLinkElement(elem)
        if elem.rel == "stylesheet":
          p = buffer.loadResource(elem)
      of TAG_IMG:
        let elem = HTMLImageElement(elem)
        p = buffer.loadResource(elem)
      else: discard
      if p != nil:
        promises.add(p)
  return all(promises)

type ConnectResult* = object
  invalid*: bool
  code*: int
  needsAuth*: bool
  redirect*: Request
  contentType*: string
  cookies*: seq[Cookie]
  referrerpolicy*: Option[ReferrerPolicy]
  charset*: Charset

proc connect*(buffer: Buffer): ConnectResult {.proxy.} =
  if buffer.connected:
    return ConnectResult(invalid: true)
  let source = buffer.source
  # Warning: source content type overrides received content types, but source
  # charset is just a fallback.
  let setct = source.contenttype.isNone
  if not setct:
    buffer.contenttype = source.contenttype.get
  var charset = source.charset
  var needsAuth = false
  var redirect: Request
  var cookies: seq[Cookie]
  var referrerpolicy: Option[ReferrerPolicy]
  case source.t
  of CLONE:
    #TODO clone should probably just fork() the buffer instead.
    let s = connectSocketStream(source.clonepid, blocking = false)
    buffer.istream = s
    buffer.fd = int(s.source.getFd())
    if buffer.istream == nil:
      return ConnectResult(code: ERROR_SOURCE_NOT_FOUND)
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_PIPE:
    discard fcntl(source.fd, F_SETFL, fcntl(source.fd, F_GETFL, 0) or O_NONBLOCK)
    buffer.istream = newPosixStream(source.fd)
    buffer.fd = source.fd
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_REQUEST:
    let request = source.request
    let response = buffer.loader.doRequest(request, blocking = true, canredir = true)
    if response.body == nil:
      return ConnectResult(code: response.res)
    if response.charset != CHARSET_UNKNOWN:
      charset = charset
    if setct:
      buffer.contenttype = response.contenttype
    buffer.istream = response.body
    let fd = SocketStream(response.body).source.getFd()
    buffer.fd = int(fd)
    needsAuth = response.status == 401 # Unauthorized
    redirect = response.redirect
    if "Set-Cookie" in response.headers.table:
      for s in response.headers.table["Set-Cookie"]:
        let cookie = newCookie(s, response.url)
        if cookie.isOk:
          cookies.add(cookie.get)
    if "Referrer-Policy" in response.headers.table:
      referrerpolicy = getReferrerPolicy(response.headers.table["Referrer-Policy"][0])
  buffer.connected = true
  return ConnectResult(
    charset: charset,
    needsAuth: needsAuth,
    redirect: redirect,
    cookies: cookies,
    contentType: if setct: buffer.contenttype else: ""
  )

# After connect, pager will call one of the following:
# * connect2, telling loader to load at last (we block loader until then)
# * redirectToFd, telling loader to load into the passed fd
proc connect2*(buffer: Buffer) {.proxy.} =
  if buffer.source.t == LOAD_REQUEST:
    # Notify loader that we can proceed with loading the input stream.
    let ss = SocketStream(buffer.istream)
    ss.swrite(false)
    ss.setBlocking(false)
  buffer.istream = newTeeStream(buffer.istream, buffer.sstream,
    closedest = false)
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)

proc redirectToFd*(buffer: Buffer, fd: FileHandle, wait: bool) {.proxy.} =
  #TODO also clone & fd
  if buffer.source.t == LOAD_REQUEST:
    let ss = SocketStream(buffer.istream)
    ss.swrite(true)
    ss.sendFileHandle(fd)
    if wait:
      #TODO this is kind of dumb
      # Basically, after redirect the network process keeps the socket open,
      # and writes a boolean after transfer has been finished. This way,
      # we can block this promise so it only returns after e.g. the whole
      # file has been saved.
      var dummy: bool
      ss.sread(dummy)
    discard close(fd)
    ss.close()

proc readFromFd*(buffer: Buffer, fd: FileHandle, ishtml: bool) {.proxy.} =
  let contentType = if ishtml:
    "text/html"
  else:
    "text/plain"
  buffer.source = BufferSource(
    t: LOAD_PIPE,
    fd: fd,
    location: buffer.source.location,
    contenttype: some(contentType),
    charset: buffer.source.charset
  )
  buffer.contenttype = contentType
  discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) or O_NONBLOCK)
  let ps = newPosixStream(fd)
  buffer.istream = newTeeStream(ps, buffer.sstream,
    closedest = false)
  buffer.fd = fd
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)

proc setContentType*(buffer: Buffer, contentType: string) {.proxy.} =
  buffer.source.contenttype = some(contentType)

const BufferSize = 4096

proc finishLoad(buffer: Buffer): EmptyPromise =
  if buffer.state != LOADING_PAGE:
    let p = EmptyPromise()
    p.resolve()
    return p
  var p: EmptyPromise
  case buffer.contenttype
  of "text/html":
    buffer.sstream.setPosition(0)
    buffer.available = 0
    if buffer.window == nil:
      buffer.window = newWindow(buffer.config.scripting, buffer.selector,
        buffer.attrs)
    let doc = parseHTML(buffer.sstream, charsets = buffer.charsets,
      window = buffer.window, url = buffer.url)
    buffer.document = doc
    buffer.state = LOADING_RESOURCES
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
  let op = buffer.sstream.getPosition()
  var s = newString(buffer.readbufsize)
  try:
    buffer.sstream.setPosition(op + buffer.available)
    let n = buffer.istream.readData(addr s[0], buffer.readbufsize)
    if n != 0: # n can be 0 if we get EOF. (in which case we shouldn't reshape unnecessarily.)
      s.setLen(n)
      buffer.sstream.setPosition(op)
      if buffer.readbufsize < BufferSize:
        buffer.readbufsize = min(BufferSize, buffer.readbufsize * 2)
      buffer.available += s.len
      case buffer.contenttype
      of "text/html":
        res.bytes = buffer.available
      else:
        buffer.do_reshape()
    if buffer.istream.atEnd():
      res.atend = true
      buffer.finishLoad().then(proc() =
        buffer.state = LOADED
        buffer.resolveTask(LOAD, res))
      return
    buffer.resolveTask(LOAD, res)
  except ErrorAgain, ErrorWouldBlock:
    if buffer.readbufsize > 1:
      buffer.readbufsize = buffer.readbufsize div 2

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
  case buffer.contenttype
  of "text/html":
    buffer.sstream.setPosition(0)
    buffer.available = 0
    if buffer.window == nil:
      buffer.window = newWindow(buffer.config.scripting, buffer.selector,
        buffer.attrs)
    buffer.document = parseHTML(buffer.sstream,
      charsets = buffer.charsets, window = buffer.window,
      url = buffer.url, canReinterpret = false)
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

func submitForm(form: HTMLFormElement, submitter: Element): Option[Request] =
  if form.constructingEntryList:
    return
  let entrylist = form.constructEntryList(submitter).get(@[])

  let action = if submitter.action() == "":
    $form.document.url
  else:
    submitter.action()

  let url = submitter.document.parseURL(action)
  if url.isnone:
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
    parsedaction.query = query.some
    return newRequest(parsedaction, httpmethod).some

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
    return newRequest(parsedaction).some

  case scheme
  of "http", "https":
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      submitAsEntityBody
  of "ftp":
    getActionUrl
  of "data":
    if formmethod == FORM_METHOD_GET:
      mutateActionUrl
    else:
      assert formmethod == FORM_METHOD_POST
      getActionUrl

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

func implicitSubmit(input: HTMLInputElement): Option[Request] =
  if input.form != nil and input.form.canSubmitImplicitly():
    return submitForm(input.form, input.form)

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
        if path.issome:
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
    multiple: select.attrb("multiple"),
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
    var path = if input.file.issome:
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

proc dispatchEvent(buffer: Buffer, ctype: string, elem: Element): tuple[
      called: bool,
      canceled: bool
    ] =
  var called = false
  var canceled = false
  for a in elem.branch:
    var stop = false
    for el in a.eventListeners:
      if el.ctype == "click":
        let event = newEvent(buffer.window.jsctx, ctype, elem, a)
        let e = el.callback(event)
        called = true
        if e.isErr:
          buffer.window.jsctx.writeException(buffer.estream)
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

proc click*(buffer: Buffer, cursorx, cursory: int): ClickResult {.proxy.} =
  if buffer.lines.len <= cursory: return
  var called = false
  var canceled = false
  if buffer.config.scripting:
    let elem = buffer.getCursorElement(cursorx, cursory)
    (called, canceled) = buffer.dispatchEvent("click", elem)
    if called:
      buffer.do_reshape()
  if not canceled:
    let clickable = buffer.getCursorClickable(cursorx, cursory)
    if clickable != nil:
      var res = buffer.click(clickable)
      res.repaint = called
      return res
  return ClickResult(repaint: called)

proc select*(buffer: Buffer, selected: seq[int]): ClickResult {.proxy.} =
  if buffer.document.focus != nil and
      buffer.document.focus.tagType == TAG_SELECT:
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
  return buffer.document != nil and buffer.document.getElementById(anchor) != nil

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

proc passFd*(buffer: Buffer, fd: FileHandle) {.proxy.} =
  buffer.source.fd = fd

#TODO this is mostly broken
proc getSource*(buffer: Buffer) {.proxy.} =
  let ssock = initServerSocket()
  let stream = ssock.acceptSocketStream()
  let op = buffer.sstream.getPosition()
  buffer.sstream.setPosition(0)
  stream.write(buffer.sstream.readAll())
  buffer.sstream.setPosition(op)
  stream.close()
  ssock.close()

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
            let `id` = SocketStream(`buffer`.pstream).recvFileHandle()
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
    except EOFError:
      #eprint "EOF error", $buffer.url & "\nMESSAGE:",
      #       getCurrentExceptionMsg() & "\n",
      #       getStackTrace(getCurrentException())
      buffer.alive = false
  elif fd == buffer.fd:
    buffer.onload()
  elif fd in buffer.loader.connecting:
    buffer.loader.onConnected(fd)
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

proc runBuffer(buffer: Buffer, rfd: int) =
  buffer.rfd = rfd
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
        assert buffer.window.timeouts.runTimeoutFd(event.fd)
        buffer.window.runJSJobs()
    buffer.loader.unregistered.setLen(0)

proc launchBuffer*(config: BufferConfig, source: BufferSource,
    attrs: WindowAttributes, loader: FileLoader, ssock: ServerSocket) =
  let buffer = Buffer(
    alive: true,
    userstyle: parseStylesheet(config.userstyle),
    attrs: attrs,
    config: config,
    loader: loader,
    source: source,
    sstream: newStringStream(),
    viewport: Viewport(window: attrs),
    width: attrs.width,
    height: attrs.height - 1
  )
  buffer.readbufsize = BufferSize
  buffer.selector = newSelector[int]()
  loader.registerFun = proc(fd: int) = buffer.selector.registerHandle(fd, {Read}, 0)
  loader.unregisterFun = proc(fd: int) = buffer.selector.unregister(fd)
  buffer.srenderer = newStreamRenderer(buffer.sstream, buffer.charsets)
  if buffer.config.scripting:
    buffer.window = newWindow(buffer.config.scripting, buffer.selector,
      buffer.attrs, proc(url: URL) = buffer.navigate(url), some(buffer.loader))
  let socks = ssock.acceptSocketStream()
  buffer.estream = newFileStream(stderr)
  buffer.pstream = socks
  let rfd = int(socks.source.getFd())
  buffer.selector.registerHandle(rfd, {Read}, 0)
  buffer.runBuffer(rfd)
  buffer.pstream.close()
  buffer.loader.quit()
  quit(0)
