import std/deques
import std/options
import std/streams
import std/unicode

when defined(posix):
  import std/posix

import config/config
import display/winattrs
import extern/stdio
import io/promise
import io/serialize
import js/dict
import js/javascript
import js/regex
import loader/connecterror
import loader/request
import local/select
import server/buffer
import server/forkserver
import types/buffersource
import types/cell
import types/color
import types/cookie
import types/url
import utils/luwrap
import utils/mimeguess
import utils/strwidth
import utils/twtstr

import chakasu/charset

type
  CursorPosition* = object
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    setx: int
    setxrefresh: bool

  ContainerEventType* = enum
    NO_EVENT, FAIL, SUCCESS, NEEDS_AUTH, REDIRECT, ANCHOR, NO_ANCHOR, UPDATE,
    READ_LINE, READ_AREA, OPEN, INVALID_COMMAND, STATUS, ALERT, LOADED, TITLE,
    CHECK_MAILCAP, QUIT

  ContainerEvent* = object
    case t*: ContainerEventType
    of READ_LINE:
      prompt*: string
      value*: string
      password*: bool
    of READ_AREA:
      tvalue*: string
    of OPEN, REDIRECT:
      request*: Request
    of ANCHOR, NO_ANCHOR:
      anchor*: string
    of ALERT:
      msg*: string
    of UPDATE:
      force*: bool
    else: discard

  HighlightType = enum
    HL_SEARCH, HL_SELECT

  SelectionType = enum
    SEL_NORMAL = "normal"
    SEL_BLOCK = "block"
    SEL_LINE = "line"

  Highlight = ref object
    case t: HighlightType
    of HL_SEARCH: discard
    of HL_SELECT:
      selectionType {.jsget.}: SelectionType
    x1, y1: int
    x2, y2: int

  PagePos = tuple
    x: int
    y: int

  Container* = ref object
    parent* {.jsget.}: Container
    children* {.jsget.}: seq[Container]
    config*: BufferConfig
    iface*: BufferInterface
    width* {.jsget.}: int
    height* {.jsget.}: int
    title*: string # used in status msg
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
    code*: int # note: this is not the status code, but the ConnectErrorCode.
    errorMessage*: string
    retry*: seq[URL]
    hlon*: bool # highlight on?
    sourcepair*: Container # pointer to buffer with a source view (may be nil)
    needslines*: bool
    canceled: bool
    events*: Deque[ContainerEvent]
    startpos: Option[CursorPosition]
    hasstart: bool
    redirectdepth*: int
    select*: Select
    canreinterpret*: bool
    cloned: bool
    currentSelection {.jsget.}: Highlight
    tmpJumpMark: PagePos
    jumpMark: PagePos
    marks: Table[string, PagePos]
    ishtml*: bool

jsDestructor(Highlight)
jsDestructor(Container)

proc newBuffer*(forkserver: ForkServer, mainproc: Pid, config: BufferConfig,
    source: BufferSource, title = "", redirectdepth = 0,
    canreinterpret = true): Container =
  let attrs = getWindowAttributes(stdout)
  let ostream = forkserver.ostream
  let istream = forkserver.istream
  ostream.swrite(FORK_BUFFER)
  ostream.swrite(source)
  ostream.swrite(config)
  ostream.swrite(attrs)
  ostream.swrite(mainproc)
  ostream.flush()
  var process: Pid
  istream.sread(process)
  return Container(
    source: source,
    width: attrs.width,
    height: attrs.height - 1,
    title: title,
    config: config,
    redirectdepth: redirectdepth,
    process: process,
    pos: CursorPosition(
      setx: -1
    ),
    canreinterpret: canreinterpret
  )

func location*(container: Container): URL {.jsfget.} =
  return container.source.location

proc clone*(container: Container, newurl: URL): Promise[Container] =
  let url = if newurl != nil:
    newurl
  else:
    container.location
  return container.iface.clone(url).then(proc(pid: Pid): Container =
    if pid == -1:
      return nil
    let ncontainer = Container(
      config: container.config,
      iface: container.iface, # changed later in setStream
      width: container.width,
      height: container.height,
      title: container.title,
      hovertext: container.hovertext,
      lastpeek: container.lastpeek,
      source: container.source,
      pos: container.pos,
      bpos: container.bpos,
      highlights: container.highlights,
      process: pid,
      loadinfo: container.loadinfo,
      lines: container.lines,
      lineshift: container.lineshift,
      numLines: container.numLines,
      code: container.code,
      retry: container.retry,
      hlon: container.hlon,
      #needslines: container.needslines,
      canceled: container.canceled,
      events: container.events,
      startpos: container.startpos,
      hasstart: container.hasstart,
      redirectdepth: container.redirectdepth,
      select: container.select,
      canreinterpret: container.canreinterpret,
      ishtml: container.ishtml,
      cloned: true
    )
    if newurl != nil:
      ncontainer.source.location = newurl
    return ncontainer
  )

