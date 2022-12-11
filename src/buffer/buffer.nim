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
import data/charset
import config/config
import html/dom
import html/tags
import html/htmlparser
import io/loader
import io/request
import io/posixstream
import io/teestream
import ips/serialize
import ips/serversocket
import ips/socketstream
import js/regex
import io/window
import layout/box
import render/renderdocument
import render/rendertext
import types/buffersource
import types/color
import types/url
import utils/twtstr

type
  LoadInfo* = enum
    CONNECT, DOWNLOAD, RENDER, DONE

  BufferCommand* = enum
    LOAD, RENDER, WINDOW_CHANGE, FIND_ANCHOR, READ_SUCCESS, READ_CANCELED,
    CLICK, FIND_NEXT_LINK, FIND_PREV_LINK, FIND_NEXT_MATCH, FIND_PREV_MATCH,
    GET_SOURCE, GET_LINES, UPDATE_HOVER, PASS_FD, CONNECT, GOTO_ANCHOR, CANCEL

  BufferMatch* = object
    success*: bool
    x*: int
    y*: int
    str*: string

  Buffer* = ref object
    alive: bool
    cs: Charset
    lasttimeout: int
    timeout: int
    readbufsize: int
    contenttype: string
    lines: FlexibleGrid
    rendered: bool
    source: BufferSource
    width: int
    height: int
    attrs: WindowAttributes
    document: Document
    viewport: Viewport
    prevstyled: StyledNode
    location: Url
    selector: Selector[int]
    istream: Stream
    sstream: Stream
    available: int
    pstream: Stream # pipe stream
    srenderer: StreamRenderer
    streamclosed: bool
    loaded: bool
    prevnode: StyledNode
    loader: FileLoader
    config: BufferConfig
    userstyle: CSSStylesheet
    timeouts: Table[int, (proc())]
    hovertext: string

  # async, but worse
  EmptyPromise = ref object of RootObj
    cb: (proc())
    next: EmptyPromise
    stream: Stream

  Promise*[T] = ref object of EmptyPromise
    res: T

  BufferInterface* = ref object
    stream*: Stream
    packetid: int
    promises: Table[int, EmptyPromise]

proc newBufferInterface*(ostream: Stream): BufferInterface =
  result = BufferInterface(
    stream: ostream
  )

proc fulfill*(iface: BufferInterface, packetid, len: int) =
  var promise: EmptyPromise
  if iface.promises.pop(packetid, promise):
    if promise.stream != nil and promise.cb == nil and len != 0:
      var abc = alloc(len)
      var x = 0
      while x < len:
        x += promise.stream.readData(abc, len)
      dealloc(abc)
    while promise != nil:
      if promise.cb != nil:
        promise.cb()
      promise = promise.next

proc hasPromises*(iface: BufferInterface): bool =
  return iface.promises.len > 0

proc then*(promise: EmptyPromise, cb: (proc())): EmptyPromise {.discardable.} =
  if promise == nil: return
  promise.cb = cb
  promise.next = EmptyPromise()
  return promise.next

proc then*[T](promise: Promise[T], cb: (proc(x: T))): EmptyPromise {.discardable.} =
  if promise == nil: return
  return promise.then(proc() =
    if promise.stream != nil:
      promise.stream.sread(promise.res)
    cb(promise.res))

proc then*[T, U](promise: Promise[T], cb: (proc(x: T): Promise[U])): Promise[U] {.discardable.} =
  if promise == nil: return
  let next = Promise[U]()
  promise.then(proc(x: T) =
    let p2 = cb(x)
    if p2 != nil:
      p2.then(proc(y: U) =
        next.res = y
        next.cb()))
  return next

