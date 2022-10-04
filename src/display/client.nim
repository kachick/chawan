import options
import os
import streams
import strutils
import tables
import terminal
import times
import unicode

import std/monotimes

import css/sheet
import config/config
import display/pager
import html/dom
import html/htmlparser
import io/buffer
import io/cell
import io/lineedit
import io/loader
import io/request
import io/term
import js/javascript
import js/regex
import types/url
import utils/twtstr

type
  Client* = ref ClientObj
  ClientObj* = object
    buffer*: Buffer
    feednext: bool
    s: string
    iserror: bool
    errormessage: string
    userstyle: CSSStylesheet
    loader: FileLoader
    console {.jsget.}: Console
    pager {.jsget.}: Pager
    config: Config
    jsrt: JSRuntime
    jsctx: JSContext
    regex: Option[Regex]
    revsearch: bool
    needsauth: bool
    redirecturl: Option[Url]
    cmdmode: bool
    timeoutid: int
    timeouts: Table[int, tuple[handler: proc(), time: int64]]
    added_timeouts: Table[int, tuple[handler: proc(), time: int64]]
    removed_timeouts: seq[int]
    intervals: Table[int, tuple[handler: proc(), time: int64, wait: int, del: JSValue]]
    added_intervals: Table[int, tuple[handler: proc(), time: int64, wait: int, del: JSValue]]
    removed_intervals: seq[int]

  Console* = ref object
    err*: Stream
    lastbuf*: Buffer
    ibuf: string

  ActionError* = object of IOError
  LoadError* = object of ActionError
  InterruptError* = object of LoadError

proc readChar(console: Console): char =
  if console.ibuf == "":
    return stdin.readChar()
  result = console.ibuf[0]
  console.ibuf = console.ibuf.substr(1)

proc `=destroy`(client: var ClientObj) =
  if client.jsctx != nil:
    free(client.jsctx)
  if client.jsrt != nil:
    free(client.jsrt)

proc statusMode(client: Client) =
  print(HVP(client.buffer.height + 1, 1))
  print(EL())

proc loadError(s: string) =
  raise newException(LoadError, s)

proc actionError(s: string) =
  raise newException(ActionError, s)

proc addBuffer(client: Client) =
  if client.buffer == nil:
    client.buffer = newBuffer()
  else:
    let oldnext = client.buffer.next
    client.buffer.next = newBuffer()
    if oldnext != nil:
      oldnext.prev = client.buffer.next
    client.buffer.next.prev = client.buffer
    client.buffer.next.next = oldnext
    client.buffer = client.buffer.next
  client.buffer.loader = client.loader
  client.buffer.userstyle = client.userstyle

proc prevBuffer(client: Client) {.jsfunc.} =
  if client.buffer.prev != nil:
    client.buffer = client.buffer.prev
    client.buffer.redraw = true

proc nextBuffer(client: Client) {.jsfunc.} =
  if client.buffer.next != nil:
    client.buffer = client.buffer.next
    client.buffer.redraw = true

proc discardBuffer(buffer: Buffer) =
  if buffer.next == nil and buffer.prev == nil:
    actionError("Cannot discard last buffer!")
  if buffer.sourcepair != nil:
    buffer.sourcepair.sourcepair = nil
  if buffer.next != nil:
    buffer.next.prev = buffer.prev
  if buffer.prev != nil:
    buffer.prev.next = buffer.next
  buffer.sourcepair = nil
  buffer.next = nil
  buffer.prev = nil

proc discardBuffer(client: Client) {.jsfunc.} =
  let old = client.buffer
  if old.next != nil:
    client.buffer = old.next
  elif old.prev != nil:
    client.buffer = old.prev
  else:
    actionError("Cannot discard last buffer!")
  discardBuffer(old)
  client.buffer.redraw = true

proc setupBuffer(client: Client) =
  let buffer = client.buffer
  buffer.load()
  buffer.render()
  buffer.gotoAnchor()
  buffer.redraw = true