func charset*(container: Container): Charset =
  return container.source.charset

func contentType*(container: Container): Option[string] {.jsfget.} =
  return container.source.contentType

func lineLoaded(container: Container, y: int): bool =
  return y - container.lineshift in 0..container.lines.high

func getLine(container: Container, y: int): SimpleFlexibleLine =
  if container.lineLoaded(y):
    return container.lines[y - container.lineshift]

iterator ilines*(container: Container, slice: Slice[int]): SimpleFlexibleLine {.inline.} =
  for y in slice:
    yield container.getLine(y)

func cursorx*(container: Container): int {.jsfget.} =
  container.pos.cursorx

func cursory*(container: Container): int {.jsfget.} =
  container.pos.cursory

func fromx*(container: Container): int {.jsfget.} =
  container.pos.fromx

func fromy*(container: Container): int {.jsfget.} =
  container.pos.fromy

func xend(container: Container): int {.inline.} = container.pos.xend
func lastVisibleLine(container: Container): int = min(container.fromy + container.height, container.numLines) - 1

func currentLine(container: Container): string =
  return container.getLine(container.cursory).str

func findColBytes(s: string, endx: int, startx = 0, starti = 0): int =
  var w = startx
  var i = starti
  while i < s.len and w < endx:
    var r: Rune
    fastRuneAt(s, i, r)
    w += r.twidth(w)
  return i

func cursorBytes(container: Container, y: int, cc = container.cursorx): int =
  return container.getLine(y).str.findColBytes(cc, 0, 0)

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

# Last cell for tab, first cell for everything else (e.g. double width.)
# This is needed because moving the cursor to the 2nd cell of a double
# width character clears it on some terminals.
func cursorDispX(container: Container): int =
  if container.numLines == 0: return 0
  let line = container.currentLine
  if line.len == 0: return 0
  var w = 0
  var pw = 0
  var i = 0
  var r: Rune
  let cc = container.cursorx
  while i < line.len and w <= cc:
    fastRuneAt(line, i, r)
    pw = w
    w += r.twidth(w)
  if r == Rune('\t'):
    return max(w - 1, 0)
  else:
    return pw

func acursorx*(container: Container): int =
  max(0, container.cursorDispX() - container.fromx)

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

func startx(hl: Highlight): int =
  if hl.y1 < hl.y2:
    hl.x1
  elif hl.y2 < hl.y1:
    hl.x2
  else:
    min(hl.x1, hl.x2)
func starty(hl: Highlight): int = min(hl.y1, hl.y2)
func endx(hl: Highlight): int =
  if hl.y1 > hl.y2:
    hl.x1
  elif hl.y2 > hl.y1:
    hl.x2
  else:
    max(hl.x1, hl.x2)
func endy(hl: Highlight): int = max(hl.y1, hl.y2)

func colorNormal(container: Container, hl: Highlight, y: int,
    limitx: Slice[int]): Slice[int] =
  let starty = hl.starty
  let endy = hl.endy
  if y in starty + 1 .. endy - 1:
    let w = container.getLine(y).str.width()
    return min(limitx.a, w) .. min(limitx.b, w)
  if y == starty and y == endy:
    return max(hl.startx, limitx.a) .. min(hl.endx, limitx.b)
  if y == starty:
    let w = container.getLine(y).str.width()
    return max(hl.startx, limitx.a) .. min(limitx.b, w)
  if y == endy:
    let w = container.getLine(y).str.width()
    return min(limitx.a, w) .. min(hl.endx, limitx.b)

func colorArea(container: Container, hl: Highlight, y: int,
    limitx: Slice[int]): Slice[int] =
  case hl.t
  of HL_SELECT:
    case hl.selectionType
    of SEL_NORMAL:
      return container.colorNormal(hl, y, limitx)
    of SEL_BLOCK:
      if y in hl.starty .. hl.endy:
        let (x, endx) = if hl.x1 < hl.x2:
          (hl.x1, hl.x2)
        else:
          (hl.x2, hl.x1)
        return max(x, limitx.a) .. min(endx, limitx.b)
    of SEL_LINE:
      if y in hl.starty .. hl.endy:
        let w = container.getLine(y).str.width()
        return min(limitx.a, w) .. min(limitx.b, w)
  else:
    return container.colorNormal(hl, y, limitx)

func findHighlights*(container: Container, y: int): seq[Highlight] =
  for hl in container.highlights:
    if y in hl.starty .. hl.endy:
      result.add(hl)

func getHoverText*(container: Container): string =
  for t in HoverType:
    if container.hovertext[t] != "":
      return container.hovertext[t]

func isHoverURL*(container: Container, url: URL): bool =
  let hoverurl = parseURL(container.hovertext[HOVER_LINK])
  return hoverurl.isSome and url.host == hoverurl.get.host

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

