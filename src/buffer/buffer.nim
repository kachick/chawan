import macros
import nativesockets
import net
import options
import os
import selectors
import streams
import tables
import unicode

when defined(posix):
  import posix

import buffer/cell
import css/cascade
import css/cssparser
import css/mediaquery
import css/sheet
import css/stylednode
import config/config
import data/charset
import html/dom
import html/env
import html/htmlparser
import html/tags
import io/loader
import io/request
import io/posixstream
import io/promise
import io/teestream
import ips/serialize
import ips/serversocket
import ips/socketstream
import js/regex
import js/timeout
import io/window
import layout/box
import render/renderdocument
import render/rendertext
import types/buffersource
import types/color
import types/cookie
import types/referer
import types/url
import utils/twtstr

type
  LoadInfo* = enum
    CONNECT, DOWNLOAD, RENDER, DONE

  BufferCommand* = enum
    LOAD, RENDER, WINDOW_CHANGE, FIND_ANCHOR, READ_SUCCESS, READ_CANCELED,
    CLICK, FIND_NEXT_LINK, FIND_PREV_LINK, FIND_NEXT_MATCH, FIND_PREV_MATCH,
    GET_SOURCE, GET_LINES, UPDATE_HOVER, PASS_FD, CONNECT, GOTO_ANCHOR, CANCEL,
    GET_TITLE

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
    oldfd: int # fd after being unregistered
    alive: bool
    readbufsize: int
    contenttype: string
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
    url: URL
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

func charsets(buffer: Buffer): seq[Charset] =
  if buffer.source.charset.isSome:
    return @[buffer.source.charset.get]
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

func getClickable(styledNode: StyledNode): Element =
  if styledNode == nil:
    return nil
  var styledNode = styledNode
  while styledNode.node == nil:
    styledNode = styledNode.parent
    if styledNode == nil:
      return nil
  if styledNode.t == STYLED_ELEMENT:
    let element = Element(styledNode.node)
    if element.tagType in ClickableElements and (element.tagType != TAG_A or HTMLAnchorElement(element).href != ""):
      return element
  var node = styledNode.node
  while true:
    result = node.findAncestor(ClickableElements)
    if result == nil:
      break
    if result.tagType != TAG_A or HTMLAnchorElement(result).href != "":
      break
    node = result

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

func getCursorClickable(buffer: Buffer, cursorx, cursory: int): Element =
  let i = buffer.lines[cursory].findFormatN(cursorx) - 1
  if i >= 0:
    return buffer.lines[cursory].formats[i].node.getClickable()

func cursorBytes(buffer: Buffer, y: int, cc: int): int =
  let line = buffer.lines[y].str
  var w = 0
  var i = 0
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.twidth(w)
  return i

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
    let ret = renderDocument(buffer.document, buffer.attrs, buffer.userstyle, buffer.viewport, buffer.prevstyled)
    buffer.lines = ret[0]
    buffer.prevstyled = ret[1]
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

proc loadResource(buffer: Buffer, document: Document, elem: HTMLLinkElement): EmptyPromise =
  let href = elem.attr("href")
  if href == "": return
  let url = parseURL(href, document.url.some)
  if url.isSome:
    let url = url.get
    if url.scheme == buffer.url.scheme:
      let media = elem.media
      if media != "":
        let media = parseMediaQueryList(parseListOfComponentValues(newStringStream(media)))
        if not media.applies(): return
      return buffer.loader.fetch(newRequest(url)).then(proc(res: Response) =
        if res.contenttype == "text/css":
          elem.sheet = parseStylesheet(res.body))

proc loadResources(buffer: Buffer, document: Document): EmptyPromise =
  var promises: seq[EmptyPromise]
  if document.html != nil:
    for elem in document.html.elements(TAG_LINK):
      let elem = HTMLLinkElement(elem)
      if elem.rel == "stylesheet":
        let p = buffer.loadResource(document, elem)
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

proc setupSource(buffer: Buffer): ConnectResult =
  if buffer.connected:
    result.invalid = true
    return
  let source = buffer.source
  let setct = source.contenttype.isNone
  if not setct:
    buffer.contenttype = source.contenttype.get
  buffer.url = source.location
  case source.t
  of CLONE:
    #TODO clone should probably just fork() the buffer instead.
    let s = connectSocketStream(source.clonepid, blocking = false)
    buffer.istream = s
    buffer.fd = cast[int](s.source.getFd())
    if buffer.istream == nil:
      result.code = ERROR_SOURCE_NOT_FOUND
      return
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
    let response = buffer.loader.doRequest(request, blocking = false)
    if response.body == nil:
      result.code = response.res
      return
    if setct:
      buffer.contenttype = response.contenttype
    buffer.istream = response.body
    let fd = SocketStream(response.body).source.getFd()
    buffer.fd = cast[int](fd)
    result.needsAuth = response.status == 401 # Unauthorized
    result.redirect = response.redirect
    if "Set-Cookie" in response.headers.table:
      for s in response.headers.table["Set-Cookie"]:
        let cookie = newCookie(s)
        if cookie != nil:
          result.cookies.add(cookie)
    if "Referrer-Policy" in response.headers.table:
      result.referrerpolicy = getReferrerPolicy(response.headers.table["Referrer-Policy"][0])
  buffer.istream = newTeeStream(buffer.istream, buffer.sstream, closedest = false)
  buffer.selector.registerHandle(buffer.fd, {Read}, 0)
  if setct:
    result.contentType = buffer.contenttype
  buffer.connected = true

