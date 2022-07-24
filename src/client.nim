import options
import os
import streams
import terminal
import unicode

import bindings/curl
import css/sheet
import config/config
import io/buffer
import io/cell
import io/lineedit
import io/loader
import js/javascript
import js/regex
import types/url
import utils/twtstr

type
  Client* = ref ClientObj
  ClientObj = object
    buffer: Buffer
    feednext: bool
    s: string
    iserror: bool
    errormessage: string
    userstyle: CSSStylesheet
    loader: FileLoader
    jsrt: JSRuntime
    jsctx: JSContext
    regex: Option[Regex]
    revsearch: bool

  ActionError = object of IOError
  LoadError = object of ActionError
  InterruptError = object of LoadError

proc statusMode(client: Client) =
  print(HVP(client.buffer.height + 1, 1))
  print(EL())

proc js_console_log(ctx: JSContext, this: JSValue, argc: int, argv: ptr JSValue): JSValue {.cdecl.} =
  let opaque = ctx.getOpaque()
  for i in 0..<argc:
    let arg = getJSObject(ctx, argv, i)
    if i != 0:
      opaque.err &= ' '
    let str = arg.toString()
    if str.isnone:
      return JS_EXCEPTION
    opaque.err &= str.get
  opaque.err &= '\n'
  return JS_UNDEFINED

proc `=destroy`(client: var ClientObj) =
  if client.jsctx != nil:
    free(client.jsctx)
  if client.jsrt != nil:
    free(client.jsrt)

proc newClient*(): Client =
  new(result)
  result.loader = newFileLoader()
  let rt = newJSRuntime()
  let ctx = rt.newJSContext()
  result.jsrt = rt
  result.jsctx = ctx
  var global = ctx.getGlobalObject()
  let console = newJSObject(result.jsctx)
  console.setFunctionProperty("log", js_console_log)
  global.setProperty("console", console)
  free(global)

proc loadError(s: string) =
  raise newException(LoadError, s)

proc actionError(s: string) =
  raise newException(ActionError, s)

proc interruptError() =
  raise newException(InterruptError, "Interrupted")

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

proc prevBuffer(client: Client) =
  if client.buffer.prev != nil:
    client.buffer = client.buffer.prev
    client.buffer.redraw = true

proc nextBuffer(client: Client) =
  if client.buffer.next != nil:
    client.buffer = client.buffer.next
    client.buffer.redraw = true

proc discardBuffer(client: Client) =
  if client.buffer.next != nil:
    if client.buffer.sourcepair != nil:
      client.buffer.sourcepair.sourcepair = nil
    client.buffer.next.prev = client.buffer.prev
    client.buffer = client.buffer.next
    client.buffer.redraw = true
  elif client.buffer.prev != nil:
    if client.buffer.sourcepair != nil:
      client.buffer.sourcepair.sourcepair = nil
    client.buffer.prev.next = client.buffer.next
    client.buffer = client.buffer.prev
    client.buffer.redraw = true
  else:
    actionError("Can't discard last buffer!")

proc setupBuffer(client: Client) =
  let buffer = client.buffer
  buffer.userstyle = client.userstyle
  buffer.load()
  buffer.render()
  buffer.gotoAnchor()
  buffer.redraw = true

proc readPipe(client: Client, ctype: string) =
  client.buffer = newBuffer()
  client.buffer.loader = client.loader
  client.buffer.contenttype = if ctype != "": ctype else: "text/plain"
  client.buffer.ispipe = true
  client.buffer.istream = newFileStream(stdin)
  const url = parseUrl("file://-").get
  client.buffer.location = url
  client.buffer.load()
  #TODO is this portable at all?
  if reopen(stdin, "/dev/tty", fmReadWrite):
    client.setupBuffer()
  else:
    client.buffer.drawBuffer()

var g_client: Client
proc gotoUrl(client: Client, url: Url, click = none(ClickAction), prevurl = none(Url), force = false, newbuf = true, ctype = "") =
  setControlCHook(proc() {.noconv.} =
    raise newException(InterruptError, "Interrupted"))
  if force or prevurl.issome or not prevurl.get.equals(url, true):
    try:
      let page = if click.isnone:
        client.loader.getPage(url)
      else:
        client.loader.getPage(url, click.get.httpmethod, click.get.mimetype, click.get.body, click.get.multipart)
      if page.s != nil:
        if newbuf:
          client.addBuffer()
          g_client = client
          setControlCHook(proc() {.noconv.} =
            if g_client.buffer.prev != nil or g_client.buffer.next != nil:
              g_client.discardBuffer()
            interruptError())
        client.buffer.istream = page.s
        client.buffer.contenttype = if ctype != "": ctype else: page.contenttype
      else:
        loadError("Couldn't load " & $url)
    except IOError, OSError:
      loadError("Couldn't load " & $url)
  elif client.buffer != nil and prevurl.isnone or not prevurl.get.equals(url):
    if not client.buffer.hasAnchor(url.anchor):
      loadError("Couldn't find anchor " & url.anchor)
  client.buffer.location = url
  client.setupBuffer()