proc requestLines*(container: Container, w = container.lineWindow): EmptyPromise
    {.discardable.} =
  if container.iface == nil:
    let res = EmptyPromise()
    res.resolve()
    return res
  return container.iface.getLines(w).then(proc(res: GetLinesResult) =
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

proc sendCursorPosition*(container: Container) =
  container.iface.updateHover(container.cursorx, container.cursory)
      .then(proc(res: UpdateHoverResult) =
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

# Set the cursor to the xth column. 0-based.
# * refresh = false inhibits reporting of the cursor position to the buffer.
# * save = false inhibits cursor movement if it is currently outside the
#   screen, and makes it so cursorx is not saved for restoration on cursory
#   movement.
proc setCursorX(container: Container, x: int, refresh = true, save = true)
    {.jsfunc.} =
  if not container.lineLoaded(container.cursory):
    container.pos.setx = x
    container.pos.setxrefresh = refresh
    return
  container.pos.setx = -1
  let cw = container.currentLineWidth()
  let x2 = x
  let x = max(min(x, cw - 1), 0)
  # we check for save here, because it is only set by restoreCursorX where
  # we do not want to move the cursor just because it is outside the window.
  if not save or container.fromx <= x and x < container.fromx + container.width:
    container.pos.cursorx = x
  elif save and container.fromx > x:
    if x2 < container.cursorx:
      container.setFromX(x, false)
    container.pos.cursorx = container.fromx
  elif x > container.cursorx:
    container.setFromX(max(x - container.width + 1, container.fromx), false)
    container.pos.cursorx = x
  elif x < container.cursorx:
    container.setFromX(x, false)
    container.pos.cursorx = x
  if container.cursorx == x and container.currentSelection != nil and
      container.currentSelection.x2 != x:
    container.currentSelection.x2 = x
    container.triggerEvent(UPDATE)
  if refresh:
    container.sendCursorPosition()
  if save:
    container.pos.xend = container.cursorx

proc restoreCursorX(container: Container) {.jsfunc.} =
  let x = clamp(container.currentLineWidth() - 1, 0, container.xend)
  container.setCursorX(x, false, false)

proc setCursorY(container: Container, y: int, refresh = true) {.jsfunc.} =
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
  if container.currentSelection != nil and container.currentSelection.y2 != y:
    container.triggerEvent(UPDATE)
    container.currentSelection.y2 = y
  container.restoreCursorX()
  if refresh:
    container.sendCursorPosition()

proc setCursorXY(container: Container, x, y: int, refresh = true) {.jsfunc.} =
  container.setCursorY(y, refresh)
  container.setCursorX(x, refresh)

proc cursorLineTextStart(container: Container) {.jsfunc.} =
  if container.numLines == 0: return
  var x = 0
  for r in container.currentLine.runes:
    if not r.isWhitespace():
      break
    x += r.twidth(x)
  container.setCursorX(x)

# zb
proc lowerPage(container: Container, n = 0) {.jsfunc.} =
  if n != 0:
    container.setCursorY(n - 1)
  container.setFromY(container.cursory - container.height + 1)

# z-
proc lowerPageBegin(container: Container, n = 0) {.jsfunc.} =
  container.lowerPage(n)
  container.cursorLineTextStart()

# zz
proc centerLine(container: Container, n = 0) {.jsfunc.} =
  if n != 0:
    container.setCursorY(n - 1)
  container.setFromY(container.cursory - container.height div 2)

# z.
proc centerLineBegin(container: Container, n = 0) {.jsfunc.} =
  container.centerLine(n)
  container.cursorLineTextStart()

# zt
proc raisePage(container: Container, n = 0) {.jsfunc.} =
  if n != 0:
    container.setCursorY(n - 1)
  container.setFromY(container.cursory)

# z^M
proc raisePageBegin(container: Container, n = 0) {.jsfunc.} =
  container.raisePage(n)
  container.cursorLineTextStart()

# z+
proc nextPageBegin(container: Container, n = 0) {.jsfunc.} =
  if n == 0:
    container.setCursorY(container.fromy + container.height)
  else:
    container.setCursorY(n - 1)
  container.cursorLineTextStart()
  container.raisePage()

# z^
proc previousPageBegin(container: Container, n = 0) {.jsfunc.} =
  if n == 0:
    container.setCursorY(container.fromy - 1)
  else:
    container.setCursorY(n - container.height) # +- 1 cancels out
  container.cursorLineTextStart()
  container.lowerPage()

proc centerColumn(container: Container) {.jsfunc.} =
  container.setFromX(container.cursorx - container.width div 2)

proc setCursorYCenter(container: Container, y: int, refresh = true)
    {.jsfunc.} =
  let fy = container.fromy
  container.setCursorY(y, refresh)
  if fy != container.fromy:
    container.centerLine()

proc setCursorXYCenter(container: Container, x, y: int, refresh = true) {.jsfunc.} =
  let fy = container.fromy
  let fx = container.fromx
  container.setCursorXY(x, y, refresh)
  if fy != container.fromy:
    container.centerLine()
  if fx != container.fromx:
    container.centerColumn()

proc cursorDown(container: Container, n = 1) {.jsfunc.} =
  if container.select.open:
    container.select.cursorDown()
  else:
    container.setCursorY(container.cursory + n)

proc cursorUp(container: Container, n = 1) {.jsfunc.} =
  if container.select.open:
    container.select.cursorUp()
  else:
    container.setCursorY(container.cursory - n)

proc cursorLeft(container: Container, n = 1) {.jsfunc.} =
  if container.select.open:
    container.select.cursorLeft()
  else:
    container.setCursorX(container.cursorFirstX() - n)

proc cursorRight(container: Container, n = 1) {.jsfunc.} =
  if container.select.open:
    container.select.cursorRight()
  else:
    container.setCursorX(container.cursorLastX() + n)

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

proc pageDown(container: Container, n = 1) {.jsfunc.} =
  container.setFromY(container.fromy + container.height * n)
  container.setCursorY(container.cursory + container.height * n)
  container.restoreCursorX()

proc pageUp(container: Container, n = 1) {.jsfunc.} =
  container.setFromY(container.fromy - container.height * n)
  container.setCursorY(container.cursory - container.height * n)
  container.restoreCursorX()

proc pageLeft(container: Container, n = 1) {.jsfunc.} =
  container.setFromX(container.fromx - container.width * n)

proc pageRight(container: Container, n = 1) {.jsfunc.} =
  container.setFromX(container.fromx + container.width * n)

# I am not cloning the vi behavior here because it is counter-intuitive
# and annoying.
# Users who disagree are free to implement it themselves. (It is about
# 5 lines of JS.)
proc halfPageUp(container: Container, n = 1) {.jsfunc.} =
  container.setFromY(container.fromy - (container.height div 2 + 1) * n)
  container.setCursorY(container.cursory - (container.height div 2 + 1) * n)
  container.restoreCursorX()

proc halfPageDown(container: Container, n = 1) {.jsfunc.} =
  container.setFromY(container.fromy + (container.height div 2 - 1) * n)
  container.setCursorY(container.cursory + (container.height div 2 - 1) * n)
  container.restoreCursorX()

proc halfPageLeft(container: Container, n = 1) {.jsfunc.} =
  container.setFromX(container.fromx - (container.width div 2 + 1) * n)

proc halfPageRight(container: Container, n = 1) {.jsfunc.} =
  container.setFromX(container.fromx + (container.width div 2 - 1) * n)

proc markPos0*(container: Container) =
  container.tmpJumpMark = (container.cursorx, container.cursory)

proc markPos*(container: Container) =
  let pos = container.tmpJumpMark
  if container.cursorx != pos.x or container.cursory != pos.y:
    container.jumpMark = pos

proc cursorFirstLine(container: Container) {.jsfunc.} =
  if container.select.open:
    container.select.cursorFirstLine()
  else:
    container.markPos0()
    container.setCursorY(0)
    container.markPos()

proc cursorLastLine*(container: Container) {.jsfunc.} =
  if container.select.open:
    container.select.cursorLastLine()
  else:
    container.markPos0()
    container.setCursorY(container.numLines - 1)
    container.markPos()

proc cursorTop(container: Container, i = 1) {.jsfunc.} =
  container.markPos0()
  let i = clamp(i - 1, 0, container.height - 1)
  container.setCursorY(container.fromy + i)
  container.markPos()

proc cursorMiddle(container: Container) {.jsfunc.} =
  container.markPos0()
  container.setCursorY(container.fromy + (container.height - 2) div 2)
  container.markPos()

proc cursorBottom(container: Container, i = 1) {.jsfunc.} =
  container.markPos0()
  let i = clamp(i, 0, container.height)
  container.setCursorY(container.fromy + container.height - i)
  container.markPos()

proc cursorLeftEdge(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx)

proc cursorMiddleColumn(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + (container.width - 2) div 2)

proc cursorRightEdge(container: Container) {.jsfunc.} =
  container.setCursorX(container.fromx + container.width - 1)

proc scrollDown(container: Container, n = 1) {.jsfunc.} =
  if container.fromy + container.height < container.numLines:
    container.setFromY(container.fromy + n)
    if container.fromy > container.cursory:
      container.cursorDown(container.fromy - container.cursory)
  else:
    container.cursorDown(n)

proc scrollUp(container: Container, n = 1) {.jsfunc.} =
  if container.fromy > 0:
    container.setFromY(container.fromy - n)
    if container.fromy + container.height <= container.cursory:
      container.cursorUp(container.cursory - container.fromy -
        container.height + 1)
  else:
    container.cursorUp(n)

proc scrollRight(container: Container, n = 1) {.jsfunc.} =
  if container.fromx + container.width + n <= container.maxScreenWidth():
    container.setFromX(container.fromx + n)

proc scrollLeft(container: Container, n = 1) {.jsfunc.} =
  if container.fromx - n >= 0:
    container.setFromX(container.fromx - n)

proc alert(container: Container, msg: string) =
  container.triggerEvent(ContainerEvent(t: ALERT, msg: msg))

proc lineInfo(container: Container) {.jsfunc.} =
  container.alert("line " & $(container.cursory + 1) & "/" &
    $container.numLines & " (" & $container.atPercentOf() & "%) col " &
    $(container.cursorx + 1) & "/" & $container.currentLineWidth &
    " (byte " & $container.currentCursorBytes & ")")

proc updateCursor(container: Container) =
  if container.pos.setx > -1:
    container.setCursorX(container.pos.setx, container.pos.setxrefresh)
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
      let i = parseUInt32(s)
      if i.isSome and i.get > 0:
        container.markPos0()
        container.setCursorY(int(i.get - 1))
        container.markPos()
      else:
        container.alert("First line is #1") # :)
  else:
    container.markPos0()
    container.setCursorY(s - 1)
    container.markPos()

proc pushCursorPos*(container: Container) =
  if container.select.open:
    container.select.pushCursorPos()
  else:
    container.bpos.add(container.pos)

proc popCursorPos*(container: Container, nojump = false) =
  if container.select.open:
    container.select.popCursorPos(nojump)
  else:
    container.pos = container.bpos.pop()
    if not nojump:
      container.updateCursor()
      container.sendCursorPosition()
      container.needslines = true

proc copyCursorPos*(container, c2: Container) =
  container.startpos = some(c2.pos)
  container.hasstart = true

proc cursorNextLink*(container: Container, n = 1) {.jsfunc.} =
  container.markPos0()
  container.iface
    .findNextLink(container.cursorx, container.cursory, n)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXYCenter(res.x, res.y)
        container.markPos()
    )

proc cursorPrevLink*(container: Container, n = 1) {.jsfunc.} =
  container.markPos0()
  container.iface
    .findPrevLink(container.cursorx, container.cursory, n)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXYCenter(res.x, res.y)
        container.markPos()
    )

