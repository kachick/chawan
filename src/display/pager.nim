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
import buffer/select
import config/config
import data/charset
import display/term
import io/headers
import io/lineedit
import io/loader
import io/promise
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
import utils/opt
import utils/twtstr

type
  LineMode* = enum
    NO_LINEMODE, LOCATION, USERNAME, PASSWORD, COMMAND, BUFFER, SEARCH_F,
    SEARCH_B, ISEARCH_F, ISEARCH_B, GOTO_LINE

  Pager* = ref object
    alerton: bool
    alerts: seq[string]
    askcursor: int
    askpromise*: Promise[bool]
    askprompt: string
    commandMode* {.jsget.}: bool
    config: Config
    container*: Container
    cookiejars: Table[string, CookieJar]
    dispatcher*: Dispatcher
    display: FixedGrid
    iregex: Result[Regex, string]
    isearchpromise: EmptyPromise
    lineedit*: Option[LineEdit]
    linehist: array[LineMode, LineHistory]
    linemode*: LineMode
    numload*: int
    omnirules: seq[OmniRule]
    procmap*: Table[Pid, Container]
    proxy: URL
    redraw*: bool
    regex: Opt[Regex]
    reverseSearch: bool
    scommand*: string
    siteconf: seq[SiteConfig]
    statusgrid*: FixedGrid
    term*: Terminal
    tty: File
    unreg*: seq[(Pid, SocketStream)]
    username: string

jsDestructor(Pager)

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
  if c != nil:
    pager.term.setTitle(c.getTitle())

proc hasprop(ctx: JSContext, pager: Pager, s: string): bool {.jshasprop.} =
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetPropertyStr(ctx, cval, s)
    if val != JS_UNDEFINED:
      result = true
    JS_FreeValue(ctx, val)

proc reflect(ctx: JSContext, this_val: JSValue, argc: cint, argv: ptr JSValue,
             magic: cint, func_data: ptr JSValue): JSValue {.cdecl.} =
  let fun = cast[ptr JSValue](cast[int](func_data) + sizeof(JSValue))[]
  return JS_Call(ctx, fun, func_data[], argc, argv)

proc getter(ctx: JSContext, pager: Pager, s: string): Option[JSValue]
    {.jsgetprop.} =
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetPropertyStr(ctx, cval, s)
    if val != JS_UNDEFINED:
      if JS_IsFunction(ctx, val):
        var func_data = @[cval, val]
        let fun = JS_NewCFunctionData(ctx, reflect, 1, 0, 2, addr func_data[0])
        return some(fun)
      return some(val)

proc searchNext(pager: Pager) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    if not pager.reverseSearch:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true)
    else:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true)

proc searchPrev(pager: Pager) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    if not pager.reverseSearch:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true)
    else:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true)

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
  pager.isearchpromise = newResolvedPromise()
  pager.setLineEdit("/", ISEARCH_F)

proc isearchBackward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.isearchpromise = newResolvedPromise()
  pager.setLineEdit("?", ISEARCH_B)

proc gotoLine[T: string|int](pager: Pager, s: T = "") {.jsfunc.} =
  when s is string:
    if s == "":
      pager.setLineEdit("Goto line: ", GOTO_LINE)
      return
  pager.container.gotoLine(s)

proc newPager*(config: Config, attrs: WindowAttributes,
    dispatcher: Dispatcher, ctx: JSContext): Pager =
  let pager = Pager(
    dispatcher: dispatcher,
    config: config,
    display: newFixedGrid(attrs.width, attrs.height - 1),
    statusgrid: newFixedGrid(attrs.width),
    term: newTerminal(stdout, config, attrs),
    siteconf: config.getSiteConfig(ctx),
    omnirules: config.getOmniRules(ctx),
    proxy: config.getProxy()
  )
  return pager

proc launchPager*(pager: Pager, tty: File) =
  pager.tty = tty
  pager.term.start(tty)

proc dumpAlerts*(pager: Pager) =
  for msg in pager.alerts:
    stderr.write("cha: " & msg & '\n')

proc quit*(pager: Pager, code = 0) =
  pager.term.quit()
  pager.dumpAlerts()

proc clearDisplay(pager: Pager) =
  pager.display = newFixedGrid(pager.display.width, pager.display.height)

proc buffer(pager: Pager): Container {.jsfget, inline.} = pager.container

proc refreshDisplay(pager: Pager, container = pager.container) =
  pager.clearDisplay()
  container.drawLines(pager.display,
    cellColor(pager.config.display.highlight_color))

