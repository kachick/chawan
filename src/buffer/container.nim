import macros
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
import io/serialize
import io/window
import js/regex
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
    READ_LINE, OPEN

  ContainerEvent* = object
    case t*: ContainerEventType
    of READ_LINE:
      prompt*: string
      value*: string
      password*: bool
    of OPEN:
      request*: Request
    else: discard

  Highlight* = ref object
    x*, y*: int
    endy*, endx*: int
    rect*: bool
    clear*: bool

  Container* = ref object
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
    sourcepair*: Container
    istream*: Stream
    ostream*: Stream
    ifd*: FileHandle
    process: Pid
    lines: SimpleFlexibleGrid
    lineshift: int
    numLines*: int
    replace*: Container
    code*: int
    retry*: seq[URL]
    redirect*: Option[URL]
    ispipe: bool
    jump: bool
    hlon*: bool
    pipeto: Container
    tty: FileHandle
    redraw*: bool

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

proc newBuffer*(config: Config, source: BufferSource, tty: FileHandle, ispipe = false): Container =
  let attrs = getWindowAttributes(stdout)
  when defined(posix):
    var pipefd_in, pipefd_out: array[0..1, cint]
    if pipe(pipefd_in) == -1:
      raise newException(Defect, "Failed to open input pipe.")
    if pipe(pipefd_out) == -1:
      raise newException(Defect, "Failed to open output pipe.")
    let pid = fork()
    if pid == -1:
      raise newException(Defect, "Failed to fork buffer process")
    elif pid == 0:
      let bconfig = config.loadBufferConfig()
      discard close(tty)
      discard close(stdout.getFileHandle())
      # child process
      discard close(pipefd_in[1]) # close write
      discard close(pipefd_out[0]) # close read
      var readf, writef: File
      if not open(readf, pipefd_in[0], fmRead):
        raise newException(Defect, "Failed to open input handle")
      if not open(writef, pipefd_out[1], fmWrite):
        raise newException(Defect, "Failed to open output handle")
      discard c_setvbuf(readf, nil, IONBF, 0)
      launchBuffer(bconfig, source, attrs, readf, writef)
    else:
      discard close(pipefd_in[0]) # close read
      discard close(pipefd_out[1]) # close write
      var readf, writef: File
      if not open(writef, pipefd_in[1], fmWrite):
        raise newException(Defect, "Failed to open output handle")
      if not open(readf, pipefd_out[0], fmRead):
        raise newException(Defect, "Failed to open input handle")
      let istream = newFileStream(readf)
      # Disable buffering of the read end so epoll doesn't get stuck
      discard c_setvbuf(readf, nil, IONBF, 0)
      let ostream = newFileStream(writef)
      result = Container(istream: istream, ostream: ostream, source: source,
                         ifd: pipefd_out[0], process: pid, attrs: attrs,
                         width: attrs.width, height: attrs.height - 1,
                         contenttype: source.contenttype, ispipe: ispipe,
                         tty: tty)
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
  if container.ispipe:
    return "*pipe*"
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

macro writeCommand(container: Container, cmd: BufferCommand, args: varargs[typed]) =
  result = newStmtList()
  result.add(quote do: `container`.ostream.swrite(`cmd`))
  for arg in args:
    result.add(quote do: `container`.ostream.swrite(`arg`))
  result.add(quote do: `container`.ostream.flush())

proc requestLines*(container: Container, w = container.lineWindow) =
  container.writeCommand(GET_LINES, w)

proc setFromY*(container: Container, y: int) =
  if container.pos.fromy != y:
    container.pos.fromy = max(min(y, container.maxfromy), 0)
    container.requestLines()
    container.redraw = true

proc setFromX*(container: Container, x: int) =
  if container.pos.fromx != x:
    container.pos.fromx = max(min(x, container.maxfromx), 0)
    if container.pos.fromx > container.cursorx:
      container.pos.cursorx = min(container.pos.fromx, container.currentLineWidth())
      container.writeCommand(MOVE_CURSOR, container.cursorx, container.cursory)
    container.redraw = true

proc setFromXY*(container: Container, x, y: int) =
  container.setFromY(y)
  container.setFromX(x)

proc setCursorX*(container: Container, x: int, refresh = true, save = true) =
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
  container.writeCommand(MOVE_CURSOR, container.cursorx, container.cursory)
  if save:
    container.pos.xend = container.cursorx

proc restoreCursorX(container: Container) =
  container.setCursorX(max(min(container.currentLineWidth() - 1, container.xend), 0), false, false)

proc setCursorY*(container: Container, y: int) =
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
  container.writeCommand(MOVE_CURSOR, container.cursorx, container.cursory)
  container.restoreCursorX()

proc centerLine*(container: Container) =
  container.setFromY(container.cursory - container.height div 2)

proc setCursorXY*(container: Container, x, y: int) =
  let fy = container.fromy
  container.setCursorY(y)
  container.setCursorX(x)
  if fy != container.fromy:
    container.centerLine()