proc cursorNextParagraph*(container: Container, n = 1) {.jsfunc.} =
  container.markPos0()
  container.iface
    .findNextParagraph(container.cursory, n)
    .then(proc(res: int) =
      container.setCursorY(res)
      container.markPos()
    )

proc cursorPrevParagraph*(container: Container, n = 1) {.jsfunc.} =
  container.markPos0()
  container.iface
    .findPrevParagraph(container.cursory, n)
    .then(proc(res: int) =
      container.setCursorY(res)
      container.markPos()
    )

proc setMark*(container: Container, id: string, x = none(int),
    y = none(int)): bool {.jsfunc.} =
  let x = x.get(container.cursorx)
  let y = y.get(container.cursory)
  container.marks.withValue(id, p):
    p[] = (x, y)
    container.triggerEvent(UPDATE)
    return false
  do:
    container.marks[id] = (x, y)
    container.triggerEvent(UPDATE)
    return true

proc clearMark*(container: Container, id: string): bool {.jsfunc.} =
  result = id in container.marks
  container.marks.del(id)
  container.triggerEvent(UPDATE)

proc getMarkPos(container: Container, id: string): Opt[PagePos] {.jsfunc.} =
  if id == "`" or id == "'":
    return ok(container.jumpMark)
  container.marks.withValue(id, p):
    return ok(p[])
  return err()