proc dupeBuffer(client: Client, location = none(URL)) {.jsfunc.} =
  let prev = client.buffer
  client.addBuffer()
  client.buffer.contenttype = prev.contenttype
  client.buffer.ispipe = prev.ispipe
  client.buffer.istream = newStringStream(prev.source)
  if location.issome:
    client.buffer.location = location.get
  else:
    client.buffer.location = prev.location
  client.buffer.document = prev.document
  client.setupBuffer()

proc readPipe(client: Client, ctype: string) =
  client.addBuffer()
  client.buffer.contenttype = if ctype != "": ctype else: "text/plain"
  client.buffer.ispipe = true
  client.buffer.istream = newFileStream(stdin)
  client.buffer.location = newURL("file://-")
  client.buffer.load()
  #TODO is this portable at all?
  if reopen(stdin, "/dev/tty", fmReadWrite):
    client.setupBuffer()
  else:
    client.buffer.drawBuffer()

type Cookie = ref object of RootObj
  name {.jsget.}: string
  value {.jsget.}: string
  expires {.jsget.}: int64 # unix time
  maxAge {.jsget.}: int64
  secure {.jsget.}: bool
  httponly {.jsget.}: bool
  samesite {.jsget.}: bool
  domain {.jsget.}: string
  path {.jsget.}: string

proc parseCookieDate(val: string): Option[DateTime] =
  # cookie-date
  const Delimiters = {'\t', ' '..'/', ';'..'@', '['..'`', '{'..'~'}
  const NonDigit = Ascii + NonAscii - Digits
  var foundTime = false
  var foundDayOfMonth = false
  var foundMonth = false
  var foundYear = false
  # date-token-list
  var time: array[3, int]
  var dayOfMonth: int
  var month: int
  var year: int
  for dateToken in val.split(Delimiters):
    if dateToken == "": continue # *delimiter
    if not foundTime:
      block timeBlock: # test for time
        let hmsTime = dateToken.until(NonDigit - {':'})
        var i = 0
        for timeField in hmsTime.split(':'):
          if i > 2: break timeBlock # too many time fields
          # 1*2DIGIT
          if timeField.len != 1 and timeField.len != 2: break timeBlock
          var timeFields: array[3, int]
          for c in timeField:
            if c notin Digits: break timeBlock
            timeFields[i] *= 10
            timeFields[i] += c.decValue
          time = timeFields
          inc i
        if i != 3: break timeBlock
        foundTime = true
        continue
    if not foundDayOfMonth:
      block dayOfMonthBlock: # test for day-of-month
        let digits = dateToken.until(NonDigit)
        if digits.len != 1 and digits.len != 2: break dayOfMonthBlock
        var n = 0
        for c in digits:
          if c notin Digits: break dayOfMonthBlock
          n *= 10
          n += c.decValue
        dayOfMonth = n
        foundDayOfMonth = true
        continue
    if not foundMonth:
      block monthBlock: # test for month
        if dateToken.len < 3: break monthBlock
        case dateToken.substr(0, 2).toLower()
        of "jan": month = 1
        of "feb": month = 2
        of "mar": month = 3
        of "apr": month = 4
        of "may": month = 5
        of "jun": month = 6
        of "jul": month = 7
        of "aug": month = 8
        of "sep": month = 9
        of "oct": month = 10
        of "nov": month = 11
        of "dec": month = 12
        else: break monthBlock
        foundMonth = true
        continue
    if not foundYear:
      block yearBlock: # test for year
        let digits = dateToken.until(NonDigit)
        if digits.len != 2 and digits.len != 4: break yearBlock
        var n = 0
        for c in digits:
          if c notin Digits: break yearBlock
          n *= 10
          n += c.decValue
        year = n
        foundYear = true
        continue
  if not (foundDayOfMonth and foundMonth and foundYear and foundTime): return none(DateTime)
  if dayOfMonth notin 0..31: return none(DateTime)
  if year < 1601: return none(DateTime)
  if time[0] > 23: return none(DateTime)
  if time[1] > 59: return none(DateTime)
  if time[2] > 59: return none(DateTime)
  var dateTime = dateTime(year, Month(month), MonthdayRange(dayOfMonth), HourRange(time[0]), MinuteRange(time[1]), SecondRange(time[2]))
  return some(dateTime)

