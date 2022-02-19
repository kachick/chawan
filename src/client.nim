import streams
import terminal
import options
import os

import css/sheet
import config/config
import io/buffer
import io/lineedit
import io/loader
import types/url
import utils/twtstr

type
  Client* = ref object
    buffer: Buffer
    feednext: bool
    s: string
    iserror: bool
    errormessage: string
    userstyle: CSSStylesheet
    loader: FileLoader

  ActionError = object of IOError
  LoadError = object of ActionError
  InterruptError = object of LoadError

proc newClient*(): Client =
  new(result)
  result.loader = newFileLoader()

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
        client.buffer.streamclosed = false
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
  client.gotoUrl(client.buffer.location, none(ClickAction), none(Url), true, false, client.buffer.contenttype)

proc changeLocation(client: Client) =
  let buffer = client.buffer
  var url = buffer.location.serialize(true)
  print(HVP(buffer.height + 1, 1))
  print(EL())
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

proc quit(client: Client) =
  eraseScreen()
  print(HVP(0, 0))
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
  client.userstyle = gconfig.stylesheet.parseStylesheet()
  if not stdin.isatty:
    client.readPipe(ctype)
  try:
    for page in pages:
      client.loadUrl(page, ctype)
  except LoadError as e:
    eprint(e.msg & '\n')
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