proc buildInterfaceProc(fun: NimNode): tuple[fun, name: NimNode] =
  let name = fun[0] # sym
  let params = fun[3] # formalparams
  let retval = params[0] # sym
  var body = newStmtList()
  assert params.len >= 2 # return type, this value
  var x = name.strVal.toScreamingSnakeCase()
  if x[^1] == '=':
    x = "SET_" & x[0..^2]
  let nup = ident(x) # add this to enums
  let this2 = newIdentDefs(ident("iface"), ident("BufferInterface"))
  let thisval = this2[0]
  body.add(quote do:
    `thisval`.stream.swrite(BufferCommand.`nup`)
    `thisval`.stream.swrite(`thisval`.packetid))
  var params2: seq[NimNode]
  var retval2: NimNode
  if retval.kind == nnkEmpty:
    retval2 = ident("EmptyPromise")
  else:
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
    `thisval`.promises[`thisval`.packetid] = `retval2`(stream: `thisval`.stream)
    inc `thisval`.packetid)
  var pragmas: NimNode
  if retval.kind == nnkEmpty:
    body.add(quote do:
      return `thisval`.promises[`thisval`.packetid - 1])
    pragmas = newNimNode(nnkPragma).add(ident("discardable"))
  else:
    body.add(quote do:
      return `retval2`(`thisval`.promises[`thisval`.packetid - 1]))
    pragmas = newEmptyNode()
  return (newProc(name, params2, body, pragmas = pragmas), nup)

type
  ProxyFunction = object
    iname: NimNode # internal name
    ename: NimNode # enum name
    params: seq[NimNode]
  ProxyMap = Table[string, ProxyFunction]

# Name -> ProxyFunction
var ProxyFunctions {.compileTime.}: ProxyMap

macro proxy0(fun: untyped) =
  fun[0] = ident(fun[0].strVal & "_internal")
  return fun

macro proxy1(fun: typed) =
  let iproc = buildInterfaceProc(fun)
  var pfun: ProxyFunction
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
  ProxyFunctions[fun[0].strVal] = pfun
  return iproc[0]

macro proxy(fun: typed) =
  quote do:
    proxy0(`fun`)
    proxy1(`fun`)

func getTitle(node: StyledNode): string =
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

func getLink(node: StyledNode): HTMLAnchorElement =
  if node == nil:
    return nil
  if node.t == STYLED_ELEMENT and node.node != nil and Element(node.node).tagType == TAG_A:
    return HTMLAnchorElement(node.node)
  if node.node != nil:
    return HTMLAnchorElement(node.node.findAncestor({TAG_A}))
  #TODO ::before links?

const ClickableElements = {
  TAG_A, TAG_INPUT, TAG_OPTION, TAG_BUTTON, TAG_TEXTAREA
}

func getClickable(styledNode: StyledNode): Element =
  if styledNode == nil or styledNode.node == nil:
    return nil
  if styledNode.t == STYLED_ELEMENT:
    let element = Element(styledNode.node)
    if element.tagType in ClickableElements:
      return element
  styledNode.node.findAncestor(ClickableElements)

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
    w += r.width()
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
  template return_if_match =
    if res.success and res.captures.len > 0:
      let cap = res.captures[^1]
      let x = buffer.lines[y].str.width(cap.s)
      let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
      return BufferMatch(success: true, x: x, y: y, str: str)
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx)
  let b2 = if b > 0: b - buffer.lines[y].str.lastRune(b)[1] else: 0
  let res = regex.exec(buffer.lines[y].str, 0, b2)
  return_if_match
  dec y
  while true:
    if y < 0:
      if wrap:
        y = buffer.lines.high
      else:
        break
    if y == cursory:
      let res = regex.exec(buffer.lines[y].str, b, buffer.lines[y].str.len)
      return_if_match
      break
    let res = regex.exec(buffer.lines[y].str)
    return_if_match
    dec y