proc gotoMark*(container: Container, id: string): bool {.jsfunc.} =
  container.markPos0()
  let mark = container.getMarkPos(id)
  if mark.isSome:
    let mark = mark.get
    container.setCursorXYCenter(mark.x, mark.y)
    container.markPos()
    return true
  return false

proc gotoMarkY*(container: Container, id: string): bool {.jsfunc.} =
  container.markPos0()
  let mark = container.getMarkPos(id)
  if mark.isSome:
    let mark = mark.get
    container.setCursorXYCenter(0, mark.y)
    container.markPos()
    return true
  return false

proc findNextMark*(container: Container, x = none(int), y = none(int)):
    Option[string] {.jsfunc.} =
  #TODO optimize (maybe store marks in an OrderedTable and sort on insert?)
  let x = x.get(container.cursorx)
  let y = y.get(container.cursory)
  var best: PagePos = (high(int), high(int))
  var bestid = none(string)
  for id, mark in container.marks:
    if mark.y < y or mark.y == y and mark.x <= x:
      continue
    if mark.y < best.y or mark.y == best.y and mark.x < best.x:
      best = mark
      bestid = some(id)
  return bestid

proc findPrevMark*(container: Container, x = none(int), y = none(int)):
    Option[string] {.jsfunc.} =
  #TODO optimize (maybe store marks in an OrderedTable and sort on insert?)
  let x = x.get(container.cursorx)
  let y = y.get(container.cursory)
  var best: PagePos = (-1, -1)
  var bestid = none(string)
  for id, mark in container.marks:
    if mark.y > y or mark.y == y and mark.x >= x:
      continue
    if mark.y > best.y or mark.y == best.y and mark.x > best.x:
      best = mark
      bestid = some(id)
  return bestid

