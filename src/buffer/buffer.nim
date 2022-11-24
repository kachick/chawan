import macros
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
import config/bufferconfig
import html/dom
import html/tags
import html/htmlparser
import io/loader
import io/request
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
  BufferCommand* = enum
    LOAD, RENDER, WINDOW_CHANGE, GOTO_ANCHOR, READ_SUCCESS, READ_CANCELED,
    CLICK, FIND_NEXT_LINK, FIND_PREV_LINK, FIND_NEXT_MATCH, FIND_PREV_MATCH,
    GET_SOURCE, GET_LINES, MOVE_CURSOR

  ContainerCommand* = enum
    SET_LINES, SET_NEEDS_AUTH, SET_CONTENT_TYPE, SET_REDIRECT, SET_TITLE,
    SET_HOVER, READ_LINE, LOAD_DONE, ANCHOR_FOUND, ANCHOR_FAIL, JUMP, OPEN,
    BUFFER_READY, SOURCE_READY, RESHAPE

  BufferMatch* = object
    success*: bool
    x*: int
    y*: int
    str*: string

  Buffer* = ref object
    input: HTMLInputElement
    contenttype: string
    lines: FlexibleGrid
    rendered: bool
    bsource: BufferSource
    width: int
    height: int
    attrs: WindowAttributes
    document: Document
    viewport: Viewport
    prevstyled: StyledNode
    reshape: bool
    location: Url
    selector: Selector[int]
    istream: Stream
    pistream: Stream # for input pipe
    postream: Stream # for output pipe
    streamclosed: bool
    loaded: bool
    source: string
    prevnode: StyledNode
    loader: FileLoader
    config: BufferConfig

macro writeCommand(buffer: Buffer, cmd: ContainerCommand, args: varargs[typed]) =
  result = newStmtList()
  result.add(quote do: `buffer`.postream.swrite(`cmd`))
  for arg in args:
    result.add(quote do: `buffer`.postream.swrite(`arg`))
  result.add(quote do: `buffer`.postream.flush())

func getLink(node: StyledNode): HTMLAnchorElement =
  if node == nil:
    return nil
  if node.t == STYLED_ELEMENT and node.node != nil and Element(node.node).tagType == TAG_A:
    return HTMLAnchorElement(node.node)
  if node.node != nil:
    return HTMLAnchorElement(node.node.findAncestor({TAG_A}))
  #TODO ::before links?

