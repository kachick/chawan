import deques
import options
import streams
import strformat
import strutils
import unicode

when defined(posix):
  import posix

import buffer/buffer
import buffer/cell
import config/config
import io/request
import io/window
import ips/forkserver
import ips/serialize
import ips/socketstream
import js/javascript
import js/regex
import types/buffersource
import types/cookie
import types/dispatcher
import types/url
import utils/twtstr

type
  CursorPosition* = object
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    setx: int

  ContainerEventType* = enum
    NO_EVENT, FAIL, SUCCESS, NEEDS_AUTH, REDIRECT, ANCHOR, NO_ANCHOR, UPDATE,
    READ_LINE, READ_AREA, OPEN, INVALID_COMMAND, STATUS, ALERT, LOADED

  ContainerEvent* = object
    case t*: ContainerEventType
    of READ_LINE:
      prompt*: string
      value*: string
      password*: bool
    of READ_AREA:
      tvalue*: string
    of OPEN:
      request*: Request
    of ANCHOR, NO_ANCHOR:
      anchor*: string
    of REDIRECT:
      location*: URL
    of ALERT:
      msg*: string
    of UPDATE:
      force*: bool
    else: discard

  Highlight* = ref object
    x*, y*: int
    endy*, endx*: int
    rect*: bool
    clear*: bool

  Container* = ref object
    parent* {.jsget.}: Container
    children* {.jsget.}: seq[Container]
    config*: BufferConfig
    iface*: BufferInterface
    attrs: WindowAttributes
    width* {.jsget.}: int
    height* {.jsget.}: int
    contenttype* {.jsget.}: Option[string]
    title: string
    hovertext: array[HoverType, string]
    lastpeek: HoverType
    source*: BufferSource
    pos: CursorPosition
    bpos: seq[CursorPosition]
    highlights: seq[Highlight]
    process* {.jsget.}: Pid
    loadinfo*: string
    lines: SimpleFlexibleGrid
    lineshift: int
    numLines*: int
    replace*: Container
    code*: int
    retry*: seq[URL]
    hlon*: bool
    sourcepair*: Container
    pipeto: Container
    redraw*: bool
    needslines*: bool
    canceled: bool
    events*: Deque[ContainerEvent]
    startpos: Option[CursorPosition]
    hasstart: bool
    redirectdepth*: int

proc newBuffer*(dispatcher: Dispatcher, config: BufferConfig,
                source: BufferSource, title = "", redirectdepth = 0): Container =
  let attrs = getWindowAttributes(stdout)
  let ostream = dispatcher.forkserver.ostream
  let istream = dispatcher.forkserver.istream
  ostream.swrite(FORK_BUFFER)
  ostream.swrite(source)
  ostream.swrite(config)
  ostream.swrite(attrs)
  ostream.swrite(dispatcher.mainproc)
  ostream.flush()
  result = Container(
    source: source, attrs: attrs, width: attrs.width,
    height: attrs.height - 1, contenttype: source.contenttype,
    title: title, config: config, redirectdepth: redirectdepth
  )
  istream.sread(result.process)
  result.pos.setx = -1

func location*(container: Container): URL {.jsfunc.} =
  container.source.location

func lineLoaded(container: Container, y: int): bool =
  return y - container.lineshift in 0..container.lines.high

func getLine(container: Container, y: int): SimpleFlexibleLine =
  if container.lineLoaded(y):
    return container.lines[y - container.lineshift]

iterator ilines*(container: Container, slice: Slice[int]): SimpleFlexibleLine {.inline.} =
  for y in slice:
    yield container.getLine(y)

func cursorx*(container: Container): int {.inline.} = container.pos.cursorx
func cursory*(container: Container): int {.inline.} = container.pos.cursory
func fromx*(container: Container): int {.inline.} = container.pos.fromx
func fromy*(container: Container): int {.inline.} = container.pos.fromy
func xend(container: Container): int {.inline.} = container.pos.xend
func lastVisibleLine(container: Container): int = min(container.fromy + container.height, container.numLines) - 1

