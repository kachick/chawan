import options
import streams
import strformat
import unicode

when defined(posix):
  import posix

import buffer/buffer
import buffer/cell
import config/bufferconfig
import config/config
import io/request
import io/window
import ips/forkserver
import ips/serialize
import ips/socketstream
import js/javascript
import js/regex
import types/buffersource
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
    READ_LINE, OPEN, INVALID_COMMAND, STATUS, ALERT

  ContainerEvent* = object
    case t*: ContainerEventType
    of READ_LINE:
      prompt*: string
      value*: string
      password*: bool
    of OPEN:
      request*: Request
    of ANCHOR, NO_ANCHOR:
      anchor*: string
    of REDIRECT:
      location*: URL
    of ALERT:
      msg*: string
    else: discard

  Highlight* = ref object
    x*, y*: int
    endy*, endx*: int
    rect*: bool
    clear*: bool

  Container* = ref object
    iface*: BufferInterface
    attrs*: WindowAttributes
    width*: int
    height*: int
    contenttype*: Option[string]
    title*: string
    hovertext*: string
    source*: BufferSource
    children*: seq[Container]
    pos: CursorPosition
    bpos: seq[CursorPosition]
    highlights: seq[Highlight]
    parent*: Container
    process*: Pid
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
    events*: seq[ContainerEvent]

proc newBuffer*(dispatcher: Dispatcher, config: Config, source: BufferSource, title = ""): Container =
  let attrs = getWindowAttributes(stdout)
  let ostream = dispatcher.forkserver.ostream
  let istream = dispatcher.forkserver.istream
  ostream.swrite(FORK_BUFFER)
  ostream.swrite(source)
  ostream.swrite(config.loadBufferConfig())
  ostream.swrite(attrs)
  ostream.swrite(dispatcher.mainproc)
  ostream.flush()
  result = Container(
    source: source, attrs: attrs, width: attrs.width,
    height: attrs.height - 1, contenttype: source.contenttype,
    title: title
  )
  istream.sread(result.process)
  result.pos.setx = -1

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
func xend*(container: Container): int {.inline.} = container.pos.xend
func lastVisibleLine*(container: Container): int = min(container.fromy + container.height, container.numLines) - 1

func acursorx*(container: Container): int =
  max(0, container.cursorx - container.fromx)

func acursory*(container: Container): int =
  container.cursory - container.fromy

func currentLine*(container: Container): string =
  return container.getLine(container.cursory).str

func cursorBytes(container: Container, y: int, cc = container.cursorx): int =
  let line = container.getLine(y).str
  var w = 0
  var i = 0
  while i < line.len and w < cc:
    var r: Rune
    fastRuneAt(line, i, r)
    w += r.width()
  return i

func currentCursorBytes(container: Container, cc = container.cursorx): int =
  return container.cursorBytes(container.cursory, cc)

func prevWidth*(container: Container): int =
  if container.numLines == 0: return 0
  let line = container.currentLine
  if line.len == 0: return 0
  var w = 0
  var i = 0
  let cc = container.pos.fromx + container.pos.cursorx
  var pr: Rune
  var r: Rune
  fastRuneAt(line, i, r)
  while i < line.len and w < cc:
    pr = r
    fastRuneAt(line, i, r)
    w += r.width()
  return pr.width()

func currentWidth*(container: Container): int =
  if container.numLines == 0: return 0
  let line = container.currentLine
  if line.len == 0: return 0
  var w = 0
  var i = 0
  let cc = container.cursorx
  var r: Rune
  fastRuneAt(line, i, r)
  while i < line.len and w < cc:
    fastRuneAt(line, i, r)
    w += r.width()
  return r.width()

func maxScreenWidth(container: Container): int =
  for line in container.ilines(container.fromy..container.lastVisibleLine):
    result = max(line.str.width(), result)

func getTitle*(container: Container): string =
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

func lineInfo*(container: Container): string =
  fmt"line {container.cursory + 1}/{container.numLines} ({container.atPercentOf}%) col {container.cursorx + 1}/{container.currentLineWidth} (byte {container.currentCursorBytes})"

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

proc triggerEvent(container: Container, event: ContainerEvent) =
  container.events.add(event)

