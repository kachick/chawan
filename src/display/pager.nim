import config/config
import io/buffer
import js/javascript

type
  Container = ref object
    buffer: Buffer
    children: seq[Container]

  Pager* = ref object
    rootContainer: Container
    container: Container
    config: Config

proc cursorLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLeft()
proc cursorDown(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorDown()
proc cursorUp(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorUp()
proc cursorRight(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorRight()
proc cursorLineBegin(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLineBegin()
proc cursorLineEnd(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLineEnd()
proc cursorNextWord(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorNextWord()
proc cursorPrevWord(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorPrevWord()
proc cursorNextLink(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorNextLink()
proc cursorPrevLink(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorPrevLink()
proc pageDown(pager: Pager) {.jsfunc.} = pager.container.buffer.pageDown()
proc pageUp(pager: Pager) {.jsfunc.} = pager.container.buffer.pageUp()
proc pageRight(pager: Pager) {.jsfunc.} = pager.container.buffer.pageRight()
proc pageLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.pageLeft()
proc halfPageDown(pager: Pager) {.jsfunc.} = pager.container.buffer.halfPageDown()
proc halfPageUp(pager: Pager) {.jsfunc.} = pager.container.buffer.halfPageUp()
proc cursorFirstLine(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorFirstLine()
proc cursorLastLine(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLastLine()
proc cursorTop(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorTop()
proc cursorMiddle(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorMiddle()
proc cursorBottom(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorBottom()
proc cursorLeftEdge(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLeftEdge()
proc cursorVertMiddle(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorVertMiddle()
proc cursorRightEdge(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorRightEdge()
proc centerLine(pager: Pager) {.jsfunc.} = pager.container.buffer.centerLine()
proc scrollDown(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollDown()
proc scrollUp(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollUp()
proc scrollLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollLeft()
proc scrollRight(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollRight()
proc lineInfo(pager: Pager) {.jsfunc.} = pager.container.buffer.lineInfo()
proc reshape(pager: Pager) {.jsfunc.} = pager.container.buffer.reshape = true
proc redraw(pager: Pager) {.jsfunc.} = pager.container.buffer.redraw = true

proc newContainer(): Container =
  new(result)

proc newPager*(config: Config, buffer: Buffer): Pager =
  result.config = config
  result.rootContainer = newContainer()

proc addBuffer*(pager: Pager, buffer: Buffer) =
  var ncontainer = newContainer()
  ncontainer.buffer = buffer
  pager.container.children.add(ncontainer)
  pager.container = ncontainer

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