proc gotoUrl(client: Client, url: string, click = none(ClickAction), prevurl = none(Url), force = false, newbuf = true, ctype = "") =
  var oldurl = prevurl
  if oldurl.isnone and client.buffer != nil:
    oldurl = client.buffer.location.some
  let newurl = parseUrl(url, oldurl)
  if newurl.isnone:
    loadError("Invalid URL " & url)
  client.gotoUrl(newurl.get, click, oldurl, force, newbuf, ctype)

proc loadUrl(client: Client, url: string, ctype = "") =
  let firstparse = parseUrl(url)
  if firstparse.issome:
    client.gotoUrl(url, none(ClickAction), none(Url), true, true, ctype)
  else:
    let cdir = parseUrl("file://" & getCurrentDir() & DirSep)
    try:
      # attempt to load local file
      client.gotoUrl(url, none(ClickAction), cdir, true, true, ctype)
    except LoadError:
      try:
        # attempt to load local file (this time percent encoded)
        client.gotoUrl(percentEncode(url, LocalPathPercentEncodeSet), none(ClickAction), cdir, true, true, ctype)
      except LoadError:
        # attempt to load remote page
        client.gotoUrl("http://" & url, none(ClickAction), none(Url), true, true, ctype)

proc reloadPage(client: Client) =
  client.gotoUrl(client.buffer.location, none(ClickAction), none(Url), true, true, client.buffer.contenttype)

proc changeLocation(client: Client) =
  let buffer = client.buffer
  var url = buffer.location.serialize(true)
  client.statusMode()
  let status = readLine("URL: ", url, buffer.width)
  if status:
    client.loadUrl(url)

proc click(client: Client) =
  let s = client.buffer.click()
  if s.issome and s.get.url != "":
    client.gotoUrl(s.get.url, s)

proc toggleSource*(client: Client) =
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

proc command(client: Client) =
  var iput: string
  client.statusMode()
  let status = readLine("COMMAND: ", iput, client.buffer.width)
  if status and iput.len > 0:
    let ret = client.jsctx.eval(iput, "<stdin>", JS_EVAL_TYPE_GLOBAL)
    let opaque = client.jsctx.getOpaque()
    if ret.isException():
      let ex = client.jsctx.getException()
      let str = ex.toString()
      if str.issome:
        opaque.err &= str.get & '\n'
      var stack = ex.getProperty("stack")
      if not stack.isUndefined():
        let str = stack.toString()
        if str.issome:
          opaque.err &= str.get & '\n'
      free(stack)
      free(ex)
    else:
      let str = ret.toString()
      if str.issome:
        opaque.err &= str.get & '\n'
    free(ret)
    client.addBuffer()
    g_client = client
    setControlCHook(proc() {.noconv.} =
      if g_client.buffer.prev != nil or g_client.buffer.next != nil:
        g_client.discardBuffer()
      interruptError())
    client.buffer.istream = newStringStream(opaque.err)
    client.buffer.contenttype = "text/plain"
    client.setupBuffer()

proc searchNext(client: Client) =
  if client.regex.issome:
    if not client.revsearch:
      discard client.buffer.cursorNextMatch(client.regex.get)
    else:
      discard client.buffer.cursorPrevMatch(client.regex.get)

proc searchPrev(client: Client) =
  if client.regex.issome:
    if not client.revsearch:
      discard client.buffer.cursorPrevMatch(client.regex.get)
    else:
      discard client.buffer.cursorNextMatch(client.regex.get)

proc search(client: Client) =
  client.statusMode()
  var iput: string
  let status = readLine("/", iput, client.buffer.width)
  if status:
    if iput.len != 0:
      client.regex = compileSearchRegex(iput)
    client.revsearch = false
    client.searchNext()

proc searchBack(client: Client) =
  client.statusMode()
  var iput: string
  let status = readLine("?", iput, client.buffer.width)
  if status:
    if iput.len != 0:
      client.regex = compileSearchRegex(iput)
    client.revsearch = true
    client.searchNext()