# Note: this function doesn't work if start < i of last written char
proc writeStatusMessage(pager: Pager, str: string,
                        format: Format = newFormat(), start = 0,
                        maxwidth = -1, clip = '$'): int {.discardable.} =
  var maxwidth = maxwidth
  if maxwidth == -1:
    maxwidth = pager.statusgrid.len
  var i = start
  let e = min(start + maxwidth, pager.statusgrid.width)
  if i >= e:
    return i
  for r in str.runes:
    let pi = i
    i += r.twidth(i)
    if i >= e:
      if i >= pager.statusgrid.width:
        i = pi
      pager.statusgrid[i].format = format
      pager.statusgrid[i].str = $clip
      inc i
      break
    if r.isControlChar():
      pager.statusgrid[pi].str = "^" & getControlLetter(char(r))
    else:
      pager.statusgrid[pi].str = $r
    pager.statusgrid[pi].format = format
  result = i
  var def = newFormat()
  while i < e:
    pager.statusgrid[i].str = ""
    pager.statusgrid[i].format = def
    inc i

proc refreshStatusMsg*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  if pager.tty == nil: return
  if pager.askpromise != nil: return
  if container.loadinfo != "":
    pager.alerton = false
    pager.writeStatusMessage(container.loadinfo)
  elif pager.alerts.len > 0:
    pager.alerton = true
    pager.writeStatusMessage(pager.alerts[0])
    pager.alerts.delete(0)
  else:
    var format = newFormat()
    format.reverse = true
    pager.alerton = false
    container.clearHover()
    var msg = $(container.cursory + 1) & "/" & $container.numLines & " (" &
              $container.atPercentOf() & "%)"
    let mw = pager.writeStatusMessage(msg, format)
    let title = " <" & container.getTitle() & ">"
    let hover = container.getHoverText()
    if hover.len == 0:
      pager.writeStatusMessage(title, format, mw)
    else:
      let hover2 = " " & hover
      let maxwidth = pager.statusgrid.width - hover2.width() - mw
      let tw = pager.writeStatusMessage(title, format, mw, maxwidth, '>')
      pager.writeStatusMessage(hover2, format, tw)

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
      var w = 0
      var i = 0
      var s = ""
      for f in line.formats:
        var outstr = ""
        while x < f.pos:
          var r: Rune
          fastRuneAt(line.str, i, r)
          outstr &= r
          x += r.width()
        s &= pager.term.processOutputString(outstr, w)
        s &= pager.term.processFormat(format, f.format)
      s &= pager.term.processOutputString(line.str.substr(i), w)
      s &= pager.term.processFormat(format, newFormat()) & "\n"
      ostream.write(s))
  ostream.flush()

proc redraw(pager: Pager) {.jsfunc.} =
  pager.redraw = true
  pager.term.clearCanvas()

proc draw*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  pager.term.hideCursor()
  if pager.redraw:
    pager.refreshDisplay()
    pager.term.writeGrid(pager.display)
  if container.select.open and container.select.redraw:
    container.select.drawSelect(pager.display)
    pager.term.writeGrid(pager.display)
  if pager.askpromise != nil:
    discard
  elif pager.lineedit.isSome:
    if pager.lineedit.get.isnew:
      #TODO hack
      # make term notice that it must redraw when status is restored
      let x = newFixedGrid(pager.attrs.width)
      pager.term.writeGrid(x, 0, pager.attrs.height - 1)
  else:
    pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)
  pager.term.outputGrid()
  if pager.askpromise != nil:
    pager.term.setCursor(pager.askcursor, pager.attrs.height - 1)
  elif pager.lineedit.isSome:
    if pager.lineedit.get.isnew:
      #TODO hack
      pager.term.setCursor(0, pager.attrs.height - 1)
      pager.lineedit.get.drawPrompt()
      pager.term.setCursor(pager.lineedit.get.getCursorX(), pager.attrs.height - 1)
      pager.lineedit.get.fullRedraw()
      pager.lineedit.get.isnew = false
    pager.term.setCursor(pager.lineedit.get.getCursorX(), pager.attrs.height - 1)
  elif container.select.open:
    pager.term.setCursor(container.select.getCursorX(),
      container.select.getCursorY())
  else:
    pager.term.setCursor(pager.container.acursorx, pager.container.acursory)
  pager.term.showCursor()
  pager.term.flush()
  pager.redraw = false

proc writeAskPrompt(pager: Pager) =
  let yn = " (y/n)"
  let maxwidth = pager.statusgrid.width - yn.len
  let i = pager.writeStatusMessage(pager.askprompt, maxwidth = maxwidth)
  pager.askcursor = pager.writeStatusMessage(yn, start = i)
  pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)

proc ask(pager: Pager, prompt: string): Promise[bool] {.jsfunc.} =
  pager.askprompt = prompt
  pager.writeAskPrompt()
  pager.askpromise = Promise[bool]()
  return pager.askpromise

proc fulfillAsk*(pager: Pager, y: bool) =
  pager.askpromise.resolve(y)
  pager.askpromise = nil
  pager.askprompt = ""

