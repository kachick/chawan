import httpclient
import streams
import uri
import terminal
import os

import io/buffer
import io/lineedit
import config/config
import html/parser
import utils/twtstr
#import types/url

type
  Client* = ref object
    http: HttpClient
    buffers: seq[Buffer]
    currentbuffer: int
    feednext: bool
    s: string

proc die() =
  eprint "Invalid parameters. Usage:\ntwt <url>"
  quit(1)

proc newClient*(): Client =
  new(result)
  result.http = newHttpClient()
  result.currentbuffer = -1

func pbuffer(client: Client): Buffer =
  if client.currentbuffer > 0:
    return client.buffers[client.currentbuffer - 1]
  return nil

func buffer(client: Client): Buffer =
  return client.buffers[client.currentbuffer]

func nbuffer(client: Client): Buffer =
  if client.currentbuffer < client.buffers.len - 1:
    return client.buffers[client.currentbuffer + 1]
  return nil

func puri(client: Client): Uri =
  if client.currentbuffer > 0:
    return client.pbuffer.location

proc loadRemotePage*(client: Client, url: string): string =
  return client.http.getContent(url)

proc loadLocalPage*(url: string): string =
  return readFile(url)

proc getRemotePage*(client: Client, url: string): Stream =
  return client.http.get(url).bodyStream

proc getLocalPage*(url: string): Stream =
  return newFileStream(url, fmRead)

proc getPageUri(client: Client, uri: Uri): Stream =
  var moduri = uri
  if moduri.scheme == "file":
    moduri.scheme = ""
    return getLocalPage($moduri)
  elif moduri.scheme == "http" or moduri.scheme == "https":
    return client.getRemotePage($moduri)

proc addBuffer(client: Client) =
  inc client.currentbuffer
  client.buffers.insert(newBuffer(), client.currentbuffer)

proc prevBuffer(client: Client) =
  if client.currentbuffer > 0:
    dec client.currentbuffer
    client.buffer.redraw = true

proc nextBuffer(client: Client) =
  if client.currentbuffer < client.buffers.len - 1:
    inc client.currentbuffer
    client.buffer.redraw = true

proc discardBuffer(client: Client) =
  if client.currentbuffer < client.buffers.len - 1:
    client.buffers.delete(client.currentbuffer)
    client.buffer.redraw = true
  elif client.currentbuffer > 0:
    client.buffers.delete(client.currentbuffer)
    dec client.currentbuffer
    client.buffer.redraw = true
  else:
    client.buffer.setStatusMessage("Can't discard last buffer!")

proc setupBuffer(client: Client) =
  let buffer = client.buffer
  buffer.document = parseHtml(newStringStream(client.buffer.source))
  buffer.render()
  buffer.gotoAnchor()
  buffer.redraw = true

proc readPipe(client: Client) =
  client.addBuffer()
  if not stdin.isatty:
    client.buffer.showsource = true
    try:
      while true:
        client.buffer.source &= stdin.readChar()
    except EOFError:
      #TODO handle failure (also, is this even portable at all?)
      discard reopen(stdin, "/dev/tty", fmReadWrite);
  else:
    die()
  client.setupBuffer()

proc mergeURLs(client: Client, urla, urlb: Uri): Uri =
  var moduri = urlb
  if moduri.scheme == "":
    moduri.scheme = urla.scheme
  if moduri.scheme == "":
    moduri.scheme = "file"
  if moduri.hostname == "":
    moduri.hostname = urla.hostname
    if moduri.path == "":
      moduri.path = urla.path
    elif urla.path != "":
      moduri.path = urla.path.splitFile().dir / moduri.path
  return moduri

proc gotoURL(client: Client, url: Uri) =
  var newuri = url
  client.addBuffer()
  newuri = client.mergeUrls(client.puri, newuri)
  let newanchor = newuri.anchor
  newuri.anchor = ""
  if client.puri != newuri or newanchor == "":
    let s = client.getPageUri(newuri)
    if s != nil:
      client.buffer.source = s.readAll() #TODO
    else:
      client.discardBuffer()
      client.buffer.setStatusMessage("Couldn't load " & $newuri)
      return
  elif newanchor != "":
    if not client.pbuffer.hasAnchor(newanchor):
      client.discardBuffer()
      client.buffer.setStatusMessage("Couldn't find anchor " & newanchor)
      return
    client.buffer.source = client.pbuffer.source
    newuri.anchor = newanchor
  client.buffer.setLocation(newuri)
  client.setupBuffer()

proc gotoURL(client: Client, url: string) =
  client.gotoURL(parseUri(url))

proc reloadPage(client: Client) =
  let buffer = client.buffer
  var location = buffer.location
  location.anchor = ""
  client.gotoURL(location)
  client.buffer.setCursorXY(client.pbuffer.cursorx, client.pbuffer.cursory)
  client.buffer.setFromXY(client.pbuffer.fromx, client.pbuffer.fromy)
  client.buffer.showsource = client.pbuffer.showsource

proc changeLocation(client: Client) =
  let buffer = client.buffer
  var url = $buffer.location
  print(HVP(buffer.height + 1, 1))
  print(EL())
  let status = readLine("URL: ", url, buffer.width)
  if status:
    client.gotoURL(url)

proc click(client: Client) =
  let s = client.buffer.click()
  if s != "":
    client.gotoURL(s)

proc toggleSource*(client: Client) =
  let buffer = client.buffer
  if buffer.sourcepair != nil:
    for i in 0..high(client.buffers):
      if client.buffers[i] == buffer.sourcepair:
        client.currentbuffer = i
        break
    eprint "Fatal error (???)"
  else:
    client.addBuffer()
    client.buffer.sourcepair = client.pbuffer
    client.buffer.source = client.pbuffer.source
    client.buffer.showsource = not client.pbuffer.showsource
    client.setupBuffer()

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
  of ACTION_QUIT:
    eraseScreen()
    print(HVP(0, 0))
    quit(0)
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

proc launchClient*(client: Client, params: seq[string]) =
  if params.len < 1:
    client.readPipe()
  else: 
    client.gotoURL(params[0])

  while true:
    client.buffer.refreshBuffer()
    client.input()