proc cursorDown*(container: Container) =
  container.setCursorY(container.cursory + 1)

proc cursorUp*(container: Container) =
  container.setCursorY(container.cursory - 1)

proc cursorLeft*(container: Container) =
  var w = container.prevWidth()
  if w == 0:
    w = 1
  container.setCursorX(container.cursorx - w)

proc cursorRight*(container: Container) =
  container.setCursorX(container.cursorx + container.currentWidth())

proc cursorLineBegin*(container: Container) =
  container.setCursorX(0)

proc cursorLineEnd*(container: Container) =
  container.setCursorX(container.currentLineWidth() - 1)

proc cursorNextWord*(container: Container) =
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

proc cursorPrevWord*(container: Container) =
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

proc pageDown*(container: Container) =
  container.setFromY(container.fromy + container.height)
  container.setCursorY(container.cursory + container.height)
  container.restoreCursorX()

proc pageUp*(container: Container) =
  container.setFromY(container.fromy - container.height)
  container.setCursorY(container.cursory - container.height)
  container.restoreCursorX()

proc pageLeft*(container: Container) =
  container.setFromX(container.fromx - container.width)

proc pageRight*(container: Container) =
  container.setFromX(container.fromx + container.width)

proc halfPageUp*(container: Container) =
  container.setFromY(container.fromy - container.height div 2 + 1)
  container.setCursorY(container.cursory - container.height div 2 + 1)
  container.restoreCursorX()

proc halfPageDown*(container: Container) =
  container.setFromY(container.fromy + container.height div 2 - 1)
  container.setCursorY(container.cursory + container.height div 2 - 1)
  container.restoreCursorX()

proc cursorFirstLine*(container: Container) =
  container.setCursorY(0)

proc cursorLastLine*(container: Container) =
  container.setCursorY(container.numLines - 1)

proc cursorTop*(container: Container) =
  container.setCursorY(container.fromy)

proc cursorMiddle*(container: Container) =
  container.setCursorY(container.fromy + (container.height - 2) div 2)

proc cursorBottom*(container: Container) =
  container.setCursorY(container.fromy + container.height - 1)

proc cursorLeftEdge*(container: Container) =
  container.setCursorX(container.fromx)

proc cursorVertMiddle*(container: Container) =
  container.setCursorX(container.fromx + (container.width - 2) div 2)

proc cursorRightEdge*(container: Container) =
  container.setCursorX(container.fromx + container.width - 1)

proc scrollDown*(container: Container) =
  if container.fromy + container.height < container.numLines:
    container.setFromY(container.fromy + 1)
    if container.fromy > container.cursory:
      container.cursorDown()
  else:
    container.cursorDown()

proc scrollUp*(container: Container) =
  if container.fromy > 0:
    container.setFromY(container.fromy - 1)
    if container.fromy + container.height <= container.cursory:
      container.cursorUp()
  else:
    container.cursorUp()

proc scrollRight*(container: Container) =
  if container.fromx + container.width < container.maxScreenWidth():
    container.setFromX(container.fromx + 1)

proc scrollLeft*(container: Container) =
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

proc sendCursorPosition*(container: Container) =
  container.writeCommand(MOVE_CURSOR, container.cursorx, container.cursory)
  container.requestLines()

proc popCursorPos*(container: Container, nojump = false) =
  container.pos = container.bpos.pop()
  container.updateCursor()
  if not nojump:
    container.writeCommand(MOVE_CURSOR, container.cursorx, container.cursory)
    container.requestLines()

macro proxy(fun: typed) =
  let name = fun[0] # sym
  let params = fun[3] # formalparams
  let retval = params[0] # sym
  var body = newStmtList()
  assert params.len >= 2 # return type, container
  var x = name.strVal.toScreamingSnakeCase()
  if x[^1] == '=':
    x = "SET_" & x[0..^2]
  let nup = ident(x)
  let container = params[1][0]
  body.add(quote do:
    `container`.ostream.swrite(`nup`))
  for c in params[2..^1]:
    let s = c[0] # sym e.g. url
    body.add(quote do:
      `container`.ostream.swrite(`s`))
  body.add(quote do:
    `container`.ostream.flush())
  if retval.kind != nnkEmpty:
    body.add(quote do:
      `container`.istream.sread(result))
  var params2: seq[NimNode]
  for x in params.children: params2.add(x)
  result = newProc(name, params2, body)

proc cursorNextLink*(container: Container) =
  container.writeCommand(FIND_NEXT_LINK, container.cursorx, container.cursory)
  container.jump = true

proc cursorPrevLink*(container: Container) =
  container.writeCommand(FIND_PREV_LINK, container.cursorx, container.cursory)
  container.jump = true

proc cursorNextMatch*(container: Container, regex: Regex, wrap: bool) =
  container.writeCommand(FIND_NEXT_MATCH, container.cursorx, container.cursory, regex, wrap)
  container.jump = true