proc parseCookie(client: Client, str: string): Cookie {.jsfunc.} =
  let cookie = new(Cookie)
  var first = true
  for part in str.split(';'):
    if first:
      cookie.name = part.until('=')
      cookie.value = part.after('=')
      first = false
      continue
    let part = percentDecode(part).strip(leading = true, trailing = false, AsciiWhitespace)
    var n = 0
    for i in 0..part.high:
      if part[i] == '=':
        n = i
        break
    if n == 0:
      continue
    let key = part.substr(0, n - 1)
    let val = part.substr(n + 1)
    case key.toLower()
    of "expires":
      let date = parseCookieDate(val)
      if date.issome:
        cookie.expires = date.get.toTime().toUnix()
    of "max-age": cookie.maxAge = parseInt64(val)
    of "secure": cookie.secure = true
    of "httponly": cookie.httponly = true
    of "samesite": cookie.samesite = true
    of "path": cookie.path = val
    of "domain": cookie.domain = val
  return cookie

proc doRequest(client: Client, req: Request): Response {.jsfunc.} =
  client.loader.doRequest(req)

# Load request in a new buffer.
var g_client: Client
proc gotoUrl(client: Client, request: Request, prevurl = none(URL), force = false, ctype = "") =
  if force or prevurl.isnone or not prevurl.get.equals(request.url, true) or
      prevurl.get.equals(request.url) or request.httpmethod != HTTP_GET:
    let page = client.doRequest(request)
    client.needsauth = page.status == 401 # Unauthorized
    client.redirecturl = page.redirect
    if page.body != nil:
      client.addBuffer()
      g_client = client
      client.buffer.contenttype = if ctype != "": ctype else: page.contenttype
      client.buffer.istream = page.body
      client.buffer.location = request.url
      client.setupBuffer()
    else:
      loadError("Couldn't load " & $request.url & " (" & $page.res & ")")
  elif client.buffer != nil and prevurl.issome and prevurl.get.equals(request.url, true):
    if client.buffer.hasAnchor(request.url.anchor):
      client.dupeBuffer(request.url.some)
    else:
      loadError("Couldn't find anchor " & request.url.anchor)

# Relative gotoUrl: either to prevurl, or if that's none, client.buffer.url.
proc gotoUrl(client: Client, url: string, prevurl = none(URL), force = false, ctype = "") =
  var prevurl = prevurl
  if prevurl.isnone and client.buffer != nil:
    prevurl = client.buffer.location.some
  let newurl = parseUrl(url, prevurl)
  if newurl.isnone:
    loadError("Invalid URL " & url)
  client.gotoUrl(newRequest(newurl.get), prevurl, force, ctype)

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
# (TODO: make this optional)
proc loadUrl(client: Client, url: string, ctype = "") =
  let firstparse = parseUrl(url)
  if firstparse.issome:
    client.gotoUrl(newRequest(firstparse.get), none(Url), true, ctype)
  else:
    let cdir = parseUrl("file://" & getCurrentDir() & DirSep)
    try:
      # attempt to load local file
      client.gotoUrl(url, cdir, true, ctype)
    except LoadError:
      try:
        # attempt to load local file (this time percent encoded)
        client.gotoUrl(percentEncode(url, LocalPathPercentEncodeSet), cdir, true, ctype)
      except LoadError:
        # attempt to load remote page
        client.gotoUrl("https://" & url, none(Url), true, ctype)

# Reload the page in a new buffer, then kill the previous buffer.
proc reloadPage(client: Client) {.jsfunc.} =
  let buf = client.buffer
  client.gotoUrl(newRequest(client.buffer.location), none(URL), true, client.buffer.contenttype)
  discardBuffer(buf)

# Open a URL prompt and visit the specified URL.
proc changeLocation(client: Client) {.jsfunc.} =
  let buffer = client.buffer
  var url = buffer.location.serialize(true)
  client.statusMode()
  let status = readLine("URL: ", url, buffer.width, config = client.config)
  if status:
    client.loadUrl(url)

proc click(client: Client) {.jsfunc.} =
  let req = client.buffer.click()
  if req.issome:
    client.gotoUrl(req.get, client.buffer.location.some)