func currentLine(container: Container): string =
  return container.getLine(container.cursory).str

func cursorBytes(container: Container, y: int, cc = container.cursorx): int =
  let line = container.getLine(y).str
  var w = 0
  var i = 0
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.twidth(w)
  return i

func currentCursorBytes(container: Container, cc = container.cursorx): int =
  return container.cursorBytes(container.cursory, cc)

# Returns the X position of the first cell occupied by the character the cursor
# currently points to.
func cursorFirstX(container: Container): int =
  if container.numLines == 0: return 0
  let line = container.currentLine
  var w = 0
  var i = 0
  var r: Rune
  let cc = container.cursorx
  while i < line.len:
    fastRuneAt(line, i, r)
    let tw = r.twidth(w)
    if w + tw > cc:
      return w
    w += tw

# Returns the X position of the last cell occupied by the character the cursor
# currently points to.
func cursorLastX(container: Container): int =
  if container.numLines == 0: return 0
  let line = container.currentLine
  var w = 0
  var i = 0
  var r: Rune
  let cc = container.cursorx
  while i < line.len and w <= cc:
    fastRuneAt(line, i, r)
    w += r.twidth(w)
  return max(w - 1, 0)

func acursorx*(container: Container): int =
  max(0, container.cursorLastX() - container.fromx)

func acursory*(container: Container): int =
  container.cursory - container.fromy

func maxScreenWidth(container: Container): int =
  for line in container.ilines(container.fromy..container.lastVisibleLine):
    result = max(line.str.width(), result)

func getTitle*(container: Container): string {.jsfunc.} =
  if container.title != "":
    return container.title
  return container.source.location.serialize(excludepassword = true)

func currentLineWidth(container: Container): int =
  if container.numLines == 0: return 0
  return container.currentLine.width()

func maxfromy(container: Container): int = max(container.numLines - container.height, 0)

func maxfromx(container: Container): int = max(container.maxScreenWidth() - container.width, 0)

func atPercentOf*(container: Container): int =
  if container.numLines == 0: return 100
  return (100 * (container.cursory + 1)) div container.numLines

func lineWindow(container: Container): Slice[int] =
  if container.numLines == 0: # not loaded
    return 0..container.height * 5
  let n = (container.height * 5) div 2
  var x = container.fromy - n + container.height div 2
  var y = container.fromy + n + container.height div 2
  if y >= container.numLines:
    x -= y - container.numLines
    y = container.numLines
  if x < 0:
    y += -x
    x = 0
  return x .. y

func contains*(hl: Highlight, x, y: int): bool =
  if hl.rect:
    let rx = hl.x .. hl.endx
    let ry = hl.y .. hl.endy
    return x in rx and y in ry
  else:
    return (y > hl.y or y == hl.y and x >= hl.x) and
      (y < hl.endy or y == hl.endy and x <= hl.endx)

func contains*(hl: Highlight, y: int): bool =
  return y in hl.y .. hl.endy

func colorArea*(hl: Highlight, y: int, limitx: Slice[int]): Slice[int] =
  if hl.rect:
    if y in hl.y .. hl.endy:
      return max(hl.x, limitx.a) .. min(hl.endx, limitx.b)
  else:
    if y in hl.y + 1 .. hl.endy - 1:
      return limitx
    if y == hl.y and y == hl.endy:
      return max(hl.x, limitx.a) .. min(hl.endx, limitx.b)
    if y == hl.y:
      return max(hl.x, limitx.a) .. limitx.b
    if y == hl.endy:
      return limitx.a .. min(hl.endx, limitx.b)

func findHighlights*(container: Container, y: int): seq[Highlight] =
  for hl in container.highlights:
    if y in hl:
      result.add(hl)

func getHoverText*(container: Container): string =
  for t in HoverType:
    if container.hovertext[t] != "":
      return container.hovertext[t]

proc triggerEvent(container: Container, event: ContainerEvent) =
  container.events.addLast(event)

proc triggerEvent(container: Container, t: ContainerEventType) =
  container.triggerEvent(ContainerEvent(t: t))

