import net
import options
import os
import streams
import tables
import unicode

when defined(posix):
  import posix

import buffer/buffer
import buffer/cell
import buffer/container
import config/config
import io/lineedit
import io/request
import io/term
import io/window
import ips/forkserver
import ips/socketstream
import js/javascript
import js/regex
import types/buffersource
import types/color
import types/dispatcher
import types/url
import utils/twtstr

type
  LineMode* = enum
    NO_LINEMODE, LOCATION, USERNAME, PASSWORD, COMMAND, BUFFER, SEARCH_F,
    SEARCH_B, ISEARCH_F, ISEARCH_B

  Pager* = ref object
    alerts: seq[string]
    commandMode*: bool
    container*: Container
    dispatcher*: Dispatcher
    lineedit*: Option[LineEdit]
    linemode*: LineMode
    username: string
    scommand*: string
    config: Config
    regex: Option[Regex]
    iregex: Option[Regex]
    reverseSearch: bool
    statusgrid*: FixedGrid
    tty: File
    procmap*: Table[Pid, Container]
    unreg*: seq[(Pid, SocketStream)]
    icpos: CursorPosition
    display: FixedGrid
    redraw*: bool
    term*: Terminal

iterator containers*(pager: Pager): Container =
  if pager.container != nil:
    var c = pager.container
    while c.parent != nil: c = c.parent
    var stack: seq[Container]
    stack.add(c)
    while stack.len > 0:
      yield stack.pop()
      for i in countdown(c.children.high, 0):
        stack.add(c.children[i])

proc setContainer*(pager: Pager, c: Container) =
  pager.container = c
  pager.redraw = true

proc cursorDown(pager: Pager) {.jsfunc.} = pager.container.cursorDown()
proc cursorUp(pager: Pager) {.jsfunc.} = pager.container.cursorUp()
proc cursorLeft(pager: Pager) {.jsfunc.} = pager.container.cursorLeft()
proc cursorRight(pager: Pager) {.jsfunc.} = pager.container.cursorRight()
proc cursorLineBegin(pager: Pager) {.jsfunc.} = pager.container.cursorLineBegin()
proc cursorLineEnd(pager: Pager) {.jsfunc.} = pager.container.cursorLineEnd()
proc cursorNextWord(pager: Pager) {.jsfunc.} = pager.container.cursorNextWord()
proc cursorPrevWord(pager: Pager) {.jsfunc.} = pager.container.cursorPrevWord()
proc cursorNextLink(pager: Pager) {.jsfunc.} = pager.container.cursorNextLink()
proc cursorPrevLink(pager: Pager) {.jsfunc.} = pager.container.cursorPrevLink()
proc pageUp(pager: Pager) {.jsfunc.} = pager.container.pageUp()
proc pageDown(pager: Pager) {.jsfunc.} = pager.container.pageDown()
proc pageRight(pager: Pager) {.jsfunc.} = pager.container.pageRight()
proc pageLeft(pager: Pager) {.jsfunc.} = pager.container.pageLeft()
proc halfPageDown(pager: Pager) {.jsfunc.} = pager.container.halfPageDown()
proc halfPageUp(pager: Pager) {.jsfunc.} = pager.container.halfPageUp()
proc cursorFirstLine(pager: Pager) {.jsfunc.} = pager.container.cursorFirstLine()
proc cursorLastLine(pager: Pager) {.jsfunc.} = pager.container.cursorLastLine()
proc cursorTop(pager: Pager) {.jsfunc.} = pager.container.cursorTop()
proc cursorMiddle(pager: Pager) {.jsfunc.} = pager.container.cursorMiddle()
proc cursorBottom(pager: Pager) {.jsfunc.} = pager.container.cursorBottom()
proc cursorLeftEdge(pager: Pager) {.jsfunc.} = pager.container.cursorLeftEdge()
proc cursorVertMiddle(pager: Pager) {.jsfunc.} = pager.container.cursorVertMiddle()
proc cursorRightEdge(pager: Pager) {.jsfunc.} = pager.container.cursorRightEdge()
proc centerLine(pager: Pager) {.jsfunc.} = pager.container.centerLine()
proc scrollDown(pager: Pager) {.jsfunc.} = pager.container.scrollDown()
proc scrollUp(pager: Pager) {.jsfunc.} = pager.container.scrollUp()
proc scrollLeft(pager: Pager) {.jsfunc.} = pager.container.scrollLeft()
proc scrollRight(pager: Pager) {.jsfunc.} = pager.container.scrollRight()
proc reshape(pager: Pager) {.jsfunc.} = pager.container.reshape()

