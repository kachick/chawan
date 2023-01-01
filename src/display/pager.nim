import deques
import net
import options
import os
import streams
import tables
import unicode

when defined(posix):
  import posix

import buffer/cell
import buffer/container
import config/config
import display/term
import io/lineedit
import io/request
import io/window
import ips/editor
import ips/forkserver
import ips/socketstream
import js/javascript
import js/regex
import types/buffersource
import types/color
import types/cookie
import types/dispatcher
import types/url
import utils/twtstr

type
  LineMode* = enum
    NO_LINEMODE, LOCATION, USERNAME, PASSWORD, COMMAND, BUFFER, SEARCH_F,
    SEARCH_B, ISEARCH_F, ISEARCH_B, GOTO_LINE

  Pager* = ref object
    jsctx: JSContext
    numload*: int
    alerts: seq[string]
    alerton: bool
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
    linehist: array[LineMode, LineHistory]
    siteconf: seq[SiteConfig]
    omnirules: seq[OmniRule]
    cookiejars: Table[string, CookieJar]

func attrs(pager: Pager): WindowAttributes = pager.term.attrs

func getRoot(container: Container): Container =
  var c = container
  while c.parent != nil: c = c.parent
  return c

iterator all_children(parent: Container): Container {.inline.} =
  var stack = newSeqOfCap[Container](parent.children.len)
  for i in countdown(parent.children.high, 0):
    stack.add(parent.children[i])
  while stack.len > 0:
    let c = stack.pop()
    yield c
    for i in countdown(c.children.high, 0):
      stack.add(c.children[i])

iterator containers*(pager: Pager): Container {.inline.} =
  if pager.container != nil:
    let root = getRoot(pager.container)
    yield root
    for c in root.all_children:
      yield c

proc setContainer*(pager: Pager, c: Container) {.jsfunc.} =
  pager.container = c
  pager.redraw = true

proc hasprop(pager: Pager, s: string): bool {.jshasprop.} =
  if pager.container != nil:
    let cval = toJS(pager.jsctx, pager.container)
    let val = JS_GetPropertyStr(pager.jsctx, cval, s)
    if val != JS_UNDEFINED:
      result = true
    JS_FreeValue(pager.jsctx, val)

proc reflect(ctx: JSContext, this_val: JSValue, argc: cint, argv: ptr JSValue,
             magic: cint, func_data: ptr JSValue): JSValue {.cdecl.} =
  let fun = cast[ptr JSValue](cast[int](func_data) + sizeof(JSValue))[]
  return JS_Call(ctx, fun, func_data[], argc, argv)

proc getter(pager: Pager, s: string): Option[JSValue] {.jsgetprop.} =
  if pager.container != nil:
    let cval = toJS(pager.jsctx, pager.container)
    let val = JS_GetPropertyStr(pager.jsctx, cval, s)
    if val != JS_UNDEFINED:
      if JS_IsFunction(pager.jsctx, val):
        var func_data = @[cval, val]
        let fun = JS_NewCFunctionData(pager.jsctx, reflect, 1, 0, 2, addr func_data[0])
        return some(fun)
      return some(val)