proc findNextMatch*(buffer: Buffer, regex: Regex, cursorx, cursory: int, wrap: bool): BufferMatch {.proxy.} =
  if cursory >= buffer.lines.len: return
  template return_if_match =
    if res.success and res.captures.len > 0:
      let cap = res.captures[0]
      let x = buffer.lines[y].str.width(cap.s)
      let str = buffer.lines[y].str.substr(cap.s, cap.e - 1)
      return BufferMatch(success: true, x: x, y: y, str: str)
  var y = cursory
  let b = buffer.cursorBytes(y, cursorx)
  let b2 = if buffer.lines[y].str.len > b: b + buffer.lines[y].str.runeLenAt(b) else: b
  let res = regex.exec(buffer.lines[y].str, b2, buffer.lines[y].str.len)
  return_if_match
  inc y
  while true:
    if y > buffer.lines.high:
      if wrap:
        y = 0
      else:
        break
    if y == cursory:
      let res = regex.exec(buffer.lines[y].str, 0, b)
      return_if_match
      break
    let res = regex.exec(buffer.lines[y].str)
    return_if_match
    inc y

proc gotoAnchor*(buffer: Buffer): tuple[x, y: int] {.proxy.} =
  if buffer.document == nil: return (-1, -1)
  let anchor = buffer.document.getElementById(buffer.location.anchor)
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
  hover*: Option[string]
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

    var upd = false
    let title = thisnode.getTitle()
    if title != "":
      upd = true
      buffer.hovertext = title
    elif (let link = thisnode.getLink(); link != nil):
      upd = true
      buffer.hovertext = link.href
    else:
      upd = buffer.hovertext != ""
      buffer.hovertext = ""
    if upd:
      result.hover = some(buffer.hovertext)

    for styledNode in prevnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if elem.hover:
          elem.hover = false
          result.repaint = true
  if result.repaint:
    buffer.do_reshape()

  buffer.prevnode = thisnode

proc loadResource(buffer: Buffer, document: Document, elem: HTMLLinkElement) =
  if elem.href == "": return
  let url = parseUrl(elem.href, document.location.some)
  if url.isSome:
    let url = url.get
    if url.scheme == buffer.location.scheme:
      let media = elem.media
      if media != "":
        let media = parseMediaQueryList(parseListOfComponentValues(newStringStream(media)))
        if not media.applies(): return
      let fs = buffer.loader.doRequest(newRequest(url))
      if fs.body != nil and fs.contenttype == "text/css":
        elem.sheet = parseStylesheet(fs.body)

proc loadResources(buffer: Buffer, document: Document) =
  var stack: seq[Element]
  if document.html != nil:
    stack.add(document.html)
  while stack.len > 0:
    let elem = stack.pop()

    if elem.tagType == TAG_LINK:
      let elem = HTMLLinkElement(elem)
      if elem.rel == "stylesheet":
        buffer.loadResource(document, elem)

    for child in elem.children_rev:
      stack.add(child)

type ConnectResult* = tuple[code: int, needsAuth: bool, redirect: Option[URL], contentType: string] 

proc setupSource(buffer: Buffer): ConnectResult =
  if buffer.loaded:
    result.code = -2
    return
  let source = buffer.source
  let setct = source.contenttype.isNone
  if not setct:
    buffer.contenttype = source.contenttype.get
  buffer.location = source.location
  case source.t
  of CLONE:
    buffer.istream = connectSocketStream(source.clonepid, blocking = false)
    if buffer.istream == nil:
      result.code = -2
      return
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_PIPE:
    discard fcntl(source.fd, F_SETFL, fcntl(source.fd, F_GETFL, 0) or O_NONBLOCK)
    buffer.istream = newPosixStream(source.fd)
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_REQUEST:
    let request = source.request
    let response = buffer.loader.doRequest(request)
    if response.body == nil:
      result.code = response.res
      return
    if setct:
      buffer.contenttype = response.contenttype
    buffer.istream = response.body
    SocketStream(buffer.istream).source.getFd().setBlocking(false)
    result.needsAuth = response.status == 401 # Unauthorized
    result.redirect = response.redirect
  buffer.istream = newTeeStream(buffer.istream, buffer.sstream, closedest = false)
  if setct:
    result.contentType = buffer.contenttype
  buffer.loaded = true