proc updateCursor(container: Container)

proc setNumLines(container: Container, lines: int, finish = false) =
  if container.numLines != lines:
    container.numLines = lines
    if container.startpos.isSome and finish:
      container.pos = container.startpos.get
      container.startpos = none(CursorPosition)
    container.updateCursor()
    container.triggerEvent(STATUS)

proc requestLines*(container: Container, w = container.lineWindow): auto {.discardable.} =
  container.iface.getLines(w).then(proc(res: tuple[numLines: int, lines: seq[SimpleFlexibleLine]]) =
    container.lines.setLen(w.len)
    container.lineshift = w.a
    for y in 0 ..< min(res.lines.len, w.len):
      container.lines[y] = res.lines[y]
      container.lines[y].str.mnormalize()
    container.updateCursor()
    if res.numLines != container.numLines:
      container.setNumLines(res.numLines, true)
    let cw = container.fromy ..< container.fromy + container.height
    if w.a in cw or w.b in cw or cw.a in w or cw.b in w:
      container.triggerEvent(UPDATE))

proc redraw(container: Container) {.jsfunc.} =
  container.triggerEvent(ContainerEvent(t: UPDATE, force: true))

proc sendCursorPosition(container: Container) =
  container.iface.updateHover(container.cursorx, container.cursory).then(proc(res: UpdateHoverResult) =
    if res.link.isSome:
      container.hovertext[HOVER_LINK] = res.link.get
    if res.title.isSome:
      container.hovertext[HOVER_TITLE] = res.title.get
    if res.link.isSome or res.title.isSome:
      container.triggerEvent(STATUS)
    if res.repaint:
      container.needslines = true)

proc setFromY(container: Container, y: int) {.jsfunc.} =
  if container.pos.fromy != y:
    container.pos.fromy = max(min(y, container.maxfromy), 0)
    container.needslines = true
    container.triggerEvent(UPDATE)

proc setFromX(container: Container, x: int, refresh = true) {.jsfunc.} =
  if container.pos.fromx != x:
    container.pos.fromx = max(min(x, container.maxfromx), 0)
    if container.pos.fromx > container.cursorx:
      container.pos.cursorx = min(container.pos.fromx, container.currentLineWidth())
      if refresh:
        container.sendCursorPosition()
    container.triggerEvent(UPDATE)

proc setFromXY(container: Container, x, y: int) {.jsfunc.} =
  container.setFromY(y)
  container.setFromX(x)

proc setCursorX(container: Container, x: int, refresh = true, save = true) {.jsfunc.} =
  if not container.lineLoaded(container.cursory):
    container.pos.setx = x
    return
  container.pos.setx = -1
  let cw = container.currentLineWidth()
  let x2 = x
  let x = max(min(x, cw - 1), 0)
  if not refresh or container.fromx <= x and x < container.fromx + container.width:
    container.pos.cursorx = x
  elif refresh and container.fromx > x:
    if x2 < container.cursorx:
      container.setFromX(x, false)
    container.pos.cursorx = container.fromx
  elif x > container.cursorx:
    container.setFromX(max(x - container.width + 1, container.fromx), false)
    container.pos.cursorx = x
  elif x < container.cursorx:
    container.setFromX(x, false)
    container.pos.cursorx = x
  if refresh:
    container.sendCursorPosition()
  if save:
    container.pos.xend = container.cursorx

proc restoreCursorX(container: Container) {.jsfunc.} =
  container.setCursorX(max(min(container.currentLineWidth() - 1, container.xend), 0), false, false)

proc setCursorY(container: Container, y: int) {.jsfunc.} =
  let y = max(min(y, container.numLines - 1), 0)
  if container.cursory == y: return
  if y - container.fromy >= 0 and y - container.height < container.fromy:
    container.pos.cursory = y
  else:
    if y > container.cursory:
      container.setFromY(y - container.height + 1)
    else:
      container.setFromY(y)
    container.pos.cursory = y
  container.restoreCursorX()
  container.sendCursorPosition()