proc toggleSource*(client: Client) {.jsfunc.} =
  let buffer = client.buffer
  if buffer.sourcepair != nil:
    client.buffer = buffer.sourcepair
    client.buffer.redraw = true
  else:
    client.addBuffer()
    client.buffer.sourcepair = client.buffer.prev
    client.buffer.sourcepair.sourcepair = client.buffer
    client.buffer.source = client.buffer.prev.source
    client.buffer.streamclosed = true
    client.buffer.location = client.buffer.sourcepair.location
    client.buffer.ispipe = client.buffer.sourcepair.ispipe
    let prevtype = client.buffer.prev.contenttype
    if prevtype == "text/html":
      client.buffer.contenttype = "text/plain"
    else:
      client.buffer.contenttype = "text/html"
    client.setupBuffer()

proc interruptHandler(rt: JSRuntime, opaque: pointer): int {.cdecl.} =
  let client = cast[Client](opaque)
  try:
    let c = stdin.readChar()
    if c == char(3): #C-c
      client.console.ibuf = ""
      return 1
    else:
      client.console.ibuf &= c
  except IOError:
    discard
  return 0

proc evalJS(client: Client, src, filename: string): JSObject =
  unblockStdin()
  return client.jsctx.eval(src, filename, JS_EVAL_TYPE_GLOBAL)

proc evalJSFree(client: Client, src, filename: string) =
  free(client.evalJS(src, filename))

proc command0(client: Client, src: string, filename = "<command>", silence = false) =
  let ret = client.evalJS(src, filename)
  if ret.isException():
    client.jsctx.writeException(client.console.err)
  else:
    if not silence:
      let str = ret.toString()
      if str.issome:
        client.console.err.write(str.get & '\n')
  free(ret)
  for k, v in client.added_timeouts:
    client.timeouts[k] = v
  client.added_timeouts.clear()
  for k, v in client.added_intervals:
    client.intervals = client.added_intervals
  client.added_intervals.clear()

proc command(client: Client, src: string) =
  restoreStdin()
  let previ = client.console.err.getPosition()
  client.command0(src)
  g_client = client
  client.console.err.setPosition(previ)
  if client.console.lastbuf == nil or client.console.lastbuf != client.buffer:
    client.addBuffer()
    client.buffer.istream = newStringStream(client.console.err.readAll()) #TODO
    client.buffer.contenttype = "text/plain"
    client.buffer.location = parseUrl("javascript:void(0);").get
    client.console.lastbuf = client.buffer
  else:
    client.buffer.istream = newStringStream(client.buffer.source & client.console.err.readAll())
    client.buffer.streamclosed = false
  client.setupBuffer()
  client.buffer.cursorLastLine()

proc command(client: Client): bool {.jsfunc.} =
  var iput: string
  client.statusMode()
  let status = readLine("COMMAND: ", iput, client.buffer.width, config = client.config)
  if status:
    client.command(iput)
  return status

proc commandMode(client: Client) {.jsfunc.} =
  client.cmdmode = client.command()

proc searchNext(client: Client) {.jsfunc.} =
  if client.regex.issome:
    if not client.revsearch:
      discard client.buffer.cursorNextMatch(client.regex.get)
    else:
      discard client.buffer.cursorPrevMatch(client.regex.get)

proc searchPrev(client: Client) {.jsfunc.} =
  if client.regex.issome:
    if not client.revsearch:
      discard client.buffer.cursorPrevMatch(client.regex.get)
    else:
      discard client.buffer.cursorNextMatch(client.regex.get)

proc search(client: Client) {.jsfunc.} =
  client.statusMode()
  var iput: string
  let status = readLine("/", iput, client.buffer.width, config = client.config)
  if status:
    if iput.len != 0:
      client.regex = compileSearchRegex(iput)
    client.revsearch = false
    client.searchNext()

proc searchBack(client: Client) {.jsfunc.} =
  client.statusMode()
  var iput: string
  let status = readLine("?", iput, client.buffer.width, config = client.config)
  if status:
    if iput.len != 0:
      client.regex = compileSearchRegex(iput)
    client.revsearch = true
    client.searchNext()