proc searchNext(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      pager.container.cursorNextMatch(pager.regex.get, true)
    else:
      pager.container.cursorPrevMatch(pager.regex.get, true)

proc searchPrev(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      pager.container.cursorPrevMatch(pager.regex.get, true)
    else:
      pager.container.cursorNextMatch(pager.regex.get, true)

proc setLineEdit(pager: Pager, edit: LineEdit, mode: LineMode) =
  pager.lineedit = some(edit)
  pager.linemode = mode

proc clearLineEdit(pager: Pager) =
  pager.lineedit = none(LineEdit)

func attrs(pager: Pager): WindowAttributes = pager.term.attrs

proc searchForward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(readLine("/", pager.attrs.width, config = pager.config, tty = pager.tty), SEARCH_F)

proc searchBackward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(readLine("?", pager.attrs.width, config = pager.config, tty = pager.tty), SEARCH_B)

proc isearchForward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.setLineEdit(readLine("/", pager.attrs.width, config = pager.config, tty = pager.tty), ISEARCH_F)

proc isearchBackward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.setLineEdit(readLine("?", pager.attrs.width, config = pager.config, tty = pager.tty), ISEARCH_B)

proc newPager*(config: Config, attrs: WindowAttributes, dispatcher: Dispatcher): Pager =
  let pager = Pager(
    dispatcher: dispatcher,
    config: config,
    display: newFixedGrid(attrs.width, attrs.height - 1),
    statusgrid: newFixedGrid(attrs.width),
    term: newTerminal(stdout, config, attrs)
  )
  return pager

proc launchPager*(pager: Pager, tty: File) =
  pager.tty = tty
  if tty != nil:
    pager.term.start(tty)

proc dumpAlerts*(pager: Pager) =
  for msg in pager.alerts:
    eprint msg

proc quit*(pager: Pager, code = 0) =
  pager.term.quit()
  pager.dumpAlerts()

proc clearDisplay(pager: Pager) =
  pager.display = newFixedGrid(pager.display.width, pager.display.height)

proc buffer(pager: Pager): Container {.jsfget, inline.} = pager.container

proc refreshDisplay(pager: Pager, container = pager.container) =
  var r: Rune
  var by = 0
  pager.clearDisplay()
  var hlformat = newFormat()
  hlformat.bgcolor = CellColor(rgb: true, rgbcolor: pager.config.hlcolor)
  for line in container.ilines(container.fromy ..< min(container.fromy + pager.display.height, container.numLines)):
    var w = 0 # width of the row so far
    var i = 0 # byte in line.str
    # Skip cells till fromx.
    while w < container.fromx and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.width()
    let dls = by * pager.display.width # starting position of row in display
    # Fill in the gap in case we skipped more cells than fromx mandates (i.e.
    # we encountered a double-width character.)
    var k = 0
    if w > container.fromx:
      while k < w - container.fromx:
        pager.display[dls + k].str &= ' '
        inc k
    var cf = line.findFormat(w)
    var nf = line.findNextFormat(w)
    let startw = w # save this for later
    var lan = ""
    # Now fill in the visible part of the row.
    while i < line.str.len:
      let pw = w
      fastRuneAt(line.str, i, r)
      w += r.width()
      if w > container.fromx + pager.display.width:
        break # die on exceeding the width limit
      if nf.pos != -1 and nf.pos <= pw:
        cf = nf
        nf = line.findNextFormat(pw)
      pager.display[dls + k].str &= r
      lan &= r
      if cf.pos != -1:
        pager.display[dls + k].format = cf.format
      let tk = k + r.width()
      while k < tk and k < pager.display.width - 1:
        inc k
    # Finally, override cell formatting for highlighted cells.
    let hls = container.findHighlights(container.fromy + by)
    let aw = container.width - (startw - container.fromx) # actual width
    for hl in hls:
      let area = hl.colorArea(container.fromy + by, startw .. startw + aw)
      for i in area:
        pager.display[dls + i - startw].format = hlformat
    inc by

proc clearStatusMessage(pager: Pager) =
  pager.statusgrid = newFixedGrid(pager.statusgrid.width)

proc writeStatusMessage(pager: Pager, str: string, format: Format = Format()) =
  pager.clearStatusMessage()
  var i = 0
  for r in str.runes:
    i += r.width()
    if i >= pager.statusgrid.len:
      pager.statusgrid[^1].str = "$"
      break
    pager.statusgrid[i].str &= r
    pager.statusgrid[i].format = format

proc refreshStatusMsg*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  if container.loadinfo != "":
    pager.writeStatusMessage(container.loadinfo)
  elif pager.alerts.len > 0:
    pager.writeStatusMessage(pager.alerts[0])
    pager.alerts.delete(0)
  else:
    var msg = $(container.cursory + 1) & "/" & $container.numLines & " (" &
              $container.atPercentOf() & "%) " & "<" & container.getTitle() & ">"
    if container.hovertext.len > 0:
      msg &= " " & container.hovertext
    var format: Format
    format.reverse = true
    pager.writeStatusMessage(msg, format)

proc drawBuffer*(pager: Pager, container: Container, ostream: Stream) =
  var format = newFormat()
  for line in container.readLines:
    if line.formats.len == 0:
      ostream.write(line.str & "\n")
    else:
      var x = 0
      var i = 0
      var s = ""
      for f in line.formats:
        var outstr = ""
        #assert f.pos < line.str.width(), "fpos " & $f.pos & "\nstr" & line.str & "\n"
        while x < f.pos:
          var r: Rune
          fastRuneAt(line.str, i, r)
          outstr &= r
          x += r.width()
        s &= outstr
        s &= pager.term.processFormat(format, f.format)
      s &= line.str.substr(i) & pager.term.processFormat(format, newFormat()) & "\n"
      ostream.write(s)
  ostream.flush()

proc redraw(pager: Pager) {.jsfunc.} =
  pager.redraw = true

proc draw*(pager: Pager) =
  pager.term.hideCursor()
  if pager.redraw or pager.container != nil and pager.container.redraw:
    pager.refreshDisplay()
    pager.term.writeGrid(pager.display)
  if pager.lineedit.isSome:
    pager.term.writeGrid(pager.lineedit.get.generateOutput(), 0, pager.attrs.height - 1)
  else:
    pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)
  pager.term.outputGrid()
  if pager.lineedit.isSome:
    pager.term.setCursor(pager.lineedit.get.getCursorX(), pager.container.attrs.height - 1)
  else:
    pager.term.setCursor(pager.container.acursorx, pager.container.acursory)
  pager.term.showCursor()
  pager.term.flush()
  pager.redraw = false
  pager.container.redraw = false

proc registerContainer*(pager: Pager, container: Container) =
  pager.procmap[container.process] = container

proc addContainer*(pager: Pager, container: Container) =
  container.parent = pager.container
  if pager.container != nil:
    pager.container.children.add(container)
  pager.registerContainer(container)
  pager.setContainer(container)

proc dupeContainer(pager: Pager, container: Container, location: Option[URL]): Container =
  return pager.dispatcher.dupeBuffer(container, pager.config, location)

proc dupeBuffer*(pager: Pager, location = none(URL)) {.jsfunc.} =
  pager.addContainer(pager.dupeContainer(pager.container, location))

# The prevBuffer and nextBuffer procedures emulate w3m's PREV and NEXT
# commands by traversing the container tree in a depth-first order.
proc prevBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  let n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n > 0:
    pager.setContainer(pager.container.parent.children[n - 1])
  else:
    pager.setContainer(pager.container.parent)
  return true

proc nextBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.children.len > 0:
    pager.setContainer(pager.container.children[0])
    return true
  if pager.container.parent == nil:
    return false
  let n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n < pager.container.parent.children.high:
    pager.setContainer(pager.container.parent.children[n + 1])
    return true
  return false

proc alert*(pager: Pager, msg: string) {.jsfunc.} =
  pager.alerts.add(msg)

proc lineInfo(pager: Pager) {.jsfunc.} =
  pager.alert(pager.container.lineInfo())

proc deleteContainer(pager: Pager, container: Container) =
  if container.parent == nil and
      container.children.len == 0 and
      container != pager.container:
    return
  if container.sourcepair != nil:
    container.sourcepair.sourcepair = nil
    container.sourcepair = nil
  if container.parent != nil:
    let parent = container.parent
    let n = parent.children.find(container)
    assert n != -1, "Container not a child of its parent"
    for i in countdown(container.children.high, 0):
      let child = container.children[i]
      child.parent = container.parent
      parent.children.insert(child, n + 1)
    parent.children.delete(n)
    if container == pager.container:
      pager.setContainer(parent)
  elif container.children.len > 0:
    let parent = container.children[0]
    parent.parent = nil
    for i in 1..container.children.high:
      container.children[i].parent = parent
      parent.children.add(container.children[i])
    if container == pager.container:
      pager.setContainer(parent)
  else:
    for child in container.children:
      child.parent = nil
    if container == pager.container:
      pager.setContainer(nil)
  container.parent = nil
  container.children.setLen(0)
  pager.unreg.add((container.process, SocketStream(container.istream)))
  pager.dispatcher.forkserver.removeChild(container.process)

proc discardBuffer*(pager: Pager) {.jsfunc.} =
  if pager.container == nil or pager.container.parent == nil and
      pager.container.children.len == 0:
    pager.alert("Cannot discard last buffer!")
  else:
    pager.deleteContainer(pager.container)

proc toggleSource*(pager: Pager) {.jsfunc.} =
  if pager.container.sourcepair != nil:
    pager.setContainer(pager.container.sourcepair)
  else:
    let contenttype = if pager.container.contenttype.get("") == "text/html":
      some("text/plain")
    else:
      some("text/html")
    let container = pager.dispatcher.dupeBuffer(pager.container, pager.config, contenttype = contenttype)
    container.sourcepair = pager.container
    pager.container.sourcepair = container
    pager.addContainer(container)

proc windowChange*(pager: Pager, attrs: WindowAttributes) =
  pager.term.windowChange(attrs)
  pager.display = newFixedGrid(attrs.width, attrs.height - 1)
  pager.statusgrid = newFixedGrid(attrs.width)
  for container in pager.containers:
    container.windowChange(attrs)

# Load request in a new buffer.
proc gotoURL*(pager: Pager, request: Request, prevurl = none(URL), ctype = none(string), replace: Container = nil) =
  if prevurl.isnone or not prevurl.get.equals(request.url, true) or
      request.url.hash == "" or request.httpmethod != HTTP_GET:
    # Basically, we want to reload the page *only* when
    # a) we force a reload (by setting prevurl to none)
    # b) or the new URL isn't just the old URL + an anchor
    # I think this makes navigation pretty natural, or at least very close to
    # what other browsers do. Still, it would be nice if we got some visual
    # feedback on what is actually going to happen when typing a URL; TODO.
    let source = BufferSource(
      t: LOAD_REQUEST,
      request: request,
      contenttype: ctype,
      location: request.url
    )
    let container = pager.dispatcher.newBuffer(pager.config, source)
    container.replace = replace
    pager.addContainer(container)
  else:
    pager.container.redirect = some(request.url)
    pager.container.gotoAnchor(request.url.anchor)

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
# (TODO: make this optional)
proc loadURL*(pager: Pager, url: string, ctype = none(string)) =
  let firstparse = parseURL(url)
  if firstparse.issome:
    let prev = if pager.container != nil:
      some(pager.container.source.location)
    else:
      none(URL)
    pager.gotoURL(newRequest(firstparse.get), prev, ctype)
    return
  var urls: seq[URL]
  let pageurl = parseURL("https://" & url)
  if pageurl.isSome: # attempt to load remote page
    urls.add(pageurl.get)
  let cdir = parseURL("file://" & getCurrentDir() & DirSep)
  let purl = percentEncode(url, LocalPathPercentEncodeSet)
  if purl != url:
    let newurl = parseURL(purl, cdir)
    if newurl.isSome:
      urls.add(newurl.get)
  let localurl = parseURL(url, cdir)
  if localurl.isSome: # attempt to load local file
    urls.add(localurl.get)
  if urls.len == 0:
    pager.alert("Invalid URL " & url)
  else:
    let prevc = pager.container
    pager.gotoURL(newRequest(urls.pop()), ctype = ctype)
    if pager.container != prevc:
      pager.container.retry = urls

proc readPipe0*(pager: Pager, ctype: Option[string], fd: FileHandle, location: Option[URL], title: string): Container =
  let source = BufferSource(
    t: LOAD_PIPE,
    fd: fd,
    contenttype: some(ctype.get("text/plain")),
    location: location.get(newURL("file://-"))
  )
  let container = pager.dispatcher.newBuffer(pager.config, source, title)
  return container

proc readPipe*(pager: Pager, ctype: Option[string], fd: FileHandle) =
  let container = pager.readPipe0(ctype, fd, none(URL), "*pipe*")
  pager.addContainer(container)

proc command(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(readLine("COMMAND: ", pager.attrs.width, config = pager.config, tty = pager.tty), COMMAND)

proc commandMode(pager: Pager) {.jsfunc.} =
  pager.commandmode = true
  pager.command()

proc updateReadLineISearch(pager: Pager, linemode: LineMode) =
  let lineedit = pager.lineedit.get
  case lineedit.state
  of CANCEL:
    pager.iregex = none(Regex)
    pager.container.popCursorPos()
    pager.container.clearSearchHighlights()
  of EDIT:
    let x = $lineedit.news
    if x != "": pager.iregex = compileSearchRegex(x)
    pager.container.popCursorPos(true)
    if pager.iregex.isSome:
      if linemode == ISEARCH_F:
        pager.container.cursorNextMatch(pager.iregex.get, true)
      else:
        pager.container.cursorPrevMatch(pager.iregex.get, true)
      pager.container.hlon = true
    if not pager.container.redraw:
      #TODO this is dumb
      pager.container.requestLines()
    pager.container.pushCursorPos()
    pager.redraw = true
  of FINISH:
    if pager.iregex.isSome:
      pager.regex = pager.iregex
    pager.reverseSearch = linemode == ISEARCH_B
    pager.container.clearSearchHighlights()
    pager.redraw = true

proc updateReadLine*(pager: Pager) =
  let lineedit = pager.lineedit.get
  template s: string = $lineedit.news
  if pager.linemode in {ISEARCH_F, ISEARCH_B}:
    pager.updateReadLineISearch(pager.linemode)
  else:
    case lineedit.state
    of EDIT: return
    of FINISH:
      case pager.linemode
      of LOCATION: pager.loadURL(s)
      of USERNAME:
        pager.username = s
        pager.setLineEdit(readLine("Password: ", pager.attrs.width, hide = true, config = pager.config, tty = pager.tty), PASSWORD)
      of PASSWORD:
        let url = newURL(pager.container.source.location)
        url.username = pager.username
        url.password = s
        pager.username = ""
        pager.gotoURL(newRequest(url), some(pager.container.source.location), replace = pager.container)
      of COMMAND:
        pager.scommand = s
        if pager.commandmode:
          pager.command()
      of BUFFER: pager.container.readSuccess(s)
      of SEARCH_F:
        let x = s
        if x != "": pager.regex = compileSearchRegex(x)
        pager.reverseSearch = false
        pager.searchNext()
      of SEARCH_B:
        let x = s
        if x != "": pager.regex = compileSearchRegex(x)
        pager.reverseSearch = true
        pager.searchPrev()
      else: discard
    of CANCEL:
      case pager.linemode
      of USERNAME: pager.discardBuffer()
      of PASSWORD:
        pager.username = ""
        pager.discardBuffer()
      of BUFFER: pager.container.readCanceled()
      of COMMAND: pager.commandmode = false
      else: discard
  if lineedit.state in {CANCEL, FINISH}:
    if pager.lineedit.get == lineedit:
      pager.clearLineEdit()

# Open a URL prompt and visit the specified URL.
proc changeLocation(pager: Pager) {.jsfunc.} =
  var url = pager.container.source.location.serialize()
  pager.setLineEdit(readLine("URL: ", pager.attrs.width, current = url, config = pager.config, tty = pager.tty), LOCATION)

# Reload the page in a new buffer, then kill the previous buffer.
proc reload(pager: Pager) {.jsfunc.} =
  pager.gotoURL(newRequest(pager.container.source.location), none(URL), pager.container.contenttype, pager.container)

proc click(pager: Pager) {.jsfunc.} =
  pager.container.click()

proc authorize*(pager: Pager) =
  pager.setLineEdit(readLine("Username: ", pager.attrs.width, config = pager.config, tty = pager.tty), USERNAME)

proc handleEvent*(pager: Pager, container: Container): bool =
  let event = container.handleEvent()
  case event.t
  of FAIL:
    pager.deleteContainer(container)
    if container.retry.len > 0:
      pager.gotoURL(newRequest(container.retry.pop()), ctype = container.contenttype)
    else:
      pager.alert("Couldn't load " & $container.source.location & " (error code " & $container.code & ")")
    if pager.container == nil:
      return false
  of SUCCESS:
    container.reshape()
    pager.container.loadinfo = ""
    if container.replace != nil:
      container.children.add(container.replace.children)
      for child in container.children:
        child.parent = container
      container.replace.children.setLen(0)
      if container.replace.parent != nil:
        container.parent = container.replace.parent
        let n = container.replace.parent.children.find(container.replace)
        assert n != -1, "Container not a child of its parent"
        container.parent.children[n] = container
      if pager.container == container.replace:
        pager.setContainer(container)
  of NEEDS_AUTH:
    if pager.container == container:
      pager.authorize()
  of REDIRECT:
    let redirect = container.redirect.get
    pager.alert("Redirecting to " & $redirect)
    pager.gotoURL(newRequest(redirect), some(pager.container.source.location), replace = pager.container)
  of ANCHOR:
    pager.addContainer(pager.dupeContainer(container, container.redirect))
  of NO_ANCHOR:
    pager.alert("Couldn't find anchor " & container.redirect.get.anchor)
  of UPDATE:
    if container == pager.container:
      pager.redraw = true
  of READ_LINE:
    if container == pager.container:
      pager.setLineEdit(readLine(event.prompt, pager.attrs.width, current = event.value, hide = event.password, config = pager.config, tty = pager.tty), BUFFER)
  of OPEN:
    pager.gotoURL(event.request, some(container.source.location))
  of INVALID_COMMAND: discard
  of STATUS:
    if pager.container == container:
      pager.refreshStatusMsg()
  of NO_EVENT: discard
  return true

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