proc cursorNthLink*(container: Container, n = 1) {.jsfunc.} =
  container.iface
    .findNthLink(n)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXYCenter(res.x, res.y))

proc cursorRevNthLink*(container: Container, n = 1) {.jsfunc.} =
  container.iface
    .findRevNthLink(n)
    .then(proc(res: tuple[x, y: int]) =
      if res.x > -1 and res.y != -1:
        container.setCursorXYCenter(res.x, res.y))

proc clearSearchHighlights*(container: Container) =
  for i in countdown(container.highlights.high, 0):
    if container.highlights[i].t == HL_SEARCH:
      container.highlights.del(i)

proc onMatch(container: Container, res: BufferMatch, refresh: bool) =
  if res.success:
    container.setCursorXYCenter(res.x, res.y, refresh)
    if container.hlon:
      container.clearSearchHighlights()
      let ex = res.x + res.str.twidth(res.x) - 1
      let hl = Highlight(
        t: HL_SEARCH,
        x1: res.x,
        y1: res.y,
        x2: ex,
        y2: res.y
      )
      container.highlights.add(hl)
      container.triggerEvent(UPDATE)
      container.hlon = false
  elif container.hlon:
    container.clearSearchHighlights()
    container.triggerEvent(UPDATE)
    container.needslines = true
    container.hlon = false

proc cursorNextMatch*(container: Container, regex: Regex, wrap, refresh: bool,
    n: int): EmptyPromise {.discardable.} =
  if container.select.open:
    #TODO
    for _ in 0 ..< n:
      container.select.cursorNextMatch(regex, wrap)
    return newResolvedPromise()
  else:
    return container.iface
      .findNextMatch(regex, container.cursorx, container.cursory, wrap, n)
      .then(proc(res: BufferMatch) =
        container.onMatch(res, refresh))

proc cursorPrevMatch*(container: Container, regex: Regex, wrap, refresh: bool,
    n: int): EmptyPromise {.discardable.} =
  if container.select.open:
    #TODO
    for _ in 0 ..< n:
      container.select.cursorPrevMatch(regex, wrap)
    return newResolvedPromise()
  else:
    container.markPos0()
    return container.iface
      .findPrevMatch(regex, container.cursorx, container.cursory, wrap, n)
      .then(proc(res: BufferMatch) =
        container.onMatch(res, refresh)
        container.markPos()
      )

type
  SelectionOptions = object of JSDict
    selectionType: SelectionType

proc cursorToggleSelection(container: Container, n = 1,
    opts = SelectionOptions()): Highlight {.jsfunc.} =
  if container.currentSelection != nil:
    let i = container.highlights.find(container.currentSelection)
    if i != -1:
      container.highlights.delete(i)
    container.currentSelection = nil
  else:
    let n = n - 1
    let hl = Highlight(
      t: HL_SELECT,
      selectionType: opts.selectionType,
      x1: container.cursorx,
      y1: container.cursory,
      x2: container.cursorx + n,
      y2: container.cursory
    )
    container.highlights.add(hl)
    container.currentSelection = hl
    container.cursorRight(n)
  container.triggerEvent(UPDATE)
  return container.currentSelection

#TODO I don't like this API
# maybe make selection a subclass of highlight?
proc getSelectionText(container: Container, hl: Highlight = nil):
    Promise[string] {.jsfunc.} =
  let hl = if hl == nil: container.currentSelection else: hl
  if hl.t != HL_SELECT:
    let p = newPromise[string]()
    p.resolve("")
    return p
  let startx = hl.startx
  let starty = hl.starty
  let endx = hl.endx
  let endy = hl.endy
  let nw = starty .. endy
  return container.iface.getLines(nw).then(proc(res: GetLinesResult): string =
    var s = ""
    case hl.selectionType
    of SEL_NORMAL:
      if starty == endy:
        let si = res.lines[0].str.findColBytes(startx)
        let ei = res.lines[0].str.findColBytes(endx + 1, startx, si) - 1
        s = res.lines[0].str.substr(si, ei)
      else:
        let si = res.lines[0].str.findColBytes(startx)
        s &= res.lines[0].str.substr(si) & '\n'
        for i in 1 .. res.lines.high - 1:
          s &= res.lines[i].str & '\n'
        let ei = res.lines[^1].str.findColBytes(endx + 1) - 1
        s &= res.lines[^1].str.substr(0, ei)
    of SEL_BLOCK:
      for i, line in res.lines:
        let si = line.str.findColBytes(startx)
        let ei = line.str.findColBytes(endx + 1, startx, si) - 1
        if i > 0:
          s &= '\n'
        s &= line.str.substr(si, ei)
    of SEL_LINE:
      for i, line in res.lines:
        if i > 0:
          s &= '\n'
        s &= line.str
    return s
  )