proc centerLine(container: Container) {.jsfunc.} =
  container.setFromY(container.cursory - container.height div 2)

proc centerColumn(container: Container) {.jsfunc.} =
  container.setFromX(container.cursorx - container.width div 2)

proc setCursorXY(container: Container, x, y: int) {.jsfunc.} =
  let fy = container.fromy
  container.setCursorY(y)
  container.setCursorX(x)
  if fy != container.fromy:
    container.centerLine()

proc cursorDown(container: Container) {.jsfunc.} =
  container.setCursorY(container.cursory + 1)

proc cursorUp(container: Container) {.jsfunc.} =
  container.setCursorY(container.cursory - 1)

proc cursorLeft(container: Container) {.jsfunc.} =
  container.setCursorX(container.cursorFirstX() - 1)

proc cursorRight(container: Container) {.jsfunc.} =
  container.setCursorX(container.cursorLastX() + 1)

proc cursorLineBegin(container: Container) {.jsfunc.} =
  container.setCursorX(0)

proc cursorLineEnd(container: Container) {.jsfunc.} =
  container.setCursorX(container.currentLineWidth() - 1)

proc cursorNextWord(container: Container) {.jsfunc.} =
  if container.numLines == 0: return
  var r: Rune
  var b = container.currentCursorBytes()
  var x = container.cursorx
  while b < container.currentLine.len:
    let pb = b
    fastRuneAt(container.currentLine, b, r)
    if r.breaksWord():
      b = pb
      break
    x += r.twidth(x)

  while b < container.currentLine.len:
    let pb = b
    fastRuneAt(container.currentLine, b, r)
    if not r.breaksWord():
      b = pb
      break
    x += r.twidth(x)

  if b < container.currentLine.len:
    container.setCursorX(x)
  else:
    if container.cursory < container.numLines - 1:
      container.cursorDown()
      container.cursorLineBegin()
    else:
      container.cursorLineEnd()

proc cursorPrevWord(container: Container) {.jsfunc.} =
  if container.numLines == 0: return
  var b = container.currentCursorBytes()
  var x = container.cursorx
  if container.currentLine.len > 0:
    b = min(b, container.currentLine.len - 1)
    while b >= 0:
      let (r, o) = lastRune(container.currentLine, b)
      if r.breaksWord():
        break
      b -= o
      x -= r.twidth(x)

    while b >= 0:
      let (r, o) = lastRune(container.currentLine, b)
      if not r.breaksWord():
        break
      b -= o
      x -= r.twidth(x)
  else:
    b = -1

  if b >= 0:
    container.setCursorX(x)
  else:
    if container.cursory > 0:
      container.cursorUp()
      container.cursorLineEnd()
    else:
      container.cursorLineBegin()

proc pageDown(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy + container.height)
  container.setCursorY(container.cursory + container.height)
  container.restoreCursorX()

proc pageUp(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy - container.height)
  container.setCursorY(container.cursory - container.height)
  container.restoreCursorX()

proc pageLeft(container: Container) {.jsfunc.} =
  container.setFromX(container.fromx - container.width)

proc pageRight(container: Container) {.jsfunc.} =
  container.setFromX(container.fromx + container.width)

proc halfPageUp(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy - container.height div 2 + 1)
  container.setCursorY(container.cursory - container.height div 2 + 1)
  container.restoreCursorX()

proc halfPageDown(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy + container.height div 2 - 1)
  container.setCursorY(container.cursory + container.height div 2 - 1)
  container.restoreCursorX()

proc cursorFirstLine(container: Container) {.jsfunc.} =
  container.setCursorY(0)

proc cursorLastLine*(container: Container) {.jsfunc.} =
  container.setCursorY(container.numLines - 1)

proc cursorTop(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy)

proc cursorMiddle(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy + (container.height - 2) div 2)

proc cursorBottom(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy + container.height - 1)

proc cursorLeftEdge(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx)

proc cursorMiddleColumn(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + (container.width - 2) div 2)

