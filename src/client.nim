import httpclient
import streams
import uri
import terminal

import io/buffer
import io/lineedit
import config/config
import html/parser
import utils/twtstr

type
  Client* = ref object
    http: HttpClient
    buffers: seq[Buffer]
    prevuri: Uri
    feednext: bool
    s: string

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
  moduri.anchor = ""
  if uri.scheme == "" or uri.scheme == "file":
    return getLocalPage($moduri)
  else:
    return client.getRemotePage($moduri)

proc die() =
  eprint "Invalid parameters. Usage:\ntwt <url>"
  quit(1)

proc newClient*(): Client =
  new(result)
  result.http = newHttpClient()

proc addBuffer(client: Client) =
  client.buffers.add(newBuffer())

func buffer(client: Client): Buffer =
  return client.buffers[^1]

proc setupBuffer*(client: Client) =
  let buffer = client.buffer
  buffer.setLocation(client.prevuri)
  buffer.document = parseHtml(newStringStream(client.buffer.source))
  buffer.render()
  buffer.gotoAnchor()
  buffer.redraw = true

proc readPipe(client: Client) =
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

proc gotoURL(client: Client, url: string) =
  var newuri = parseUri(url)
  let newanchor = newuri.anchor
  let prevanchor = client.prevuri.anchor
  client.prevuri.anchor = ""
  newuri.anchor = ""
  let prevs = $client.prevuri
  let news = $newuri
  client.prevuri.anchor = prevanchor
  newuri.anchor = newanchor
  if news != "":
    client.addBuffer()
    client.buffer.source = client.getPageUri(newuri).readAll() #TODO
  elif prevanchor != newanchor:
    let psource = client.buffer.source
    client.addBuffer()
    client.buffer.source = psource

  client.prevuri = newuri
  client.setupBuffer()

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
  of ACTION_RELOAD: client.gotoURL($buffer.location)
  of ACTION_RESHAPE: buffer.reshape = true
  of ACTION_REDRAW: buffer.redraw = true
  of ACTION_TOGGLE_SOURCE: buffer.toggleSource()
  else: discard

proc launchClient*(client: Client, params: seq[string]) =
  client.addBuffer()

  if params.len < 1:
    client.readPipe()
  else: 
    client.gotoURL(params[0])

  while true:
    client.buffer.refreshBuffer()
    client.input()