proc setLoadInfo(container: Container, msg: string) =
  container.loadinfo = msg
  container.triggerEvent(STATUS)

#TODO TODO TODO this should be called with a timeout.
proc onload*(container: Container, res: LoadResult) =
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
          container.triggerEvent(TITLE)
        return container.iface.render()
      ).then(proc(lines: int): auto =
        container.setNumLines(lines, true)
        container.needslines = true
        container.triggerEvent(LOADED)
        if not container.hasstart and container.source.location.anchor != "":
          return container.iface.gotoAnchor()
      ).then(proc(res: Opt[tuple[x, y: int]]) =
        if res.isSome:
          let res = res.get
          container.setCursorXYCenter(res.x, res.y))

proc load(container: Container) =
  container.setLoadInfo("Connecting to " & container.location.host & "...")
  container.iface.connect().then(proc(res: ConnectResult) =
    let info = container.loadinfo
    if not res.invalid:
      container.code = res.code
      if res.code == 0:
        container.triggerEvent(SUCCESS)
        # accept cookies
        let cookiejar = container.config.loaderConfig.cookiejar
        if res.cookies.len > 0 and cookiejar != nil:
          cookiejar.add(res.cookies)
        # set referrer policy, if any
        if res.referrerpolicy.isSome and container.config.referer_from:
          container.config.referrerpolicy = res.referrerpolicy.get
        container.setLoadInfo("Connected to " & $container.source.location & ". Downloading...")
        if res.needsAuth:
          container.triggerEvent(NEEDS_AUTH)
        if res.redirect != nil:
          container.triggerEvent(ContainerEvent(t: REDIRECT, request: res.redirect))
        container.source.charset = res.charset
        container.ishtml = res.contentType == "text/html"
        if res.contentType == "application/octet-stream":
          let contentType = guessContentType(container.location.pathname,
            "application/octet-stream", container.config.mimeTypes)
          if contentType != "application/octet-stream":
            container.iface.setContentType(contentType)
          container.source.contentType = some(contentType)
        else:
          container.source.contentType = some(res.contentType)
        container.triggerEvent(CHECK_MAILCAP)
      else:
        if res.errorMessage != "":
          container.errorMessage = res.errorMessage
        else:
          container.errorMessage = getLoaderErrorMessage(res.code)
        container.setLoadInfo("")
        container.triggerEvent(FAIL)
    else:
      container.setLoadInfo(info)
  )

proc startload*(container: Container) =
  container.iface.load()
    .then(proc(res: tuple[atend: bool, lines, bytes: int]) =
      container.onload(res))

proc connect2*(container: Container): EmptyPromise =
  return container.iface.connect2()

proc redirectToFd*(container: Container, fdin: FileHandle, wait: bool):
    EmptyPromise =
  return container.iface.redirectToFd(fdin, wait)

proc readFromFd*(container: Container, fdout: FileHandle, ishtml: bool):
    EmptyPromise =
  container.ishtml = ishtml
  return container.iface.readFromFd(fdout, ishtml)

proc quit*(container: Container) =
  container.triggerEvent(QUIT)

proc cancel*(container: Container) {.jsfunc.} =
  if container.select.open:
    container.select.cancel()
  else:
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

proc reshape(container: Container): EmptyPromise {.discardable, jsfunc.} =
  return container.iface.render().then(proc(lines: int): auto =
    container.setNumLines(lines)
    return container.requestLines())

proc pipeBuffer*(container, pipeTo: Container) =
  container.iface.getSource().then(proc() =
    pipeTo.load() #TODO do not load if pipeTo is killed first?
  )

proc onclick(container: Container, res: ClickResult)

proc displaySelect(container: Container, selectResult: SelectResult) =
  let submitSelect = proc(selected: seq[int]) =
    container.iface.select(selected).then(proc(res: ClickResult) =
      container.onclick(res))
  container.select.initSelect(selectResult, container.acursorx,
    container.acursory, container.height, submitSelect)
  container.triggerEvent(UPDATE)

proc onclick(container: Container, res: ClickResult) =
  if res.repaint:
    container.needslines = true
  if res.open.isSome:
    container.triggerEvent(ContainerEvent(t: OPEN, request: res.open.get))
  if res.select.isSome:
    container.displaySelect(res.select.get)
  if res.readline.isSome:
    let rl = res.readline.get
    let event = if rl.area:
      ContainerEvent(
        t: READ_AREA,
        tvalue: rl.value
      )
    else:
      ContainerEvent(
        t: READ_LINE,
        prompt: rl.prompt,
        value: rl.value,
        password: rl.hide
      )
    container.triggerEvent(event)