proc cursorRightEdge(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + container.width - 1)

proc scrollDown(container: Container) {.jsfunc.} =
  if container.fromy + container.height < container.numLines:
    container.setFromY(container.fromy + 1)
    if container.fromy > container.cursory:
      container.cursorDown()
  else:
    container.cursorDown()

proc scrollUp(container: Container) {.jsfunc.} =
  if container.fromy > 0:
    container.setFromY(container.fromy - 1)
    if container.fromy + container.height <= container.cursory:
      container.cursorUp()
  else:
    container.cursorUp()

proc scrollRight(container: Container) {.jsfunc.} =
  if container.fromx + container.width < container.maxScreenWidth():
    container.setFromX(container.fromx + 1)

proc scrollLeft(container: Container) {.jsfunc.} =
  if container.fromx > 0:
    container.setFromX(container.fromx - 1)
    if container.cursorx < container.fromx:
      container.setCursorX(container.currentLineWidth() - 1)

proc alert(container: Container, msg: string) =
  container.triggerEvent(ContainerEvent(t: ALERT, msg: msg))

proc lineInfo(container: Container) {.jsfunc.} =
  container.alert(fmt"line {container.cursory + 1}/{container.numLines} ({container.atPercentOf}%) col {container.cursorx + 1}/{container.currentLineWidth} (byte {container.currentCursorBytes})")

proc updateCursor(container: Container) =
  if container.pos.setx > -1:
    container.setCursorX(container.pos.setx)
  if container.fromy > container.maxfromy:
    container.setFromY(container.maxfromy)
  if container.cursory >= container.numLines:
    container.setCursorY(container.lastVisibleLine)
    container.alert("Last line is #" & $container.numLines)

proc gotoLine*[T: string|int](container: Container, s: T) =
  when s is string:
    if s == "":
      redraw(container)
    elif s[0] == '^':
      container.cursorFirstLine()
    elif s[0] == '$':
      container.cursorLastLine()
    else:
      try:
        let i = parseInt(s)
        container.setCursorY(i)
      except ValueError:
        container.alert("First line is #1") # :)
  else:
    container.setCursorY(s)

proc pushCursorPos*(container: Container) =
  container.bpos.add(container.pos)

proc popCursorPos*(container: Container, nojump = false) =
  container.pos = container.bpos.pop()
  if not nojump:
    container.updateCursor()
    container.sendCursorPosition()
    container.needslines = true

proc copyCursorPos*(container, c2: Container) =
  container.startpos = some(c2.pos)
  container.hasstart = true

proc cursorNextLink*(container: Container) {.jsfunc.} =
  container.iface
    .findNextLink(container.cursorx, container.cursory)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXY(res.x, res.y))

proc cursorPrevLink*(container: Container) {.jsfunc.} =
  container.iface
    .findPrevLink(container.cursorx, container.cursory)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXY(res.x, res.y))

proc clearSearchHighlights*(container: Container) =
  for i in countdown(container.highlights.high, 0):
    if container.highlights[i].clear:
      container.highlights.del(i)

proc cursorNextMatch*(container: Container, regex: Regex, wrap: bool) {.jsfunc.} =
  container.iface
    .findNextMatch(regex, container.cursorx, container.cursory, wrap)
    .then(proc(res: BufferMatch) =
      if res.success:
        container.setCursorXY(res.x, res.y)
        if container.hlon:
          container.clearSearchHighlights()
          let ex = res.str.twidth(res.x) - 1
          let hl = Highlight(x: res.x, y: res.y, endx: ex, endy: res.y, clear: true)
          container.highlights.add(hl)
          container.triggerEvent(UPDATE)
          container.hlon = false
      elif container.hlon:
        container.clearSearchHighlights()
        container.triggerEvent(UPDATE)
        container.needslines = true
        container.hlon = false)