proc cursorPrevMatch*(container: Container, regex: Regex, wrap: bool) =
  container.writeCommand(FIND_PREV_MATCH, container.cursorx, container.cursory, regex, wrap)
  container.jump = true

proc load*(container: Container) {.proxy.} = discard
proc gotoAnchor*(container: Container, anchor: string) {.proxy.} = discard
proc readCanceled*(container: Container) {.proxy.} = discard
proc readSuccess*(container: Container, s: string) {.proxy.} = discard

proc render*(container: Container, noreq = false) =
  container.writeCommand(RENDER)
  container.jump = true # may jump to anchor
  if not noreq:
    container.requestLines()

proc dupeBuffer*(container: Container, config: Config, location = none(URL), contenttype = none(string)): Container =
  let source = BufferSource(
    t: CLONE,
    location: location.get(container.source.location),
    contenttype: if contenttype.isSome: contenttype else: container.contenttype,
    clonepid: container.process,
  )
  container.pipeto = newBuffer(config, source, container.tty, container.ispipe)
  container.writeCommand(GET_SOURCE)
  return container.pipeto

proc click*(container: Container) =
  container.writeCommand(CLICK, container.cursorx, container.cursory)

proc windowChange*(container: Container, attrs: WindowAttributes) =
  container.attrs = attrs
  container.width = attrs.width
  container.height = attrs.height - 1
  container.writeCommand(WINDOW_CHANGE, attrs)

proc clearSearchHighlights*(container: Container) =
  for i in countdown(container.highlights.high, 0):
    if container.highlights[i].clear:
      container.highlights.del(i)

proc handleCommand(container: Container, cmd: ContainerCommand): ContainerEvent =
  case cmd
  of SET_LINES:
    var w: Slice[int]
    container.istream.sread(container.numLines)
    container.istream.sread(w)
    container.lines.setLen(w.len)
    container.lineshift = w.a
    for y in 0 ..< w.len:
      container.istream.sread(container.lines[y])
    container.updateCursor()
    let cw = container.fromy ..< container.fromy + container.height
    if w.a in cw or w.b in cw or cw.a in w or cw.b in w:
      return ContainerEvent(t: UPDATE)
  of SET_NEEDS_AUTH:
    return ContainerEvent(t: NEEDS_AUTH)
  of SET_CONTENT_TYPE:
    var ctype: string
    container.istream.sread(ctype)
    container.contenttype = some(ctype)
  of SET_REDIRECT:
    var redirect: URL
    container.istream.sread(redirect)
    container.redirect = some(redirect)
    return ContainerEvent(t: REDIRECT)
  of SET_TITLE:
    container.istream.sread(container.title)
  of SET_HOVER:
    container.istream.sread(container.hovertext)
  of LOAD_DONE:
    container.istream.sread(container.code)
    if container.code != 0:
      return ContainerEvent(t: FAIL)
    return ContainerEvent(t: SUCCESS)
  of ANCHOR_FOUND:
    return ContainerEvent(t: ANCHOR)
  of ANCHOR_FAIL:
    return ContainerEvent(t: FAIL)
  of READ_LINE:
    var prompt, str: string
    var pwd: bool
    container.istream.sread(prompt)
    container.istream.sread(str)
    container.istream.sread(pwd)
    return ContainerEvent(t: READ_LINE, prompt: prompt, value: str, password: pwd)
  of JUMP:
    var x, y, ex: int
    container.istream.sread(x)
    container.istream.sread(y)
    container.istream.sread(ex)
    if x != -1 and y != -1 and container.jump:
      if container.hlon:
        container.clearSearchHighlights()
        let hl = Highlight(x: x, y: y, endx: ex, endy: y, clear: true)
        container.highlights.add(hl)
        container.hlon = false
      container.setCursorXY(x, y)
      container.jump = false
  of OPEN:
    return ContainerEvent(t: OPEN, request: container.istream.readRequest())
  of SOURCE_READY:
    if container.pipeto != nil:
      container.pipeto.load()
  of RESHAPE:
    container.requestLines()

# Synchronously read all lines in the buffer.
iterator readLines*(container: Container): SimpleFlexibleLine {.inline.} =
  var cmd: ContainerCommand
  container.requestLines(0 .. -1)
  container.istream.sread(cmd)
  while cmd != SET_LINES:
    discard container.handleCommand(cmd)
    container.istream.sread(cmd)
  assert cmd == SET_LINES
  var w: Slice[int]
  container.istream.sread(container.numLines)
  container.istream.sread(w)
  var line: SimpleFlexibleLine
  for y in 0 ..< w.len:
    container.istream.sread(line)
    yield line

proc handleEvent*(container: Container): ContainerEvent =
  var cmd: ContainerCommand
  container.istream.sread(cmd)
  return container.handleCommand(cmd)