proc isearch(client: Client) {.jsfunc.} =
  client.statusMode()
  var iput: string
  let cpos = client.buffer.cpos
  var mark: Mark
  template del_mark() =
    if mark != nil:
      client.buffer.removeMark(mark)

  let status = readLine("/", iput, client.buffer.width, {}, false, client.config, (proc(state: var LineState): bool =
    del_mark
    let regex = compileSearchRegex($state.news)
    client.buffer.cpos = cpos
    if regex.issome:
      let match = client.buffer.cursorNextMatch(regex.get)
      if match.success:
        mark = client.buffer.addMark(match.x, match.y, match.str.width())
        client.buffer.redraw = true
        client.buffer.refreshBuffer(true)
        print(HVP(client.buffer.height + 1, 2))
        print(SGR())
      else:
        del_mark
        client.buffer.redraw = true
        client.buffer.refreshBuffer(true)
        print(HVP(client.buffer.height + 1, 2))
        print(SGR())
      return true
    false
  ))

  del_mark
  client.buffer.redraw = true
  client.buffer.refreshBuffer(true)
  if status:
    client.regex = compileSearchRegex(iput)
  else:
    client.buffer.cpos = cpos

proc isearchBack(client: Client) {.jsfunc.} =
  client.statusMode()
  var iput: string
  let cpos = client.buffer.cpos
  var mark: Mark
  template del_mark() =
    if mark != nil:
      client.buffer.removeMark(mark)
  let status = readLine("?", iput, client.buffer.width, {}, false, client.config, (proc(state: var LineState): bool =
    del_mark
    let regex = compileSearchRegex($state.news)
    client.buffer.cpos = cpos
    if regex.issome:
      let match = client.buffer.cursorPrevMatch(regex.get)
      if match.success:
        mark = client.buffer.addMark(match.x, match.y, match.str.width())
        client.buffer.redraw = true
        client.buffer.refreshBuffer(true)
        print(HVP(client.buffer.height + 1, 2))
        print(SGR())
      else:
        del_mark
        client.buffer.redraw = true
        client.buffer.refreshBuffer(true)
        print(HVP(client.buffer.height + 1, 2))
        print(SGR())
      return true
    false
  ))
  del_mark
  client.buffer.redraw = true
  if status:
    client.regex = compileSearchRegex(iput)
  else:
    client.buffer.cpos = cpos

proc quit(client: Client) {.jsfunc.} =
  print(HVP(getTermAttributes().height, 0))
  print(EL())
  quit(0)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

#TODO move this to a pager module or something
proc cursorLeft(client: Client) {.jsfunc.} = client.buffer.cursorLeft()
proc cursorDown(client: Client) {.jsfunc.} = client.buffer.cursorDown()
proc cursorUp(client: Client) {.jsfunc.} = client.buffer.cursorUp()
proc cursorRight(client: Client) {.jsfunc.} = client.buffer.cursorRight()
proc cursorLineBegin(client: Client) {.jsfunc.} = client.buffer.cursorLineBegin()
proc cursorLineEnd(client: Client) {.jsfunc.} = client.buffer.cursorLineEnd()
proc cursorNextWord(client: Client) {.jsfunc.} = client.buffer.cursorNextWord()
proc cursorPrevWord(client: Client) {.jsfunc.} = client.buffer.cursorPrevWord()
proc cursorNextLink(client: Client) {.jsfunc.} = client.buffer.cursorNextLink()
proc cursorPrevLink(client: Client) {.jsfunc.} = client.buffer.cursorPrevLink()
proc pageDown(client: Client) {.jsfunc.} = client.buffer.pageDown()
proc pageUp(client: Client) {.jsfunc.} = client.buffer.pageUp()
proc pageRight(client: Client) {.jsfunc.} = client.buffer.pageRight()
proc pageLeft(client: Client) {.jsfunc.} = client.buffer.pageLeft()
proc halfPageDown(client: Client) {.jsfunc.} = client.buffer.halfPageDown()
proc halfPageUp(client: Client) {.jsfunc.} = client.buffer.halfPageUp()
proc cursorFirstLine(client: Client) {.jsfunc.} = client.buffer.cursorFirstLine()
proc cursorLastLine(client: Client) {.jsfunc.} = client.buffer.cursorLastLine()
proc cursorTop(client: Client) {.jsfunc.} = client.buffer.cursorTop()
proc cursorMiddle(client: Client) {.jsfunc.} = client.buffer.cursorMiddle()
proc cursorBottom(client: Client) {.jsfunc.} = client.buffer.cursorBottom()
proc cursorLeftEdge(client: Client) {.jsfunc.} = client.buffer.cursorLeftEdge()
proc cursorVertMiddle(client: Client) {.jsfunc.} = client.buffer.cursorVertMiddle()
proc cursorRightEdge(client: Client) {.jsfunc.} = client.buffer.cursorRightEdge()
proc centerLine(client: Client) {.jsfunc.} = client.buffer.centerLine()
proc scrollDown(client: Client) {.jsfunc.} = client.buffer.scrollDown()
proc scrollUp(client: Client) {.jsfunc.} = client.buffer.scrollUp()
proc scrollLeft(client: Client) {.jsfunc.} = client.buffer.scrollLeft()
proc scrollRight(client: Client) {.jsfunc.} = client.buffer.scrollRight()
proc lineInfo(client: Client) {.jsfunc.} = client.buffer.lineInfo()
proc reshape(client: Client) {.jsfunc.} = client.buffer.reshape = true
proc redraw(client: Client) {.jsfunc.} = client.buffer.redraw = true