proc connect*(buffer: Buffer): ConnectResult {.proxy.} =
  let code = buffer.setupSource()
  return code

const BufferSize = 4096

proc finishLoad(buffer: Buffer) =
  if buffer.streamclosed: return
  case buffer.contenttype
  of "text/html":
    buffer.sstream.setPosition(0)
    buffer.available = 0
    let (doc, cs) = parseHTML5(buffer.sstream, fallbackcs = buffer.cs)
    buffer.document = doc
    if buffer.document == nil: # needsreinterpret
      buffer.sstream.setPosition(0)
      let (doc, _) = parseHTML5(buffer.sstream, cs = some(cs))
      buffer.document = doc
    buffer.document.location = buffer.location
    buffer.loadResources(buffer.document)
  buffer.istream.close()
  buffer.streamclosed = true

proc load*(buffer: Buffer): tuple[atend: bool, lines, bytes: int] {.proxy.} =
  var bytes = -1
  if buffer.streamclosed: return (true, buffer.lines.len, bytes)
  let op = buffer.sstream.getPosition()
  var s = newString(buffer.readbufsize)
  try:
    buffer.sstream.setPosition(op + buffer.available)
    let n = buffer.istream.readData(addr s[0], buffer.readbufsize)
    s.setLen(n)
    result = (n == 0, buffer.lines.len, bytes)
    buffer.sstream.setPosition(op)
    if buffer.readbufsize < BufferSize:
      buffer.readbufsize = min(BufferSize, buffer.readbufsize * 2)
    buffer.available += s.len
    case buffer.contenttype
    of "text/html":
      bytes = buffer.available
    else:
      buffer.do_reshape()
    if result.atend:
      buffer.finishLoad()
  except ErrorAgain, ErrorWouldBlock:
    buffer.timeout = buffer.lasttimeout
    if buffer.readbufsize == 1:
      if buffer.lasttimeout == 0:
        buffer.lasttimeout = 32
      elif buffer.lasttimeout < 1048:
        buffer.lasttimeout *= 2
    else:
      buffer.readbufsize = buffer.readbufsize div 2
    result = (false, buffer.lines.len, bytes)

proc render*(buffer: Buffer): int {.proxy.} =
  buffer.do_reshape()
  return buffer.lines.len