proc connect*(buffer: Buffer): ConnectResult {.proxy.} =
  let code = buffer.setupSource()
  return code

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
      buffer.window = newWindow(buffer.config.scripting, buffer.selector)
    let doc = parseHTML(buffer.sstream, charsets = buffer.charsets,
      window = buffer.window, url = buffer.url)
    buffer.document = doc
    buffer.state = LOADING_RESOURCES
    p = buffer.loadResources(buffer.document)
  else:
    p = EmptyPromise()
    p.resolve()
  buffer.selector.unregister(buffer.fd)
  buffer.oldfd = buffer.fd
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
      buffer.window = newWindow(buffer.config.scripting, buffer.selector)
    buffer.document = parseHTML(buffer.sstream,
      charsets = buffer.charsets, window = buffer.window,
      url = buffer.url, canReinterpret = false)
    buffer.do_reshape()
  return buffer.lines.len

# https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-form-data-set
proc constructEntryList(form: HTMLFormElement, submitter: Element = nil, encoding: string = ""): seq[tuple[name, value: string]] =
  if form.constructingentrylist:
    return
  form.constructingentrylist = true

  var entrylist: seq[tuple[name, value: string]]
  for field in form.controls:
    if field.findAncestor({TAG_DATALIST}) != nil or
        field.attrb("disabled") or
        field.isButton() and Element(field) != submitter:
      continue

    if field.tagType == TAG_INPUT:
      let field = HTMLInputElement(field)
      if field.inputType == INPUT_IMAGE:
        let name = if field.attr("name") != "":
          field.attr("name") & '.'
        else:
          ""
        entrylist.add((name & 'x', $field.xcoord))
        entrylist.add((name & 'y', $field.ycoord))
        continue

    #TODO custom elements

    let name = field.attr("name")

    if name == "":
      continue

    if field.tagType == TAG_SELECT:
      let field = HTMLSelectElement(field)
      for option in field.options:
        if option.selected or option.disabled:
          entrylist.add((name, option.value))
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_CHECKBOX, INPUT_RADIO}:
      let value = if field.attr("value") != "":
        field.attr("value")
      else:
        "on"
      entrylist.add((name, value))
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_FILE:
      #TODO file
      discard
    elif field.tagType == TAG_INPUT and HTMLInputElement(field).inputType == INPUT_HIDDEN and name.equalsIgnoreCase("_charset_"):
      let charset = if encoding != "":
        encoding
      else:
        "UTF-8"
      entrylist.add((name, charset))
    else:
      case field.tagType
      of TAG_INPUT:
        entrylist.add((name, HTMLInputElement(field).value))
      of TAG_BUTTON:
        entrylist.add((name, HTMLButtonElement(field).value))
      of TAG_TEXTAREA:
        entrylist.add((name, HTMLTextAreaElement(field).value))
      else: assert false, "Tag type " & $field.tagType & " not accounted for in constructEntryList"
    if field.tagType == TAG_TEXTAREA or
        field.tagType == TAG_INPUT and HTMLInputElement(field).inputType in {INPUT_TEXT, INPUT_SEARCH}:
      if field.attr("dirname") != "":
        let dirname = field.attr("dirname")
        let dir = "ltr" #TODO bidi
        entrylist.add((dirname, dir))

  form.constructingentrylist = false
  return entrylist

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc serializeMultipartFormData(kvs: seq[(string, string)]): MimeData =
  for it in kvs:
    let name = makeCRLF(it[0])
    let value = makeCRLF(it[1])
    result[name] = value

proc serializePlainTextFormData(kvs: seq[(string, string)]): string =
  for it in kvs:
    let (name, value) = it
    result &= name
    result &= '='
    result &= value
    result &= "\r\n"

func submitForm(form: HTMLFormElement, submitter: Element): Option[Request] =
  let entrylist = form.constructEntryList(submitter)

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
    let query = serializeApplicationXWWWFormUrlEncoded(entrylist)
    parsedaction.query = query.some
    return newRequest(parsedaction, httpmethod).some

  template submitAsEntityBody() =
    var mimetype: string
    var body = none(string)
    var multipart = none(MimeData)
    case enctype
    of FORM_ENCODING_TYPE_URLENCODED:
      body = serializeApplicationXWWWFormUrlEncoded(entrylist).some
      mimeType = $enctype
    of FORM_ENCODING_TYPE_MULTIPART:
      multipart = serializeMultipartFormData(entrylist).some
      mimetype = $enctype
    of FORM_ENCODING_TYPE_TEXT_PLAIN:
      body = serializePlainTextFormData(entrylist).some
      mimetype = $enctype
    return newRequest(parsedaction, httpmethod, @{"Content-Type": mimetype}, body).some #TODO multipart

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