proc input(client: Client) =
  if client.cmdmode:
    client.commandMode()
    return
  if not client.feednext:
    client.s = ""
  else:
    client.feednext = false
  restoreStdin()
  let c = client.console.readChar()
  client.s &= c

  let action = getNormalAction(client.config, client.s)
  client.evalJSFree(action, "<command>")

proc followRedirect(client: Client)

proc checkAuth(client: Client) =
  if client.needsauth:
    client.buffer.refreshBuffer()
    client.statusMode()
    var username = ""
    let ustatus = readLine("Username: ", username, client.buffer.width, config = client.config)
    if not ustatus:
      client.needsauth = false
      return
    client.statusMode()
    var password = ""
    let pstatus = readLine("Password: ", password, client.buffer.width, hide = true, config = client.config)
    if not pstatus:
      client.needsauth = false
      return
    var url = client.buffer.location
    url.username = username
    url.password = password
    var buf = client.buffer
    client.gotoUrl(newRequest(url), prevurl = some(client.buffer.location))
    discardBuffer(buf)
    client.followRedirect()

proc followRedirect(client: Client) =
  while client.redirecturl.issome:
    client.statusMode()
    print("Redirecting to ", $client.redirecturl.get)
    stdout.flushFile()
    client.buffer.refreshBuffer(true)
    var buf = client.buffer
    let redirecturl = client.redirecturl.get
    client.redirecturl = none(Url)
    client.gotoUrl(newRequest(redirecturl), prevurl = some(client.buffer.location))
    discardBuffer(buf)
    if client.needsauth:
      client.checkAuth()

proc inputLoop(client: Client) =
  while true:
    g_client = client
    restoreStdin()
    client.followRedirect()
    client.checkAuth()
    client.buffer.refreshBuffer()
    if client.needsauth: # Unauthorized
      client.checkAuth()
    try:
      client.input()
    except ActionError as e:
      client.buffer.setStatusMessage(e.msg)

#TODO this is dumb
proc readFile(client: Client, path: string): string {.jsfunc.} =
  try:
    return readFile(path)
  except IOError:
    discard

#TODO ditto
proc writeFile(client: Client, path: string, content: string) {.jsfunc.} =
  writeFile(path, content)

import bindings/quickjs