proc isearch(client: Client) =
  client.statusMode()
  var iput: string
  let cpos = client.buffer.cpos
  var mark: Mark
  var my: int
  template del_mark() =
    if mark != nil:
      client.buffer.removeMark(my, mark)

  let status = readLine("/", iput, client.buffer.width, {}, (proc(state: var LineState): bool =
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
      else:
        del_mark
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

proc isearchBack(client: Client) =
  client.statusMode()
  var iput: string
  let cpos = client.buffer.cpos
  var mark: Mark
  var my: int
  template del_mark() =
    if mark != nil:
      client.buffer.removeMark(my, mark)
  let status = readLine("?", iput, client.buffer.width, {}, (proc(state: var LineState): bool =
    del_mark
    let regex = compileSearchRegex($state.news)
    client.buffer.cpos = cpos
    if regex.issome:
      let match = client.buffer.cursorPrevMatch(regex.get)
      if match.success:
        mark = client.buffer.addMark(match.x, match.y, match.str.width())
        my = match.y
        client.buffer.redraw = true
        client.buffer.refreshBuffer(true)
        print(HVP(client.buffer.height + 1, 2))
      else:
        del_mark
      return true
    false
  ))
  del_mark
  client.buffer.redraw = true
  if status:
    client.regex = compileSearchRegex(iput)
  else:
    client.buffer.cpos = cpos

proc quit(client: Client) =
  eraseScreen()
  print(HVP(0, 0))
  curl_global_cleanup()
  quit(0)

proc input(client: Client) =
  let buffer = client.buffer
  if not client.feednext:
    client.s = ""
  else:
    client.feednext = false
  let c = getch()
  client.s &= c
  let action = getNormalAction(client.s)
  case action
  of ACTION_QUIT: client.quit()
  of ACTION_CURSOR_LEFT: buffer.cursorLeft()
  of ACTION_CURSOR_DOWN: buffer.cursorDown()
  of ACTION_CURSOR_UP: buffer.cursorUp()
  of ACTION_CURSOR_RIGHT: buffer.cursorRight()
  of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
  of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
  of ACTION_CURSOR_NEXT_WORD: buffer.cursorNextWord()
  of ACTION_CURSOR_PREV_WORD: buffer.cursorPrevWord()
  of ACTION_CURSOR_NEXT_LINK: buffer.cursorNextLink()
  of ACTION_CURSOR_PREV_LINK: buffer.cursorPrevLink()
  of ACTION_PAGE_DOWN: buffer.pageDown()
  of ACTION_PAGE_UP: buffer.pageUp()
  of ACTION_PAGE_RIGHT: buffer.pageRight()
  of ACTION_PAGE_LEFT: buffer.pageLeft()
  of ACTION_HALF_PAGE_DOWN: buffer.halfPageDown()
  of ACTION_HALF_PAGE_UP: buffer.halfPageUp()
  of ACTION_CURSOR_FIRST_LINE: buffer.cursorFirstLine()
  of ACTION_CURSOR_LAST_LINE: buffer.cursorLastLine()
  of ACTION_CURSOR_TOP: buffer.cursorTop()
  of ACTION_CURSOR_MIDDLE: buffer.cursorMiddle()
  of ACTION_CURSOR_BOTTOM: buffer.cursorBottom()
  of ACTION_CURSOR_LEFT_EDGE: buffer.cursorLeftEdge()
  of ACTION_CURSOR_VERT_MIDDLE: buffer.cursorVertMiddle()
  of ACTION_CURSOR_RIGHT_EDGE: buffer.cursorRightEdge()
  of ACTION_CENTER_LINE: buffer.centerLine()
  of ACTION_SCROLL_DOWN: buffer.scrollDown()
  of ACTION_SCROLL_UP: buffer.scrollUp()
  of ACTION_SCROLL_LEFT: buffer.scrollLeft()
  of ACTION_SCROLL_RIGHT: buffer.scrollRight()
  of ACTION_CLICK: client.click()
  of ACTION_CHANGE_LOCATION: client.changeLocation()
  of ACTION_LINE_INFO: buffer.lineInfo()
  of ACTION_FEED_NEXT: client.feednext = true
  of ACTION_RELOAD: client.reloadPage()
  of ACTION_RESHAPE: buffer.reshape = true
  of ACTION_REDRAW: buffer.redraw = true
  of ACTION_TOGGLE_SOURCE: client.toggleSource()
  of ACTION_PREV_BUFFER: client.prevBuffer()
  of ACTION_NEXT_BUFFER: client.nextBuffer()
  of ACTION_DISCARD_BUFFER: client.discardBuffer()
  of ACTION_COMMAND: client.command()
  of ACTION_SEARCH: client.search()
  of ACTION_SEARCH_BACK: client.searchBack()
  of ACTION_ISEARCH: client.isearch()
  of ACTION_ISEARCH_BACK: client.isearchBack()
  of ACTION_SEARCH_NEXT: client.searchNext()
  of ACTION_SEARCH_PREV: client.searchPrev()
  else: discard

proc inputLoop(client: Client) =
  while true:
    g_client = client
    setControlCHook(proc() {.noconv.} =
      g_client.buffer.setStatusMessage("Interrupted rendering procedure")
      g_client.buffer.redraw = true
      g_client.buffer.reshape = false
      g_client.inputLoop())
    client.buffer.refreshBuffer()
    try:
      client.input()
    except ActionError as e:
      client.buffer.setStatusMessage(e.msg)

proc launchClient*(client: Client, pages: seq[string], ctype: string, dump: bool) =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    eprint "Failed to initialize libcurl."
    quit(1)
  client.userstyle = gconfig.stylesheet.parseStylesheet()
  if not stdin.isatty:
    client.readPipe(ctype)
  try:
    for page in pages:
      client.loadUrl(page, ctype)
  except LoadError as e:
    eprint e.msg
    quit(1)

  if stdout.isatty and not dump: client.inputLoop()
  else:
    var buffer = client.buffer
    while buffer.next != nil:
      buffer = buffer.next

    buffer.drawBuffer()
    while buffer.prev != nil:
      buffer = buffer.prev
      buffer.drawBuffer()