proc registerContainer*(pager: Pager, container: Container) =
  pager.procmap[container.process] = container

proc addContainer*(pager: Pager, container: Container) =
  container.parent = pager.container
  if pager.container != nil:
    pager.container.children.insert(container, 0)
  pager.registerContainer(container)
  pager.setContainer(container)

proc dupeContainer(pager: Pager, container: Container, location: URL): Container =
  return pager.dispatcher.dupeBuffer(container, pager.config, location, "")

proc dupeBuffer*(pager: Pager, location: URL = nil) {.jsfunc.} =
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
    var container = pager.container.parent.children[n - 1]
    while container.children.len > 0:
      container = container.children[^1]
    pager.setContainer(container)
  else:
    pager.setContainer(pager.container.parent)
  return true

proc nextBuffer(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.children.len > 0:
    pager.setContainer(pager.container.children[0])
    return true
  var container = pager.container
  while container.parent != nil:
    let n = container.parent.children.find(container)
    assert n != -1, "Container not a child of its parent"
    if n < container.parent.children.high:
      pager.setContainer(container.parent.children[n + 1])
      return true
    container = container.parent
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
      "text/plain"
    else:
      "text/html"
    let container = pager.dispatcher.dupeBuffer(pager.container, pager.config, nil, contenttype)
    container.sourcepair = pager.container
    pager.container.sourcepair = container
    pager.addContainer(container)

proc windowChange*(pager: Pager, attrs: WindowAttributes) =
  pager.term.windowChange(attrs)
  pager.display = newFixedGrid(attrs.width, attrs.height - 1)
  pager.statusgrid = newFixedGrid(attrs.width)
  for container in pager.containers:
    container.windowChange(attrs)
  if pager.askprompt != "":
    pager.writeAskPrompt()
  pager.refreshStatusMsg()

# Apply siteconf settings to a request.
# Note that this may modify the URL passed.
proc applySiteconf(pager: Pager, url: var URL): BufferConfig =
  let host = url.host
  var referer_from: bool
  var cookiejar: CookieJar
  var headers: Headers
  var scripting: bool
  var images: bool
  var charsets = pager.config.encoding.document_charset
  var userstyle = pager.config.css.stylesheet
  var proxy = pager.proxy
  for sc in pager.siteconf:
    if sc.url.isSome and not sc.url.get.match($url):
      continue
    elif sc.host.isSome and not sc.host.get.match(host):
      continue
    if sc.rewrite_url != nil:
      let s = sc.rewrite_url(url)
      if s.isSome and s.get != nil:
        url = s.get
    if sc.cookie.isSome:
      if sc.cookie.get:
        # host/url might have changed by now
        let jarid = sc.share_cookiejar.get(url.host)
        if jarid notin pager.cookiejars:
          pager.cookiejars[jarid] = newCookieJar(url,
            sc.third_party_cookie)
        cookiejar = pager.cookiejars[jarid]
      else:
        cookiejar = nil # override
    if sc.scripting.isSome:
      scripting = sc.scripting.get
    if sc.referer_from.isSome:
      referer_from = sc.referer_from.get
    if sc.document_charset.len > 0:
      charsets = sc.document_charset
    if sc.images.isSome:
      images = sc.images.get
    if sc.stylesheet.isSome:
      userstyle &= "\n"
      userstyle &= sc.stylesheet.get
    if sc.proxy.isSome:
      proxy = sc.proxy.get
  return pager.config.getBufferConfig(url, cookiejar, headers,
    referer_from, scripting, charsets, images, userstyle, proxy)

# Load request in a new buffer.
proc gotoURL(pager: Pager, request: Request, prevurl = none(URL),
    ctype = none(string), cs = none(Charset), replace: Container = nil,
    redirectdepth = 0, referrer: Container = nil) =
  if referrer != nil and referrer.config.referer_from:
    request.referer = referrer.source.location
  var bufferconfig = pager.applySiteconf(request.url)
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
      charset: cs,
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
      let sub = rule.substitute_url(s)
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
proc loadURL*(pager: Pager, url: string, ctype = none(string),
    cs = none(Charset)) =
  let url0 = pager.omniRewrite(url)
  let url = if url[0] == '~': expandPath(url0) else: url0
  let firstparse = parseURL(url)
  if firstparse.issome:
    let prev = if pager.container != nil:
      some(pager.container.source.location)
    else:
      none(URL)
    pager.gotoURL(newRequest(firstparse.get), prev, ctype, cs)
    return
  var urls: seq[URL]
  if pager.config.network.prepend_https and url[0] != '/':
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
    pager.gotoURL(newRequest(urls.pop()), ctype = ctype, cs = cs)
    if pager.container != prevc:
      pager.container.retry = urls

proc readPipe0*(pager: Pager, ctype: Option[string], cs: Option[Charset],
    fd: FileHandle, location: Option[URL], title: string): Container =
  var location = location.get(newURL("file://-").get)
  let bufferconfig = pager.applySiteconf(location)
  let source = BufferSource(
    t: LOAD_PIPE,
    fd: fd,
    contenttype: some(ctype.get("text/plain")),
    charset: cs,
    location: location
  )
  return pager.dispatcher.newBuffer(bufferconfig, source, title = title)

proc readPipe*(pager: Pager, ctype: Option[string], cs: Option[Charset],
    fd: FileHandle) =
  let container = pager.readPipe0(ctype, cs, fd, none(URL), "*pipe*")
  pager.addContainer(container)

proc command(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("COMMAND: ", COMMAND)

proc commandMode(pager: Pager, val: bool) {.jsfset.} =
  pager.commandMode = val
  if val:
    pager.command()

proc checkRegex(pager: Pager, regex: Result[Regex, string]): Opt[Regex] =
  if regex.isErr:
    pager.alert("Invalid regex: " & regex.error)
    return err()
  return ok(regex.get)

proc updateReadLineISearch(pager: Pager, linemode: LineMode) =
  let lineedit = pager.lineedit.get
  pager.isearchpromise = pager.isearchpromise.then(proc(): EmptyPromise =
    case lineedit.state
    of CANCEL:
      pager.iregex.err()
      pager.container.popCursorPos()
      pager.container.clearSearchHighlights()
      pager.redraw = true
      pager.isearchpromise = nil
    of EDIT:
      let x = $lineedit.news
      if x != "": pager.iregex = compileSearchRegex(x)
      pager.container.popCursorPos(true)
      pager.container.pushCursorPos()
      if pager.iregex.isSome:
        pager.container.hlon = true
        let wrap = pager.config.search.wrap
        return if linemode == ISEARCH_F:
          pager.container.cursorNextMatch(pager.iregex.get, wrap, false)
        else:
          pager.container.cursorPrevMatch(pager.iregex.get, wrap, false)
    of FINISH:
      pager.regex = pager.checkRegex(pager.iregex)
      pager.reverseSearch = linemode == ISEARCH_B
      pager.container.clearSearchHighlights()
      pager.container.sendCursorPosition()
      pager.redraw = true
      pager.isearchpromise = nil
  )

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
        if pager.commandMode:
          pager.command()
      of BUFFER: pager.container.readSuccess(s)
      of SEARCH_F, SEARCH_B:
        let x = s
        if x != "":
          pager.regex = pager.checkRegex(compileSearchRegex(x))
        pager.reverseSearch = pager.linemode == SEARCH_B
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
      of COMMAND: pager.commandMode = false
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
  pager.gotoURL(newRequest(pager.container.source.location), none(URL),
    pager.container.contenttype, replace = pager.container)

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
      let errorMessage = getLoaderErrorMessage(container.code)
      pager.alert("Can't load " & $container.source.location & " (" &
        errorMessage & ")")
    return false
  of SUCCESS:
    if container.replace != nil:
      let n = container.replace.children.find(container)
      if n != -1:
        container.replace.children.delete(n)
        container.parent = nil
      let n2 = container.children.find(container.replace)
      if n2 != -1:
        container.children.delete(n2)
        container.replace.parent = nil
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
    if container.redirectdepth < pager.config.network.max_redirect:
      pager.alert("Redirecting to " & $event.request.url)
      pager.gotoURL(event.request, some(container.source.location),
        replace = container, redirectdepth = container.redirectdepth + 1,
        referrer = pager.container)
    else:
      pager.alert("Error: maximum redirection depth reached")
      pager.deleteContainer(container)
      return false
  of ANCHOR:
    var url2 = newURL(container.source.location)
    url2.setHash(event.anchor)
    pager.addContainer(pager.dupeContainer(container, url2))
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
    if pager.container == nil or not pager.container.isHoverURL(event.request.url):
      pager.ask("Open pop-up? " & $event.request.url).then(proc(x: bool) =
        if x:
          pager.gotoURL(event.request, some(container.source.location), referrer = pager.container))
    else:
      pager.gotoURL(event.request, some(container.source.location), referrer = pager.container)
  of INVALID_COMMAND: discard
  of STATUS:
    if pager.container == container:
      pager.refreshStatusMsg()
  of TITLE:
    if pager.container == container:
      pager.refreshStatusMsg()
      pager.term.setTitle(container.getTitle())
  of ALERT:
    if pager.container == container:
      pager.alert(event.msg)
  of NO_EVENT: discard
  return true

proc handleEvents*(pager: Pager, container: Container) =
  while container.events.len > 0:
    let event = container.events.popFirst()
    if not pager.handleEvent0(container, event):
      break

proc handleEvent*(pager: Pager, container: Container) =
  try:
    container.handleEvent()
    pager.handleEvents(container)
  except IOError:
    discard

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