type ClickResult* = object
  open*: Option[Request]
  readline*: Option[ReadLineResult]
  repaint*: bool

proc click(buffer: Buffer, clickable: Element): ClickResult =
  case clickable.tagType
  of TAG_LABEL:
    let label = HTMLLabelElement(clickable)
    let control = label.control
    if control != nil:
      return buffer.click(control)
  of TAG_SELECT:
    result.repaint = buffer.setFocus(clickable)
  of TAG_A:
    result.repaint = buffer.restoreFocus()
    let url = parseURL(HTMLAnchorElement(clickable).href, clickable.document.baseURL.some)
    if url.issome:
      result.open = some(newRequest(url.get, HTTP_GET))
  of TAG_OPTION:
    let option = HTMLOptionElement(clickable)
    let select = option.select
    if select != nil:
      if buffer.document.focus == select:
        # select option
        if not select.attrb("multiple"):
          for option in select.options:
            option.selected = false
        option.selected = true
        result.repaint = buffer.restoreFocus()
      else:
        # focus on select
        result.repaint = buffer.setFocus(select)
  of TAG_BUTTON:
    let button = HTMLButtonElement(clickable)
    if button.form != nil:
      case button.ctype
      of BUTTON_SUBMIT: result.open = submitForm(button.form, button)
      of BUTTON_RESET:
        button.form.reset()
        result.repaint = true
        buffer.do_reshape()
      of BUTTON_BUTTON: discard
  of TAG_TEXTAREA:
    result.repaint = buffer.setFocus(clickable)
    let textarea = HTMLTextAreaElement(clickable)
    result.readline = some(ReadLineResult(
      value: textarea.value,
      area: true
    ))
  of TAG_INPUT:
    result.repaint = buffer.restoreFocus()
    let input = HTMLInputElement(clickable)
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
  else:
    result.repaint = buffer.restoreFocus()

proc click*(buffer: Buffer, cursorx, cursory: int): ClickResult {.proxy.} =
  if buffer.lines.len <= cursory: return
  let clickable = buffer.getCursorClickable(cursorx, cursory)
  if clickable != nil:
    return buffer.click(clickable)

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

proc passFd*(buffer: Buffer) {.proxy.} =
  let fd = SocketStream(buffer.pstream).recvFileHandle()
  buffer.source.fd = fd

proc getSource*(buffer: Buffer) {.proxy.} =
  let ssock = initServerSocket()
  let stream = ssock.acceptSocketStream()
  let op = buffer.sstream.getPosition()
  buffer.sstream.setPosition(0)
  stream.write(buffer.sstream.readAll())
  buffer.sstream.setPosition(op)
  stream.close()
  ssock.close()

macro bufferDispatcher(funs: static ProxyMap, buffer: Buffer, cmd: BufferCommand, packetid: int) =
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
  elif fd in buffer.loader.ongoing:
    #TODO something with readablestream?
    discard
  elif buffer.fd == -1 and buffer.oldfd == fd:
    discard #TODO hack
  else: assert false

proc handleError(buffer: Buffer, fd: int) =
  if fd == buffer.rfd:
    # Connection reset by peer, probably. Close the buffer.
    buffer.alive = false
  elif fd == buffer.fd:
    buffer.onload()
  elif fd in buffer.loader.connecting:
    # probably shouldn't happen. TODO
    assert false
  elif fd in buffer.loader.ongoing:
    #TODO something with readablestream?
    discard
  elif buffer.fd == -1 and fd == buffer.oldfd:
    discard #TODO hack
  else:
    assert false

proc runBuffer(buffer: Buffer, rfd: int) =
  buffer.rfd = rfd
  while buffer.alive:
    let events = buffer.selector.select(-1)
    for event in events:
      if Error in event.events:
        buffer.handleError(event.fd)
      if not buffer.alive:
        break
      if Read in event.events:
        buffer.handleRead(event.fd)
      if Event.Timer in event.events:
        assert buffer.window != nil
        assert buffer.window.timeouts.runTimeoutFd(event.fd)
        buffer.window.runJSJobs()
  buffer.pstream.close()
  buffer.loader.quit()
  quit(0)

proc launchBuffer*(config: BufferConfig, source: BufferSource,
                   attrs: WindowAttributes, loader: FileLoader,
                   mainproc: Pid) =
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
      some(buffer.loader))
  let socks = connectSocketStream(mainproc, false)
  socks.swrite(getpid())
  buffer.pstream = socks
  let rfd = int(socks.source.getFd())
  buffer.selector.registerHandle(rfd, {Read}, 0)
  buffer.runBuffer(rfd)