proc setTimeout[T: JSObject|string](client: Client, handler: T, timeout = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  when T is string:
    client.added_timeouts[id] = ((proc() =
      client.evalJSFree(handler, "setTimeout handler")
    ), getMonoTime().ticks div 1_000_000 + timeout)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.added_timeouts[id] = ((proc() =
      let ret = JSObject(ctx: handler.ctx, val: fun).callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
      JS_FreeValue(ret.ctx, fun)
    ), getMonoTime().ticks div 1_000_000 + timeout)
  return id

proc setInterval[T: JSObject|string](client: Client, handler: T, interval = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  when T is string:
    client.added_intervals[id] = ((proc() =
      client.evalJSFree(handler, "setInterval handler")
    ), getMonoTime().ticks div 1_000_000 + interval, interval, JS_NULL)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.added_intervals[id] = ((proc() =
      let ret = JSObject(ctx: handler.ctx, val: fun).callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
    ), getMonoTime().ticks div 1_000_000 + interval, interval, fun)
  return id

proc clearTimeout(client: Client, id: int) {.jsfunc.} =
  client.removed_timeouts.add(id)

proc clearInterval(client: Client, id: int) {.jsfunc.} =
  client.removed_intervals.add(id)

proc jsEventLoop(client: Client) =
  while client.timeouts.len > 0 or client.intervals.len > 0:
    var wait = -1
    let curr = getMonoTime().ticks div 1_000_000
    for k, v in client.timeouts:
      if v.time <= curr:
        v.handler()
        client.removed_timeouts.add(k)
    for k, v in client.intervals.mpairs:
      if v.time <= curr:
        v.handler()
        v.time = curr + v.wait
    for k, v in client.added_timeouts:
      client.timeouts[k] = v
    client.added_timeouts.clear()
    for k, v in client.added_intervals:
      client.intervals[k] = v
    client.added_intervals.clear()
    for k in client.removed_timeouts:
      client.timeouts.del(k)
    for k in client.removed_intervals:
      if k in client.intervals and client.intervals[k].del != JS_NULL:
        JS_FreeValue(client.jsctx, client.intervals[k].del)
      client.intervals.del(k)
    client.removed_timeouts.setLen(0)
    client.removed_intervals.setLen(0)
    for k, v in client.timeouts:
      if wait != -1:
        wait = min(wait, int(v.time - curr))
      else:
        wait = int(v.time - curr)
    for k, v in client.intervals:
      if wait != -1:
        wait = min(wait, int(v.time - curr))
      else:
        wait = int(v.time - curr)
    if wait > 0:
      sleep(wait)

proc launchClient*(client: Client, pages: seq[string], ctype: string, dump: bool) =
  if client.config.startup != "":
    let s = readFile(client.config.startup)
    client.console.err = newFileStream(stderr)
    client.command0(s, client.config.startup, silence = true)
    client.jsEventLoop()
    client.console.err = newStringStream()
    quit()
  client.userstyle = client.config.stylesheet.parseStylesheet()
  if not stdin.isatty:
    client.readPipe(ctype)
  try:
    for page in pages:
      client.loadUrl(page, ctype)
  except LoadError as e:
    eprint e.msg
    quit(1)

  if stdout.isatty and not dump:
    when defined(posix):
      enableRawMode()
    client.inputLoop()
  else:
    var buffer = client.buffer
    while buffer.next != nil:
      buffer = buffer.next

    buffer.drawBuffer()
    while buffer.prev != nil:
      buffer = buffer.prev
      buffer.drawBuffer()

proc nimGCStats(client: Client): string {.jsfunc.} =
  return GC_getStatistics()

proc jsGCStats(client: Client): string {.jsfunc.} =
  return client.jsrt.getMemoryUsage()

func newConsole(): Console =
  new(result)
  result.err = newStringStream()

proc log(console: Console, ss: varargs[string]) {.jsfunc.} =
  for i in 0..<ss.len:
    console.err.write(ss[i])
    if i != ss.high:
      console.err.write(' ')
  console.err.write('\n')

proc sleep(client: Client, millis: int) {.jsfunc.} =
  sleep millis

proc newClient*(config: Config): Client =
  new(result)
  result.config = config
  result.loader = newFileLoader()
  result.console = newConsole()
  let rt = newJSRuntime()
  rt.setInterruptHandler(interruptHandler, cast[pointer](result))
  let ctx = rt.newJSContext()
  result.jsrt = rt
  result.jsctx = ctx
  var global = ctx.getGlobalObject()
  ctx.registerType(Cookie)
  ctx.registerType(Client, asglobal = true)
  global.setOpaque(result)
  ctx.setProperty(global.val, "client", global.val)
  free(global)

  ctx.registerType(Console)

  ctx.addUrlModule()
  ctx.addDOMModule()
  ctx.addHTMLModule()
  ctx.addRequestModule()
  ctx.addPagerModule()