proc cursorPrevMatch*(container: Container, regex: Regex, wrap: bool) {.jsfunc.} =
  container.iface
    .findPrevMatch(regex, container.cursorx, container.cursory, wrap)
    .then(proc(res: BufferMatch) =
      if res.success:
        container.setCursorXY(res.x, res.y)
        if container.hlon:
          container.clearSearchHighlights()
          let ex = res.str.twidth(res.x) - 1
          let hl = Highlight(x: res.x, y: res.y, endx: ex, endy: res.y, clear: true)
          container.highlights.add(hl)
          container.hlon = false)

proc setLoadInfo(container: Container, msg: string) =
  container.loadinfo = msg
  container.triggerEvent(STATUS)

#TODO TODO TODO this should be called with a timeout.
proc onload(container: Container, res: LoadResult) =
  if container.canceled:
    container.setLoadInfo("")
    #TODO we wouldn't need the then part if we had incremental rendering of
    # HTML.
    container.iface.cancel().then(proc(lines: int) =
      container.setNumLines(lines)
      container.needslines = true)
  else:
    if res.bytes == -1 or res.atend:
      container.setLoadInfo("")
    elif not res.atend:
      container.setLoadInfo(convert_size(res.bytes) & " loaded")
    if res.lines > container.numLines:
      container.setNumLines(res.lines)
      container.triggerEvent(STATUS)
      container.needslines = true
    if not res.atend:
      discard container.iface.load().then(proc(res: LoadResult) =
        container.onload(res))
    else:
      container.iface.getTitle().then(proc(title: string): auto =
        if title != "":
          container.title = title
          container.triggerEvent(STATUS)
        return container.iface.render()
      ).then(proc(lines: int): auto =
        container.setNumLines(lines, true)
        container.needslines = true
        container.triggerEvent(LOADED)
        if not container.hasstart and container.source.location.anchor != "":
          return container.iface.gotoAnchor()
      ).then(proc(res: tuple[x, y: int]) =
        if res.x != -1 and res.y != -1:
          container.setCursorXY(res.x, res.y))

proc load(container: Container) =
  container.setLoadInfo("Connecting to " & $container.source.location & "...")
  container.iface.connect().then(proc(res: ConnectResult): auto =
    let info = container.loadinfo
    if res.code != -2:
      container.code = res.code
      if res.code == 0:
        container.triggerEvent(SUCCESS)
        if res.cookies.len > 0 and container.config.cookiejar != nil: # accept cookies
          container.config.cookiejar.cookies.add(res.cookies)
        if res.referrerpolicy.isSome and container.config.refererfrom:
          container.config.referrerpolicy = res.referrerpolicy.get
        container.setLoadInfo("Connected to " & $container.source.location & ". Downloading...")
        if res.needsAuth:
          container.triggerEvent(NEEDS_AUTH)
        if res.redirect.isSome:
          container.triggerEvent(ContainerEvent(t: REDIRECT, location: res.redirect.get))
        if res.contentType != "":
          container.contenttype = some(res.contentType)
        return container.iface.load()
      else:
        container.setLoadInfo("")
        container.triggerEvent(FAIL)
    else:
      container.setLoadInfo(info)
  ).then(proc(res: tuple[atend: bool, lines, bytes: int]) =
        container.onload(res))

proc cancel*(container: Container) {.jsfunc.} =
  container.canceled = true
  container.alert("Canceled loading")

proc findAnchor*(container: Container, anchor: string) =
  container.iface.findAnchor(anchor).then(proc(found: bool) =
    if found:
      container.triggerEvent(ContainerEvent(t: ANCHOR, anchor: anchor))
    else:
      container.triggerEvent(NO_ANCHOR))

proc readCanceled*(container: Container) =
  container.iface.readCanceled().then(proc(repaint: bool) =
    if repaint:
      container.needslines = true)

proc readSuccess*(container: Container, s: string) =
  container.iface.readSuccess(s).then(proc(res: ReadSuccessResult) =
    if res.repaint:
      container.needslines = true
    if res.open.isSome:
      container.triggerEvent(ContainerEvent(t: OPEN, request: res.open.get)))

proc reshape(container: Container, noreq = false) {.jsfunc.} =
  container.iface.render().then(proc(lines: int) =
    container.setNumLines(lines))
  if not noreq:
    container.needslines = true