proc click(container: Container) {.jsfunc.} =
  if container.select.open:
    container.select.click()
  else:
    container.iface.click(container.cursorx, container.cursory)
      .then(proc(res: ClickResult) = container.onclick(res))

proc windowChange*(container: Container, attrs: WindowAttributes) =
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
  container.iface.resolve(packetid, len - slen(packetid))

proc setStream*(container: Container, stream: Stream) =
  if not container.cloned:
    container.iface = newBufferInterface(stream)
    if container.source.t == LOAD_PIPE:
      container.iface.passFd(container.source.fd).then(proc() =
        if container.source.fd == 0:
          # We are closing stdin.
          # Leaving the stdin fileno open to grab is a bad idea.
          closeStdin()
        else:
          discard close(container.source.fd)
      )
      stream.flush()
    container.load()
  else:
    container.iface = cloneInterface(stream)
    # Maybe we have to resume loading. Let's try.
    discard container.iface.load().then(proc(res: LoadResult) =
      container.onload(res))

proc onreadline(container: Container, w: Slice[int], handle: (proc(line: SimpleFlexibleLine)), res: GetLinesResult) =
  for line in res.lines:
    handle(line)
  if res.numLines > w.b + 1:
    var w = w
    w.a += 24
    w.b += 24
    container.iface.getLines(w).then(proc(res: GetLinesResult) =
      container.onreadline(w, handle, res))
  else:
    container.setNumLines(res.numLines, true)

# Synchronously read all lines in the buffer.
proc readLines*(container: Container, handle: (proc(line: SimpleFlexibleLine))) =
  if container.code == 0:
    # load succeded
    let w = 0 .. 23
    container.iface.getLines(w).then(proc(res: GetLinesResult) =
      container.onreadline(w, handle, res))
    while container.iface.hasPromises:
      # fulfill all promises
      container.handleCommand()

proc drawLines*(container: Container, display: var FixedGrid,
    hlcolor: CellColor) =
  var r: Rune
  var by = 0
  let endy = min(container.fromy + display.height, container.numLines)
  for line in container.ilines(container.fromy ..< endy):
    var w = 0 # width of the row so far
    var i = 0 # byte in line.str
    # Skip cells till fromx.
    while w < container.fromx and i < line.str.len:
      fastRuneAt(line.str, i, r)
      w += r.twidth(w)
    let dls = by * display.width # starting position of row in display
    # Fill in the gap in case we skipped more cells than fromx mandates (i.e.
    # we encountered a double-width character.)
    var k = 0
    if w > container.fromx:
      while k < w - container.fromx:
        display[dls + k].str &= ' '
        inc k
    var cf = line.findFormat(w)
    var nf = line.findNextFormat(w)
    let startw = w # save this for later
    # Now fill in the visible part of the row.
    while i < line.str.len:
      let pw = w
      fastRuneAt(line.str, i, r)
      let rw = r.twidth(w)
      w += rw
      if w > container.fromx + display.width:
        break # die on exceeding the width limit
      if nf.pos != -1 and nf.pos <= pw:
        cf = nf
        nf = line.findNextFormat(pw)
      if cf.pos != -1:
        display[dls + k].format = cf.format
      if r == Rune('\t'):
        # Needs to be replaced with spaces, otherwise bgcolor isn't displayed.
        let tk = k + rw
        while k < tk:
          display[dls + k].str &= ' '
          inc k
      else:
        display[dls + k].str &= r
        k += rw
    # Finally, override cell formatting for highlighted cells.
    let hls = container.findHighlights(container.fromy + by)
    let aw = container.width - (startw - container.fromx) # actual width
    for hl in hls:
      let area = container.colorArea(hl, container.fromy + by,
        startw .. startw + aw)
      for i in area:
        if i - startw >= container.width:
          break
        var hlformat = display[dls + i - startw].format
        hlformat.bgcolor = hlcolor
        display[dls + i - startw].format = hlformat
    inc by

proc highlightMarks*(container: Container, display: var FixedGrid,
    hlcolor: CellColor) =
  for mark in container.marks.values:
    if mark.x in container.fromx ..< container.fromx + display.width and
        mark.y in container.fromy ..< container.fromy + display.height:
      let x = mark.x - container.fromx
      let y = mark.y - container.fromy
      var hlformat = display[y * display.width + x].format
      hlformat.bgcolor = hlcolor
      display[y * display.width + x].format = hlformat

proc handleEvent*(container: Container) =
  container.handleCommand()
  if container.needslines:
    container.requestLines()
    container.needslines = false

proc addContainerModule*(ctx: JSContext) =
  ctx.registerType(Highlight)
  ctx.registerType(Container, name = "Buffer")