proc triggerEvent(container: Container, t: ContainerEventType) =
  container.triggerEvent(ContainerEvent(t: t))

proc updateCursor(container: Container)

proc requestLines*(container: Container, w = container.lineWindow) =
  container.iface.getLines(w).then(proc(res: seq[SimpleFlexibleLine]) =
    container.lines.setLen(w.len)
    container.lineshift = w.a
    for y in 0 ..< min(res.len, w.len):
      container.lines[y] = res[y]
    container.updateCursor()
    container.redraw = true
    let cw = container.fromy ..< container.fromy + container.height
    if w.a in cw or w.b in cw or cw.a in w or cw.b in w:
      container.triggerEvent(UPDATE))

proc redraw*(container: Container) {.jsfunc.} =
  container.redraw = true

proc sendCursorPosition*(container: Container) =
  container.iface.updateHover(container.cursorx, container.cursory).then(proc(res: UpdateHoverResult) =
    if res.hover.isSome:
      container.hovertext = res.hover.get
      container.triggerEvent(STATUS)
    if res.repaint:
      container.needslines = true)

proc setFromY*(container: Container, y: int) {.jsfunc.} =
  if container.pos.fromy != y:
    container.pos.fromy = max(min(y, container.maxfromy), 0)
    container.needslines = true
    container.redraw = true

proc setFromX*(container: Container, x: int) {.jsfunc.} =
  if container.pos.fromx != x:
    container.pos.fromx = max(min(x, container.maxfromx), 0)
    if container.pos.fromx > container.cursorx:
      container.pos.cursorx = min(container.pos.fromx, container.currentLineWidth())
      container.sendCursorPosition()
    container.redraw = true

proc setFromXY*(container: Container, x, y: int) {.jsfunc.} =
  container.setFromY(y)
  container.setFromX(x)

proc setCursorX*(container: Container, x: int, refresh = true, save = true) {.jsfunc.} =
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
      container.setFromX(x)
    container.pos.cursorx = container.fromx
  elif x > container.cursorx:
    container.setFromX(max(x - container.width + 1, container.fromx))
    container.pos.cursorx = x
  elif x < container.cursorx:
    container.setFromX(x)
    container.pos.cursorx = x
  container.sendCursorPosition()
  if save:
    container.pos.xend = container.cursorx

proc restoreCursorX(container: Container) {.jsfunc.} =
  container.setCursorX(max(min(container.currentLineWidth() - 1, container.xend), 0), false, false)

proc setCursorY*(container: Container, y: int) {.jsfunc.} =
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
  container.sendCursorPosition()
  container.restoreCursorX()

proc centerLine*(container: Container) {.jsfunc.} =
  container.setFromY(container.cursory - container.height div 2)

proc setCursorXY*(container: Container, x, y: int) {.jsfunc.} =
  let fy = container.fromy
  container.setCursorY(y)
  container.setCursorX(x)
  if fy != container.fromy:
    container.centerLine()

proc cursorDown*(container: Container) {.jsfunc.} =
  container.setCursorY(container.cursory + 1)

proc cursorUp*(container: Container) {.jsfunc.} =
  container.setCursorY(container.cursory - 1)

proc cursorLeft*(container: Container) {.jsfunc.} =
  var w = container.prevWidth()
  if w == 0:
    w = 1
  container.setCursorX(container.cursorx - w)

proc cursorRight*(container: Container) {.jsfunc.} =
  container.setCursorX(container.cursorx + container.currentWidth())

proc cursorLineBegin*(container: Container) {.jsfunc.} =
  container.setCursorX(0)

proc cursorLineEnd*(container: Container) {.jsfunc.} =
  container.setCursorX(container.currentLineWidth() - 1)

proc cursorNextWord*(container: Container) {.jsfunc.} =
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
    x += r.width()

  while b < container.currentLine.len:
    let pb = b
    fastRuneAt(container.currentLine, b, r)
    if not r.breaksWord():
      b = pb
      break
    x += r.width()

  if b < container.currentLine.len:
    container.setCursorX(x)
  else:
    if container.cursory < container.numLines - 1:
      container.cursorDown()
      container.cursorLineBegin()
    else:
      container.cursorLineEnd()