proc dupeBuffer*(dispatcher: Dispatcher, container: Container, config: Config, location = none(URL), contenttype = none(string)): Container =
  let source = BufferSource(
    t: CLONE,
    location: location.get(container.source.location),
    contenttype: if contenttype.isSome: contenttype else: container.contenttype,
    clonepid: container.process,
  )
  container.pipeto = dispatcher.newBuffer(container.config, source, container.title)
  container.iface.getSource().then(proc() =
    if container.pipeto != nil:
      container.pipeto.load()
      container.pipeto = nil)
  return container.pipeto

proc click(container: Container) {.jsfunc.} =
  container.iface.click(container.cursorx, container.cursory).then(proc(res: ClickResult) =
    if res.repaint:
      container.needslines = true
    if res.open.isSome:
      container.triggerEvent(ContainerEvent(t: OPEN, request: res.open.get))
    if res.readline.isSome:
      let rl = res.readline.get
      if rl.area:
        container.triggerEvent(
          ContainerEvent(
            t: READ_AREA,
            tvalue: rl.value
          ))
      else:
        container.triggerEvent(
          ContainerEvent(
            t: READ_LINE,
            prompt: rl.prompt,
            value: rl.value,
            password: rl.hide
          )))

proc windowChange*(container: Container, attrs: WindowAttributes) =
  container.attrs = attrs
  if attrs.width != container.width or attrs.height - 1 != container.height:
    container.width = attrs.width
    container.height = attrs.height - 1
    container.iface.windowChange(attrs).then(proc(): auto =
      container.needslines = true
      return container.iface.render()
    ).then(proc(lines: int) =
      if lines != container.numLines:
        container.setNumLines(lines, true)
      container.needslines = true)

proc peek(container: Container) {.jsfunc.} =
  container.alert($container.source.location)

proc clearHover*(container: Container) =
  container.lastpeek = low(HoverType)

proc peekCursor(container: Container) {.jsfunc.} =
  var p = container.lastpeek
  while true:
    if container.hovertext[p] != "":
      container.alert($p & ": " & container.hovertext[p])
      break
    if p < high(HoverType):
      inc p
    else:
      p = low(HoverType)
    if p == container.lastpeek: break
  if container.lastpeek < high(HoverType):
    inc container.lastpeek
  else:
    container.lastpeek = low(HoverType)

proc handleCommand(container: Container) =
  var packetid, len: int
  container.iface.stream.sread(len)
  container.iface.stream.sread(packetid)
  container.iface.fulfill(packetid, len - slen(packetid))

proc setStream*(container: Container, stream: Stream) =
  container.iface = newBufferInterface(stream)
  if container.source.t == LOAD_PIPE:
    container.iface.passFd()
    let s = SocketStream(stream)
    s.sendFileHandle(container.source.fd)
    discard close(container.source.fd)
    stream.flush()
  container.load()

proc onreadline(container: Container, w: Slice[int], handle: (proc(line: SimpleFlexibleLine)), res: GetLinesResult) =
  for line in res.lines:
    handle(line)
  if res.numLines > w.b + 1:
    var w = w
    w.a = w.b
    w.b += 24
    container.iface.getLines(w).then(proc(res: GetLinesResult) =
      container.onreadline(w, handle, res))
  else:
    container.setNumLines(res.numLines, true)

# Synchronously read all lines in the buffer.
proc readLines*(container: Container, handle: (proc(line: SimpleFlexibleLine))) =
  if container.code == 0:
    # load succeded
    let w = 0 .. 24
    container.iface.getLines(w).then(proc(res: GetLinesResult) =
      container.onreadline(w, handle, res))
    while container.iface.hasPromises:
      # fulfill all promises
      container.handleCommand()

proc handleEvent*(container: Container) =
  container.handleCommand()
  if container.needslines:
    container.requestLines()
    container.needslines = false

proc addContainerModule*(ctx: JSContext) =
  ctx.registerType(Container, name = "Buffer")