const ClickableElements = {
  TAG_A, TAG_INPUT, TAG_OPTION
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

func findNextLink(buffer: Buffer, cursorx, cursory: int): tuple[x, y: int] =
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

func findPrevLink(buffer: Buffer, cursorx, cursory: int): tuple[x, y: int] =
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

proc findNextMatch(buffer: Buffer, regex: Regex, cursorx, cursory: int, wrap: bool): BufferMatch =
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

proc findPrevMatch(buffer: Buffer, regex: Regex, cursorx, cursory: int, wrap: bool): BufferMatch =
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

proc gotoAnchor(buffer: Buffer) =
  if buffer.document == nil: return
  let anchor = buffer.document.getElementById(buffer.location.anchor)
  if anchor == nil: return
  for y in 0..<buffer.lines.len:
    let line = buffer.lines[y]
    var i = 0
    while i < line.formats.len:
      let format = line.formats[i]
      if format.node != nil and anchor in format.node.node:
        buffer.writeCommand(JUMP, format.pos, y)
        return
      inc i

proc windowChange(buffer: Buffer) =
  buffer.viewport = Viewport(window: buffer.attrs)
  buffer.width = buffer.attrs.width
  buffer.height = buffer.attrs.height - 1
  buffer.reshape = true

proc updateHover(buffer: Buffer, cursorx, cursory: int) =
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
          buffer.reshape = true

    let link = thisnode.getLink()
    if link != nil:
      buffer.writeCommand(SET_HOVER, link.href)
    else:
      buffer.writeCommand(SET_HOVER, "")

    for styledNode in prevnode.branch:
      if styledNode.t == STYLED_ELEMENT and styledNode.node != nil:
        let elem = Element(styledNode.node)
        if elem.hover:
          elem.hover = false
          buffer.reshape = true

  buffer.prevnode = thisnode

proc loadResource(buffer: Buffer, document: Document, elem: HTMLLinkElement) =
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

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

func getFd(buffer: Buffer): FileHandle =
  let source = buffer.bsource
  case source.t
  of CLONE, LOAD_REQUEST:
    let istream = SocketStream(buffer.istream)
    return cast[FileHandle](istream.source.getFd())
  of LOAD_PIPE:
    return buffer.bsource.fd

proc setupSource(buffer: Buffer): int =
  if buffer.loaded: return -2
  let source = buffer.bsource
  let setct = source.contenttype.isNone
  if not setct:
    buffer.contenttype = source.contenttype.get
  buffer.location = source.location
  case source.t
  of CLONE:
    buffer.istream = connectSocketStream(source.clonepid)
    if buffer.istream == nil: return -2
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_PIPE:
    var f: File
    if not open(f, source.fd, fmRead):
      return 1
    discard c_setvbuf(f, nil, IONBF, 0)
    buffer.istream = newFileStream(f)
    if setct:
      buffer.contenttype = "text/plain"
  of LOAD_REQUEST:
    let request = source.request
    let response = buffer.loader.doRequest(request)
    if response.body == nil:
      return response.res
    if setct:
      buffer.contenttype = response.contenttype
    buffer.istream = response.body
    if response.status == 401: # Unauthorized
      buffer.writeCommand(SET_NEEDS_AUTH)
    if response.redirect.isSome:
      buffer.writeCommand(SET_REDIRECT, response.redirect.get)
  if setct:
    buffer.writeCommand(SET_CONTENT_TYPE, buffer.contenttype)
  buffer.selector.registerHandle(cast[int](buffer.getFd()), {Read}, 1)
  buffer.loaded = true

proc load(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if not buffer.streamclosed:
      buffer.source = buffer.istream.readAll()
      buffer.istream.close()
      buffer.istream = newStringStream(buffer.source)
      buffer.document = parseHTML5(buffer.istream)
      buffer.streamclosed = true
    else:
      buffer.document = parseHTML5(newStringStream(buffer.source))
    buffer.writeCommand(SET_TITLE, buffer.document.title)
    buffer.document.location = buffer.location
    buffer.loadResources(buffer.document)
  else:
    discard
    #if not buffer.streamclosed:
    #  if buffer.bsource.t != LOAD_PIPE:
    #    buffer.source = buffer.istream.readAll()
    #    buffer.istream.close()
    #    buffer.streamclosed = true

proc render(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    if buffer.viewport == nil:
      buffer.viewport = Viewport(window: buffer.attrs)
    let ret = renderDocument(buffer.document, buffer.attrs, buffer.config.userstyle, buffer.viewport, buffer.prevstyled)
    buffer.lines = ret[0]
    buffer.prevstyled = ret[1]
  else:
    buffer.lines = renderPlainText(buffer.source)

proc load2(buffer: Buffer) =
  case buffer.contenttype
  of "text/html":
    assert false, "Not implemented yet..."
  else:
    # This is incredibly stupid but it works so whatever.
    # (We're basically recv'ing single bytes, but nim std/net does buffering
    # for us so we should be ok?)
    if not buffer.streamclosed:
      let c = buffer.istream.readChar()
      buffer.source &= c
      buffer.reshape = true

proc finishLoad(buffer: Buffer) =
  if not buffer.streamclosed:
    if not buffer.istream.atEnd:
      buffer.source &= buffer.istream.readAll()
      buffer.reshape = true
    buffer.selector.unregister(int(buffer.getFd()))
    buffer.istream.close()
    buffer.streamclosed = true

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
      if field.tagType == TAG_INPUT:
        entrylist.add((name, HTMLInputElement(field).value))
      else:
        assert false
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

template set_focus(e: Element) =
  if buffer.document.focus != e:
    buffer.document.focus = e
    buffer.reshape = true

template restore_focus =
  if buffer.document.focus != nil:
    buffer.document.focus = nil
    buffer.reshape = true

proc lineInput(buffer: Buffer, s: string) =
  if buffer.input != nil:
    let input = buffer.input
    case input.inputType
    of INPUT_SEARCH:
      input.value = s
      input.invalid = true
      buffer.reshape = true
      if input.form != nil:
        let submitaction = submitForm(input.form, input)
        if submitaction.isSome:
          buffer.writeCommand(OPEN, submitaction.get)
    of INPUT_TEXT, INPUT_PASSWORD:
      input.value = s
      input.invalid = true
      buffer.reshape = true
    of INPUT_FILE:
      let cdir = parseUrl("file://" & getCurrentDir() & DirSep)
      let path = parseUrl(s, cdir)
      if path.issome:
        input.file = path
        input.invalid = true
        buffer.reshape = true
    else: discard
    buffer.input = nil

proc click(buffer: Buffer, cursorx, cursory: int) =
  let clickable = buffer.getCursorClickable(cursorx, cursory)
  if clickable != nil:
    case clickable.tagType
    of TAG_SELECT:
      set_focus clickable
    of TAG_A:
      restore_focus
      let url = parseUrl(HTMLAnchorElement(clickable).href, clickable.document.baseUrl.some)
      if url.issome:
        buffer.writeCommand(OPEN, newRequest(url.get, HTTP_GET))
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
          restore_focus
        else:
          # focus on select
          set_focus select
    of TAG_INPUT:
      restore_focus
      let input = HTMLInputElement(clickable)
      case input.inputType
      of INPUT_SEARCH:
        buffer.input = input
        buffer.writeCommand(READ_LINE, "SEARCH: ", input.value, false)
      of INPUT_TEXT, INPUT_PASSWORD:
        buffer.input = input
        buffer.writeCommand(READ_LINE, "TEXT: ", input.value, input.inputType == INPUT_PASSWORD)
      of INPUT_FILE:
        var path = if input.file.issome:
          input.file.get.path.serialize_unicode()
        else:
          ""
        buffer.writeCommand(READ_LINE, "Filename: ", path, false)
      of INPUT_CHECKBOX:
        input.checked = not input.checked
        input.invalid = true
        buffer.reshape = true
      of INPUT_RADIO:
        for radio in input.radiogroup:
          radio.checked = false
          radio.invalid = true
        input.checked = true
        input.invalid = true
        buffer.reshape = true
      of INPUT_RESET:
        if input.form != nil:
          input.form.reset()
          buffer.reshape = true
      of INPUT_SUBMIT, INPUT_BUTTON:
        if input.form != nil:
          let submitaction = submitForm(input.form, input)
          if submitaction.isSome:
            buffer.writeCommand(OPEN, submitaction.get)
      else:
        restore_focus
    else:
      restore_focus

proc readCommand(buffer: Buffer) =
  let istream = buffer.pistream
  let ostream = buffer.postream
  var cmd: BufferCommand
  istream.sread(cmd)
  case cmd
  of LOAD:
    let code = buffer.setupSource()
    buffer.load()
    buffer.writeCommand(LOAD_DONE, code)
  of GOTO_ANCHOR:
    var anchor: string
    istream.sread(anchor)
    if buffer.document != nil and buffer.document.getElementById(anchor) != nil:
      buffer.writeCommand(ANCHOR_FOUND)
    else:
      buffer.writeCommand(ANCHOR_FAIL)
  of RENDER:
    buffer.render()
    buffer.gotoAnchor()
  of GET_LINES:
    var w: Slice[int]
    istream.sread(w)
    if w.b < 0 or w.b > buffer.lines.high:
      w.b = buffer.lines.high
    ostream.swrite(SET_LINES)
    ostream.swrite(buffer.lines.len)
    ostream.swrite(w)
    for y in w:
      ostream.swrite(buffer.lines[y])
    ostream.flush()
  of WINDOW_CHANGE:
    istream.sread(buffer.attrs)
    buffer.windowChange()
  of FIND_PREV_LINK:
    var cx, cy: int
    istream.sread(cx)
    istream.sread(cy)
    let pl = buffer.findPrevLink(cx, cy)
    buffer.writeCommand(JUMP, pl.x, pl.y, 0)
  of FIND_NEXT_LINK:
    var cx, cy: int
    istream.sread(cx)
    istream.sread(cy)
    let nl = buffer.findNextLink(cx, cy)
    buffer.writeCommand(JUMP, nl.x, nl.y, 0)
  of FIND_PREV_MATCH:
    var cx, cy: int
    var regex: Regex
    var wrap: bool
    istream.sread(cx)
    istream.sread(cy)
    istream.sread(regex)
    istream.sread(wrap)
    let match = buffer.findPrevMatch(regex, cx, cy, wrap)
    if match.success:
      buffer.writeCommand(JUMP, match.x, match.y, match.x + match.str.width() - 1)
  of FIND_NEXT_MATCH:
    var cx, cy: int
    var regex: Regex
    var wrap: bool
    istream.sread(cx)
    istream.sread(cy)
    istream.sread(regex)
    istream.sread(wrap)
    let match = buffer.findNextMatch(regex, cx, cy, wrap)
    if match.success:
      buffer.writeCommand(JUMP, match.x, match.y, match.x + match.str.width() - 1)
  of READ_SUCCESS:
    var s: string
    istream.sread(s)
    buffer.lineInput(s)
  of READ_CANCELED:
    buffer.input = nil
  of CLICK:
    var cx, cy: int
    istream.sread(cx)
    istream.sread(cy)
    buffer.click(cx, cy)
  of MOVE_CURSOR:
    var cx, cy: int
    istream.sread(cx)
    istream.sread(cy)
    buffer.updateHover(cx, cy)
  of GET_SOURCE:
    let ssock = initServerSocket()
    buffer.writeCommand(SOURCE_READY)
    let stream = ssock.acceptSocketStream()
    if not buffer.streamclosed:
      buffer.source = buffer.istream.readAll()
      buffer.streamclosed = true
    stream.write(buffer.source)
    stream.close()
    ssock.close()

proc runBuffer(buffer: Buffer, rfd: int) =
  block loop:
    while true:
      let events = buffer.selector.select(-1)
      for event in events:
        if Read in event.events:
          if event.fd == rfd:
            try:
              buffer.readCommand()
            except IOError:
              break loop
          else:
            buffer.load2()
        if Error in event.events:
          if event.fd == rfd:
            break loop
          elif event.fd == buffer.getFd():
            buffer.finishLoad()
      if buffer.reshape:
        buffer.reshape = false
        buffer.render()
        buffer.writeCommand(RESHAPE)
  buffer.pistream.close()
  buffer.postream.close()
  buffer.loader.quit()
  quit(0)

proc launchBuffer*(config: BufferConfig, source: BufferSource,
                   attrs: WindowAttributes, loader: FileLoader,
                   mainproc: Pid) =
  let buffer = new Buffer
  buffer.attrs = attrs
  buffer.windowChange()
  buffer.config = config
  buffer.loader = loader
  buffer.bsource = source
  buffer.selector = newSelector[int]()
  let sstream = connectSocketStream(mainproc, false)
  sstream.swrite(getpid())
  sstream.swrite(BUFFER_READY)
  sstream.flush()
  buffer.pistream = sstream
  buffer.postream = sstream
  let rfd = int(sstream.source.getFd())
  buffer.selector.registerHandle(rfd, {Read}, 0)
  buffer.runBuffer(rfd)