proc cursorPrevWord*(container: Container) {.jsfunc.} =
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
      x -= r.width()

    while b >= 0:
      let (r, o) = lastRune(container.currentLine, b)
      if not r.breaksWord():
        break
      b -= o
      x -= r.width()
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

proc pageDown*(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy + container.height)
  container.setCursorY(container.cursory + container.height)
  container.restoreCursorX()

proc pageUp*(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy - container.height)
  container.setCursorY(container.cursory - container.height)
  container.restoreCursorX()

proc pageLeft*(container: Container) {.jsfunc.} =
  container.setFromX(container.fromx - container.width)

proc pageRight*(container: Container) {.jsfunc.} =
  container.setFromX(container.fromx + container.width)

proc halfPageUp*(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy - container.height div 2 + 1)
  container.setCursorY(container.cursory - container.height div 2 + 1)
  container.restoreCursorX()

proc halfPageDown*(container: Container) {.jsfunc.} =
  container.setFromY(container.fromy + container.height div 2 - 1)
  container.setCursorY(container.cursory + container.height div 2 - 1)
  container.restoreCursorX()

proc cursorFirstLine*(container: Container) {.jsfunc.} =
  container.setCursorY(0)

proc cursorLastLine*(container: Container) {.jsfunc.} =
  container.setCursorY(container.numLines - 1)

proc cursorTop*(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy)

proc cursorMiddle*(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy + (container.height - 2) div 2)

proc cursorBottom*(container: Container) {.jsfunc.} =
  container.setCursorY(container.fromy + container.height - 1)

proc cursorLeftEdge*(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx)

proc cursorVertMiddle*(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + (container.width - 2) div 2)

proc cursorRightEdge*(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + container.width - 1)

proc scrollDown*(container: Container) {.jsfunc.} =
  if container.fromy + container.height < container.numLines:
    container.setFromY(container.fromy + 1)
    if container.fromy > container.cursory:
      container.cursorDown()
  else:
    container.cursorDown()

proc scrollUp*(container: Container) {.jsfunc.} =
  if container.fromy > 0:
    container.setFromY(container.fromy - 1)
    if container.fromy + container.height <= container.cursory:
      container.cursorUp()
  else:
    container.cursorUp()

proc scrollRight*(container: Container) {.jsfunc.} =
  if container.fromx + container.width < container.maxScreenWidth():
    container.setFromX(container.fromx + 1)

proc scrollLeft*(container: Container) {.jsfunc.} =
  if container.fromx > 0:
    container.setFromX(container.fromx - 1)
    if container.cursorx < container.fromx:
      container.setCursorX(container.currentLineWidth() - 1)

proc updateCursor(container: Container) =
  if container.pos.setx > -1:
    container.setCursorX(container.pos.setx)
  if container.fromy > container.lastVisibleLine:
    container.setFromY(0)
    container.setCursorY(container.lastVisibleLine)
  if container.cursory >= container.numLines:
    container.pos.cursory = max(0, container.numLines - 1)
  if container.numLines == 0:
    container.pos.cursory = 0

proc pushCursorPos*(container: Container) =
  container.bpos.add(container.pos)

proc popCursorPos*(container: Container, nojump = false) =
  container.pos = container.bpos.pop()
  container.updateCursor()
  if not nojump:
    container.sendCursorPosition()
    container.needslines = true

proc cursorNextLink*(container: Container) {.jsfunc.} =
  container.iface
    .findNextLink(container.cursorx, container.cursory)
    .then(proc(res: tuple[x, y: int]) =
      container.setCursorXY(res.x, res.y))

proc cursorPrevLink*(container: Container) {.jsfunc.} =
  container.iface
    .findPrevLink(container.cursorx, container.cursory)
    .then(proc(res: tuple[x, y: int]) =
      container.setCursorXY(res.x, res.y))

proc clearSearchHighlights*(container: Container) =
  for i in countdown(container.highlights.high, 0):
    if container.highlights[i].clear:
      container.highlights.del(i)

proc cursorNextMatch*(container: Container, regex: Regex, wrap: bool) {.jsfunc.} =
  container.iface
    .findNextMatch(regex, container.cursorx, container.cursory, wrap)
    .then(proc(res: BufferMatch) =
      if container.hlon:
        container.setCursorXY(res.x, res.y)
        container.clearSearchHighlights()
        let ex = res.x + res.str.width() - 1
        let hl = Highlight(x: res.x, y: res.y, endx: ex, endy: res.y, clear: true)
        container.highlights.add(hl)
        container.hlon = false)