proc searchNext(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      pager.container.cursorNextMatch(pager.regex.get, pager.config.searchwrap)
    else:
      pager.container.cursorPrevMatch(pager.regex.get, pager.config.searchwrap)

proc searchPrev(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      pager.container.cursorPrevMatch(pager.regex.get, pager.config.searchwrap)
    else:
      pager.container.cursorNextMatch(pager.regex.get, pager.config.searchwrap)

proc getLineHist(pager: Pager, mode: LineMode): LineHistory =
  if pager.linehist[mode] == nil:
    pager.linehist[mode] = newLineHistory()
  return pager.linehist[mode]

proc setLineEdit(pager: Pager, prompt: string, mode: LineMode, current = "", hide = false) =
  pager.lineedit = some(readLine(prompt, pager.attrs.width, current = current, term = pager.term, hide = hide, hist = pager.getLineHist(mode)))
  pager.linemode = mode

proc clearLineEdit(pager: Pager) =
  pager.lineedit = none(LineEdit)

proc searchForward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("/", SEARCH_F)

proc searchBackward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("?", SEARCH_B)

proc isearchForward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.setLineEdit("/", ISEARCH_F)

proc isearchBackward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.setLineEdit("?", ISEARCH_B)

proc gotoLine[T: string|int](pager: Pager, s: T = "") {.jsfunc.} =
  when s is string:
    if s == "":
      pager.setLineEdit("Goto line: ", GOTO_LINE)
      return
  pager.container.gotoLine(s)

proc newPager*(config: Config, attrs: WindowAttributes, dispatcher: Dispatcher, ctx: JSContext): Pager =
  let pager = Pager(
    dispatcher: dispatcher,
    config: config,
    display: newFixedGrid(attrs.width, attrs.height - 1),
    statusgrid: newFixedGrid(attrs.width),
    term: newTerminal(stdout, config, attrs),
    jsctx: ctx,
    siteconf: config.getSiteConfig(ctx),
    omnirules: config.getOmniRules(ctx)
  )
  return pager

proc launchPager*(pager: Pager, tty: File) =
  pager.tty = tty
  pager.term.start(tty)

proc dumpAlerts*(pager: Pager) =
  for msg in pager.alerts:
    eprint "cha: " & msg

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
  for line in container.ilines(container.fromy ..< min(container.fromy + pager.display.height, container.numLines)):
    var w = 0 # width of the row so far
    var i = 0 # byte in line.str
    # Skip cells till fromx.
    while w < container.fromx and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.twidth(w)
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
      let rw = r.twidth(w)
      w += rw
      if w > container.fromx + pager.display.width:
        break # die on exceeding the width limit
      if nf.pos != -1 and nf.pos <= pw:
        cf = nf
        nf = line.findNextFormat(pw)
      pager.display[dls + k].str &= r
      lan &= r
      if cf.pos != -1:
        pager.display[dls + k].format = cf.format
      let tk = k + rw
      while k < tk and k < pager.display.width - 1:
        inc k
    # Finally, override cell formatting for highlighted cells.
    let hls = container.findHighlights(container.fromy + by)
    let aw = container.width - (startw - container.fromx) # actual width
    for hl in hls:
      let area = hl.colorArea(container.fromy + by, startw .. startw + aw)
      for i in area:
        var hlformat = pager.display[dls + i - startw].format
        hlformat.bgcolor = pager.config.hlcolor.cellColor()
        pager.display[dls + i - startw].format = hlformat
    inc by

proc clearStatusMessage(pager: Pager) =
  pager.statusgrid = newFixedGrid(pager.statusgrid.width)

proc writeStatusMessage(pager: Pager, str: string, format: Format = newFormat()) =
  pager.clearStatusMessage()
  var i = 0
  for r in str.runes:
    if i >= pager.statusgrid.len:
      pager.statusgrid[^1].str = "$"
      break
    if r.isControlChar() or r == Rune('\n'):
      pager.statusgrid[i].str &= "^"
      pager.statusgrid[i].str &= getControlLetter(char(r))
    else:
      pager.statusgrid[i].str &= r
    pager.statusgrid[i].format = format
    i += r.twidth(i)

proc refreshStatusMsg*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  if pager.tty == nil: return
  if container.loadinfo != "":
    pager.alerton = false
    pager.writeStatusMessage(container.loadinfo)
  elif pager.alerts.len > 0:
    pager.alerton = true
    pager.writeStatusMessage(pager.alerts[0])
    pager.alerts.delete(0)
  else:
    pager.alerton = false
    container.clearHover()
    var msg = $(container.cursory + 1) & "/" & $container.numLines & " (" &
              $container.atPercentOf() & "%)"
    let mw = msg.width()
    let t = container.getTitle()
    let tt = " <" & t & ">"
    let tw = tt.width()
    let ht = container.getHoverText()
    if ht.len == 0: # hover text is empty.
      msg &= tt
    else:
      let h = " " & ht
      let hw = h.width()
      if mw + tw + hw < pager.statusgrid.width:
        msg &= tt
      elif mw + hw + 3 < pager.statusgrid.width:
        # squeezing the title would mean we still have some space for it.
        var t2 = " <"
        var w = mw + hw + 2 # t2 has a width of 2
        for r in t.runes:
          if w >= pager.statusgrid.width - 1: # ends with another >
            t2 &= ">"
            break
          t2 &= r
          w += r.width()
        msg &= t2
      msg &= h
    var format = newFormat()
    format.reverse = true
    pager.writeStatusMessage(msg, format)

# Call refreshStatusMsg if no alert is being displayed on the screen.
proc showAlerts*(pager: Pager) =
  if not pager.alerton:
    pager.refreshStatusMsg()

proc drawBuffer*(pager: Pager, container: Container, ostream: Stream) =
  var format = newFormat()
  container.readLines(proc(line: SimpleFlexibleLine) =
    if line.formats.len == 0:
      ostream.write(line.str & "\n")
    else:
      var x = 0
      var i = 0
      var s = ""
      for f in line.formats:
        var outstr = ""
        while x < f.pos:
          var r: Rune
          fastRuneAt(line.str, i, r)
          outstr &= r
          x += r.width()
        s &= outstr
        s &= pager.term.processFormat(format, f.format)
      s &= line.str.substr(i) & pager.term.processFormat(format, newFormat()) & "\n"
      ostream.write(s))
  ostream.flush()

proc redraw(pager: Pager) {.jsfunc.} =
  pager.redraw = true
  pager.term.clearCanvas()

proc draw*(pager: Pager) =
  if pager.container == nil: return
  pager.term.hideCursor()
  if pager.redraw:
    pager.refreshDisplay()
    pager.term.writeGrid(pager.display)
  if pager.lineedit.isSome:
    pager.term.writeGrid(pager.lineedit.get.generateOutput(), 0, pager.attrs.height - 1)
  else:
    pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)
  pager.term.outputGrid()
  if pager.lineedit.isSome:
    pager.term.setCursor(pager.lineedit.get.getCursorX(), pager.attrs.height - 1)
  else:
    pager.term.setCursor(pager.container.acursorx, pager.container.acursory)
  pager.term.showCursor()
  pager.term.flush()
  pager.redraw = false

proc registerContainer*(pager: Pager, container: Container) =
  pager.procmap[container.process] = container

proc addContainer*(pager: Pager, container: Container) =
  container.parent = pager.container
  if pager.container != nil:
    pager.container.children.insert(container, 0)
  pager.registerContainer(container)
  pager.setContainer(container)

proc dupeContainer(pager: Pager, container: Container, location: Option[URL]): Container =
  return pager.dispatcher.dupeBuffer(container, pager.config, location)

proc dupeBuffer*(pager: Pager, location = none(URL)) {.jsfunc.} =
  pager.addContainer(pager.dupeContainer(pager.container, location))

# The prevBuffer and nextBuffer procedures emulate w3m's PREV and NEXT
# commands by traversing the container tree in a depth-first order.
proc prevBuffer(pager: Pager): bool {.jsfunc.} =
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

proc nextBuffer(pager: Pager): bool {.jsfunc.} =
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

proc parentBuffer(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  pager.setContainer(pager.container.parent)
  return true

proc prevSiblingBuffer(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  var n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n == 0:
    n = pager.container.parent.children.len
  pager.setContainer(pager.container.parent.children[n - 1])
  return true

proc nextSiblingBuffer(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  var n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n == pager.container.parent.children.high:
    n = -1
  pager.setContainer(pager.container.parent.children[n + 1])
  return true

proc alert*(pager: Pager, msg: string) {.jsfunc.} =
  pager.alerts.add(msg)

proc deleteContainer(pager: Pager, container: Container) =
  container.cancel()
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
      if n == 0:
        pager.setContainer(parent)
      else:
        pager.setContainer(parent.children[n - 1])
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
  pager.unreg.add((container.process, SocketStream(container.iface.stream)))
  pager.dispatcher.forkserver.removeChild(container.process)

proc discardBuffer(pager: Pager, container = none(Container)) {.jsfunc.} =
  let c = container.get(pager.container)
  if c == nil or c.parent == nil and c.children.len == 0:
    pager.alert("Cannot discard last buffer!")
  else:
    pager.deleteContainer(c)

proc discardTree(pager: Pager, container = none(Container)) {.jsfunc.} =
  let container = container.get(pager.container)
  if container != nil:
    for c in container.all_children:
      pager.deleteContainer(c)
  else:
    pager.alert("Buffer has no children!")

proc toggleSource(pager: Pager) {.jsfunc.} =
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
  pager.refreshStatusMsg()

proc applySiteconf(pager: Pager, request: Request): BufferConfig =
  let url = $request.url
  let host = request.url.host
  var refererfrom: bool
  var cookiejar: CookieJar
  var headers: HeaderList
  var scripting: bool
  for sc in pager.siteconf:
    if sc.url.isSome and not sc.url.get.match(url):
      continue
    elif sc.host.isSome and not sc.host.get.match(host):
      continue
    if sc.subst != nil:
      let s = sc.subst(request.url)
      if s.isSome and s.get != nil:
        request.url = s.get
    if sc.cookie.isSome:
      if sc.cookie.get:
        # host/url might have changed by now
        let jarid = sc.sharecookiejar.get(request.url.host)
        if jarid notin pager.cookiejars:
          pager.cookiejars[jarid] = newCookieJar(request.url, sc.thirdpartycookie)
        cookiejar = pager.cookiejars[jarid]
      else:
        cookiejar = nil # override
    if sc.scripting.isSome:
      scripting = sc.scripting.get
    if sc.refererfrom.isSome:
      refererfrom = sc.refererfrom.get
  return pager.config.getBufferConfig(request.url, cookiejar, headers, refererfrom, scripting)

# Load request in a new buffer.
proc gotoURL(pager: Pager, request: Request, prevurl = none(URL),
              ctype = none(string), replace: Container = nil,
              redirectdepth = 0, referrer: Container = nil) =
  if referrer != nil and referrer.config.refererfrom:
    request.referer = referrer.source.location
  var bufferconfig = pager.applySiteconf(request)
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
    if referrer != nil:
      bufferconfig.referrerpolicy = referrer.config.referrerpolicy
    let container = pager.dispatcher.newBuffer(bufferconfig, source, redirectdepth = redirectdepth)
    if replace != nil:
      container.replace = replace
      container.copyCursorPos(container.replace)
    pager.addContainer(container)
    inc pager.numload
  else:
    pager.container.findAnchor(request.url.anchor)

proc omniRewrite(pager: Pager, s: string): string =
  for rule in pager.omnirules:
    if rule.match.match(s):
      let sub = rule.subst(s)
      if sub.isSome:
        return sub.get
      else:
        pager.alert("Error in substitution of rule " & rule.match.buf & " for " & s)
  return s

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
proc loadURL*(pager: Pager, url: string, ctype = none(string)) =
  let url0 = pager.omniRewrite(url)
  let url = if url[0] == '~': expandPath(url0) else: url0
  let firstparse = parseURL(url)
  if firstparse.issome:
    let prev = if pager.container != nil:
      some(pager.container.source.location)
    else:
      none(URL)
    pager.gotoURL(newRequest(firstparse.get), prev, ctype)
    return
  var urls: seq[URL]
  if pager.config.prependhttps and url[0] != '/':
    let pageurl = parseURL("https://" & url)
    if pageurl.isSome: # attempt to load remote page
      urls.add(pageurl.get)
  let cdir = parseURL("file://" & percentEncode(getCurrentDir(), LocalPathPercentEncodeSet) & DirSep)
  let localurl = percentEncode(url, LocalPathPercentEncodeSet)
  let newurl = parseURL(localurl, cdir)
  if newurl.isSome:
    urls.add(newurl.get) # attempt to load local file
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
  let bufferconfig = pager.config.getBufferConfig(source.location)
  return pager.dispatcher.newBuffer(bufferconfig, source, title = title)

proc readPipe*(pager: Pager, ctype: Option[string], fd: FileHandle) =
  let container = pager.readPipe0(ctype, fd, none(URL), "*pipe*")
  pager.addContainer(container)

proc command(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("COMMAND: ", COMMAND)

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
      pager.container.hlon = true
      if linemode == ISEARCH_F:
        pager.container.cursorNextMatch(pager.iregex.get, pager.config.searchwrap)
      else:
        pager.container.cursorPrevMatch(pager.iregex.get, pager.config.searchwrap)
    pager.container.pushCursorPos()
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
        pager.setLineEdit("Password: ", PASSWORD, hide = true)
      of PASSWORD:
        let url = newURL(pager.container.source.location)
        url.username = pager.username
        url.password = s
        pager.username = ""
        pager.gotoURL(newRequest(url), some(pager.container.source.location), replace = pager.container, referrer = pager.container)
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
        pager.searchNext()
      of GOTO_LINE:
        pager.container.gotoLine(s)
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
proc load(pager: Pager, s = "") {.jsfunc.} =
  if s.len > 0 and s[^1] == '\n':
    pager.loadURL(s[0..^2])
  else:
    var url = s
    if url == "":
      url = pager.container.source.location.serialize()
    pager.setLineEdit("URL: ", LOCATION, url)

# Reload the page in a new buffer, then kill the previous buffer.
proc reload(pager: Pager) {.jsfunc.} =
  pager.gotoURL(newRequest(pager.container.source.location), none(URL), pager.container.contenttype, pager.container)

proc authorize(pager: Pager) =
  pager.setLineEdit("Username: ", USERNAME)

proc handleEvent0(pager: Pager, container: Container, event: ContainerEvent): bool =
  case event.t
  of FAIL:
    dec pager.numload
    pager.deleteContainer(container)
    if container.retry.len > 0:
      pager.gotoURL(newRequest(container.retry.pop()), ctype = container.contenttype)
    else:
      pager.alert("Can't load " & $container.source.location & " (error code " & $container.code & ")")
    if pager.container == nil:
      return false
  of SUCCESS:
    if container.replace != nil:
      let n = container.replace.children.find(container)
      if n != -1:
        container.replace.children.delete(n)
        container.parent = nil
      container.children.add(container.replace.children)
      for child in container.children:
        child.parent = container
      container.replace.children.setLen(0)
      if container.replace.parent != nil:
        container.parent = container.replace.parent
        let n = container.replace.parent.children.find(container.replace)
        assert n != -1, "Container not a child of its parent"
        container.parent.children[n] = container
        container.replace.parent = nil
      if pager.container == container.replace:
        pager.setContainer(container)
      pager.deleteContainer(container.replace)
      container.replace = nil
  of LOADED:
    dec pager.numload
  of NEEDS_AUTH:
    if pager.container == container:
      pager.authorize()
  of REDIRECT:
    if container.redirectdepth < pager.config.maxredirect:
      pager.alert("Redirecting to " & $event.request.url)
      pager.gotoURL(event.request, some(container.source.location),
        replace = container, redirectdepth = container.redirectdepth + 1,
        referrer = pager.container)
    else:
      pager.alert("Error: maximum redirection depth reached")
      pager.deleteContainer(container)
      if pager.container == nil:
        return false
  of ANCHOR:
    var url2 = newURL(container.source.location)
    url2.hash(event.anchor)
    pager.addContainer(pager.dupeContainer(container, some(url2)))
  of NO_ANCHOR:
    pager.alert("Couldn't find anchor " & event.anchor)
  of UPDATE:
    if container == pager.container:
      pager.redraw = true
      if event.force: pager.term.clearCanvas()
  of READ_LINE:
    if container == pager.container:
      pager.setLineEdit("(BUFFER) " & event.prompt, BUFFER, event.value, hide = event.password)
  of READ_AREA:
    if container == pager.container:
      var s = event.tvalue
      if openInEditor(pager.term, pager.config, s):
        pager.container.readSuccess(s)
      else:
        pager.container.readCanceled()
      pager.redraw = true
  of OPEN:
    pager.gotoURL(event.request, some(container.source.location), referrer = pager.container)
  of INVALID_COMMAND: discard
  of STATUS:
    if pager.container == container:
      pager.refreshStatusMsg()
  of ALERT:
    if pager.container == container:
      pager.alert(event.msg)
  of NO_EVENT: discard
  return true

proc handleEvents*(pager: Pager, container: Container): bool =
  while container.events.len > 0:
    let event = container.events.popFirst()
    if not pager.handleEvent0(container, event):
      return false
  return true

proc handleEvent*(pager: Pager, container: Container): bool =
  try:
    container.handleEvent()
  except IOError:
    return false
  return pager.handleEvents(container)

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