proc cancel*(buffer: Buffer): int {.proxy.} =
  if buffer.streamclosed: return
  buffer.istream.close()
  buffer.streamclosed = true
  case buffer.contenttype
  of "text/html":
    buffer.sstream.setPosition(0)
    buffer.available = 0
    let (doc, _) = parseHTML5(buffer.sstream, cs = some(buffer.cs)) # confidence: certain
    buffer.document = doc
    buffer.document.location = buffer.location
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
proc makeCRLF(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len - 1:
    if s[i] == '\r' and s[i + 1] != '\n':
      result &= '\r'
      result &= '\n'
    elif s[i] != '\r' and s[i + 1] == '\n':
      result &= s[i]
      result &= '\r'
      result &= '\n'
      inc i
    else:
      result &= s[i]
    inc i

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

proc submitForm(form: HTMLFormElement, submitter: Element): Option[Request] =
  let entrylist = form.constructEntryList(submitter)

  let action = if submitter.action() == "":
    $form.document.location
  else:
    submitter.action()

  let url = parseUrl(action, submitter.document.baseUrl.some)
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
    return newRequest(parsedaction, httpmethod, {"Content-Type": mimetype}, body, multipart).some

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

proc implicitSubmit(buffer: Buffer, input: HTMLInputElement): Option[Request] =
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
        result.open = buffer.implicitSubmit(input)
      of INPUT_FILE:
        let cdir = parseUrl("file://" & getCurrentDir() & DirSep)
        let path = parseUrl(s, cdir)
        if path.issome:
          input.file = path
          input.invalid = true
          buffer.do_reshape()
          result.repaint = true
          result.open = buffer.implicitSubmit(input)
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

proc click*(buffer: Buffer, cursorx, cursory: int): ClickResult {.proxy.} =
  if buffer.lines.len <= cursory: return
  let clickable = buffer.getCursorClickable(cursorx, cursory)
  if clickable != nil:
    case clickable.tagType
    of TAG_SELECT:
      result.repaint = buffer.setFocus(clickable)
    of TAG_A:
      result.repaint = buffer.restoreFocus()
      let url = parseUrl(HTMLAnchorElement(clickable).href, clickable.document.baseUrl.some)
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

proc readCanceled*(buffer: Buffer): bool {.proxy.} =
  return buffer.restoreFocus()

proc findAnchor*(buffer: Buffer, anchor: string): bool {.proxy.} =
  return buffer.document != nil and buffer.document.getElementById(anchor) != nil

proc getLines*(buffer: Buffer, w: Slice[int]): tuple[numLines: int, lines: seq[SimpleFlexibleLine]] {.proxy.} =
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
  buffer.finishLoad()
  buffer.sstream.setPosition(0)
  stream.write(buffer.sstream.readAll())
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
    if v.ename.strVal == "LOAD": #TODO TODO TODO this is very ugly
      stmts.add(quote do:
        if buffer.timeout > 0:
          let fdi = buffer.selector.registerTimer(buffer.timeout, true, 0)
          buffer.timeouts[fdi] = (proc() =
            let len = slen(`packetid`) + slen(`rval`)
            buffer.pstream.swrite(len)
            buffer.pstream.swrite(`packetid`)
            buffer.pstream.swrite(`rval`)
            buffer.pstream.flush())
          buffer.timeout = 0
          return)
    if rval == nil:
      stmts.add(quote do:
        let len = slen(`packetid`)
        buffer.pstream.swrite(len)
        buffer.pstream.swrite(`packetid`)
        buffer.pstream.flush())
    else:
      stmts.add(quote do:
        let len = slen(`packetid`) + slen(`rval`)
        buffer.pstream.swrite(len)
        buffer.pstream.swrite(`packetid`)
        buffer.pstream.swrite(`rval`)
        buffer.pstream.flush())
    ofbranch.add(stmts)
    switch.add(ofbranch)
  return switch

proc readCommand(buffer: Buffer) =
  var cmd: BufferCommand
  buffer.pstream.sread(cmd)
  var packetid: int
  buffer.pstream.sread(packetid)
  bufferDispatcher(ProxyFunctions, buffer, cmd, packetid)

proc runBuffer(buffer: Buffer, rfd: int) =
  block loop:
    while buffer.alive:
      let events = buffer.selector.select(-1)
      for event in events:
        if Read in event.events:
          if event.fd == rfd:
            try:
              buffer.readCommand()
            except IOError:
              #eprint "ERROR IN BUFFER", buffer.location
              #eprint "MESSAGE:", getCurrentExceptionMsg()
              #eprint getStackTrace(getCurrentException())
              break loop
          else:
            assert false
        if Event.Timer in event.events:
          buffer.selector.unregister(event.fd)
          var timeout: proc()
          if buffer.timeouts.pop(event.fd, timeout):
            timeout()
          else:
            assert false
        if Error in event.events:
          if event.fd == rfd:
            break loop
          else:
            assert false
  buffer.pstream.close()
  buffer.loader.quit()
  quit(0)

proc launchBuffer*(config: BufferConfig, source: BufferSource,
                   attrs: WindowAttributes, loader: FileLoader,
                   mainproc: Pid) =
  let buffer = Buffer(
    alive: true,
    cs: CHARSET_UTF_8,
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
  buffer.srenderer = newStreamRenderer(buffer.sstream)
  let socks = connectSocketStream(mainproc, false)
  socks.swrite(getpid())
  buffer.pstream = socks
  let rfd = int(socks.source.getFd())
  buffer.selector.registerHandle(rfd, {Read}, 0)
  buffer.runBuffer(rfd)