proc cursorPrevMatch*(container: Container, regex: Regex, wrap: bool) {.jsfunc.} =
  container.iface
    .findPrevMatch(regex, container.cursorx, container.cursory, wrap)
    .then(proc(res: BufferMatch) =
      if container.hlon:
        container.setCursorXY(res.x, res.y)
        container.clearSearchHighlights()
        let ex = res.x + res.str.width() - 1
        let hl = Highlight(x: res.x, y: res.y, endx: ex, endy: res.y, clear: true)
        container.highlights.add(hl)
        container.hlon = false)

proc setLoadInfo(container: Container, msg: string) =
  container.loadinfo = msg
  container.triggerEvent(STATUS)

proc setNumLines(container: Container, lines: int) =
  container.numLines = lines
  container.updateCursor()

proc alert(container: Container, msg: string) =
  container.triggerEvent(ContainerEvent(t: ALERT, msg: msg))

proc onload(container: Container, res: tuple[atend: bool, lines, bytes: int]) =
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
      discard container.iface.load().then(proc(res: tuple[atend: bool, lines, bytes: int]) =
        container.onload(res))
    else:
      container.iface.render().then(proc(lines: int): auto =
        container.setNumLines(lines)
        container.needslines = true
        return container.iface.gotoAnchor()
      ).then(proc(res: tuple[x, y: int]) =
        if res.x != -1 and res.y != -1:
          container.setCursorXY(res.x, res.y))

proc load*(container: Container) =
  container.setLoadInfo("Connecting to " & $container.source.location & "...")
  container.iface.connect().then(proc(res: ConnectResult): auto =
    let info = container.loadinfo
    if res.code != -2:
      container.code = res.code
      if res.code == 0:
        container.triggerEvent(SUCCESS)
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
  container.iface.readCanceled()

proc readSuccess*(container: Container, s: string) =
  container.iface.readSuccess(s).then(proc(res: ReadSuccessResult) =
    if res.repaint:
      container.needslines = true
    if res.open.isSome:
      container.triggerEvent(ContainerEvent(t: OPEN, request: res.open.get)))

proc reshape*(container: Container, noreq = false) {.jsfunc.} =
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
  container.pipeto = dispatcher.newBuffer(config, source, container.title)
  container.iface.getSource().then(proc() =
    if container.pipeto != nil:
      container.pipeto.load()
      container.pipeto = nil)
  return container.pipeto

proc click*(container: Container) {.jsfunc.} =
  container.iface.click(container.cursorx, container.cursory).then(proc(res: ClickResult) =
    if res.repaint:
      container.needslines = true
    if res.open.isSome:
      container.triggerEvent(ContainerEvent(t: OPEN, request: res.open.get))
    if res.readline.isSome:
      let rl = res.readline.get
      container.triggerEvent(
        ContainerEvent(
          t: READ_LINE,
          prompt: rl.prompt,
          value: rl.value,
          password: rl.hide)))

proc windowChange*(container: Container, attrs: WindowAttributes) =
  container.attrs = attrs
  container.width = attrs.width
  container.height = attrs.height - 1
  container.iface.windowChange(attrs).then(proc() =
    container.needslines = true)

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

# Synchronously read all lines in the buffer.
iterator readLines*(container: Container): SimpleFlexibleLine {.inline.} =
  while container.iface.hasPromises:
    # Spin event loop till container has been loaded
    container.handleCommand()
  if container.code == 0:
    # load succeded
    discard container.iface.getLines(0 .. -1)
    var plen, len, packetid: int
    container.iface.stream.sread(plen)
    container.iface.stream.sread(packetid)
    container.iface.stream.sread(len)
    var line: SimpleFlexibleLine
    for y in 0 ..< len:
      container.iface.stream.sread(line)
      yield line

proc handleEvent*(container: Container) =
  container.handleCommand()
  if container.needslines:
    container.requestLines()
    container.needslines = false

proc addContainerModule*(ctx: JSContext) =
  ctx.registerType(Container, name = "Buffer")
