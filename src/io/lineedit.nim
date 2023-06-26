import unicode
import strutils
import sequtils
import sugar

import bindings/quickjs
import buffer/cell
import display/term
import js/javascript
import types/color
import utils/opt
import utils/twtstr

type
  LineEditState* = enum
    EDIT, FINISH, CANCEL

  LineHistory* = ref object
    lines: seq[string]

  LineEdit* = ref object
    isnew*: bool #TODO hack
    news*: seq[Rune]
    prompt*: string
    promptw: int
    current: string
    state*: LineEditState
    escNext*: bool
    cursor: int
    shift: int
    minlen: int
    maxwidth: int
    displen: int
    disallowed: set[char]
    hide: bool
    term: Terminal
    hist: LineHistory
    histindex: int
    histtmp: string

func newLineHistory*(): LineHistory =
  return LineHistory()

const colorFormat = (func(): Format =
  result = newFormat()
  result.fgcolor = cellColor(ANSI_BLUE)
)()
const defaultFormat = newFormat()
proc printesc(edit: LineEdit, rs: seq[Rune]) =
  var s = ""
  var format = newFormat()
  for r in rs:
    if r.isControlChar():
      s &= edit.term.processFormat(format, colorFormat)
    else:
      s &= edit.term.processFormat(format, defaultFormat)
    s &= r
  edit.term.write(s)

proc printesc(edit: LineEdit, s: string) =
  var s = ""
  var format = newFormat()
  for r in s.runes:
    if r.isControlChar():
      s &= edit.term.processFormat(format, colorFormat)
    else:
      s &= edit.term.processFormat(format, defaultFormat)
    s &= r
  edit.term.write(s)

template kill0(edit: LineEdit, i: int) =
  edit.space(i)
  edit.backward0(i)

template kill0(edit: LineEdit) =
  let w = min(edit.news.width(edit.cursor), edit.displen)
  edit.kill0(w)

proc backward0(state: LineEdit, i: int) =
  state.term.cursorBackward(i)

proc forward0(state: LineEdit, i: int) =
  state.term.cursorForward(i)

proc begin0(edit: LineEdit) =
  edit.term.cursorBegin()
  edit.forward0(edit.minlen)

proc space(edit: LineEdit, i: int) =
  edit.term.write(' '.repeat(i))

#TODO this is broken (e.g. it doesn't account for shift, but for other
# reasons too)
proc generateOutput*(edit: LineEdit): FixedGrid =
  result = newFixedGrid(edit.promptw + edit.maxwidth)
  var x = 0
  for r in edit.prompt.runes():
    result[x].str &= $r
    x += r.width()
  if edit.hide:
    for r in edit.news:
      let w = r.width()
      result[x].str = '*'.repeat(w)
      x += w
      if x >= result.width: break
  else:
    for r in edit.news:
      result[x].str &= $r
      x += r.width()
      if x >= result.width: break
  var s = ""
  for c in result:
    s &= c.str

proc getCursorX*(edit: LineEdit): int =
  return edit.promptw + edit.news.width(edit.shift, edit.cursor)

proc redraw(state: LineEdit) =
  if state.shift + state.displen > state.news.len:
    state.displen = state.news.len - state.shift
  var dispw = state.news.width(state.shift, state.shift + state.displen)
  while dispw > state.maxwidth - 1:
    dispw -= state.news[state.shift + state.displen - 1].width()
    dec state.displen
  state.begin0()
  let os = state.news.substr(state.shift, state.shift + state.displen)
  if state.hide:
    state.printesc('*'.repeat(os.width()))
  else:
    state.printesc(os)
  state.space(max(state.maxwidth - state.minlen - os.width(), 0))
  state.begin0()
  state.forward0(state.news.width(state.shift, state.cursor))

proc zeroShiftRedraw(state: LineEdit) =
  state.shift = 0
  state.displen = state.news.len
  state.redraw()

proc fullRedraw*(state: LineEdit) =
  state.displen = state.news.len
  if state.cursor > state.shift:
    var shiftw = state.news.width(state.shift, state.cursor)
    while shiftw > state.maxwidth - 1:
      inc state.shift
      shiftw -= state.news[state.shift].width()
  else:
    state.shift = max(state.cursor - 1, 0)
  state.redraw()

proc drawPrompt*(edit: LineEdit) =
  edit.term.write(edit.prompt)

proc insertCharseq(edit: LineEdit, cs: var seq[Rune]) =
  let escNext = edit.escNext
  cs.keepIf((r) => (escNext or not r.isControlChar) and not (r.isAscii and char(r) in edit.disallowed))
  edit.escNext = false
  if cs.len == 0:
    return

  if edit.cursor >= edit.news.len and edit.news.width(edit.shift, edit.cursor) + cs.width() < edit.maxwidth:
    edit.news &= cs
    edit.cursor += cs.len
    if edit.hide:
      edit.printesc('*'.repeat(cs.width()))
    else:
      edit.printesc(cs)
  else:
    edit.news.insert(cs, edit.cursor)
    edit.cursor += cs.len
    edit.fullRedraw()

proc cancel(edit: LineEdit) {.jsfunc.} =
  edit.state = CANCEL

proc submit(edit: LineEdit) {.jsfunc.} =
  let s = $edit.news
  if edit.hist.lines.len == 0 or s != edit.hist.lines[^1]:
    edit.hist.lines.add(s)
  edit.state = FINISH

proc backspace(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    let w = edit.news[edit.cursor - 1].width()
    edit.news.delete(edit.cursor - 1..edit.cursor - 1)
    dec edit.cursor
    if edit.cursor == edit.news.len and edit.shift == 0:
      edit.backward0(w)
      edit.kill0(w)
    else:
      edit.fullRedraw()

proc write*(edit: LineEdit, s: string): bool {.jsfunc.} =
  if validateUtf8(s) == -1:
    var cs = s.toRunes()
    edit.insertCharseq(cs)
    return true

proc delete(edit: LineEdit) {.jsfunc.} =
  if edit.cursor >= 0 and edit.cursor < edit.news.len:
    let w = edit.news[edit.cursor].width()
    edit.news.delete(edit.cursor..edit.cursor)
    if edit.cursor == edit.news.len and edit.shift == 0:
      edit.kill0(w)
    else:
      edit.fullRedraw()

proc escape(edit: LineEdit) {.jsfunc.} =
  edit.escNext = true

proc clear(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    edit.news.delete(0..edit.cursor - 1)
    edit.cursor = 0
    edit.zeroShiftRedraw()

proc kill(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    edit.kill0()
    edit.news.setLen(edit.cursor)

proc backward(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    dec edit.cursor
    if edit.cursor > edit.shift or edit.shift == 0:
      edit.backward0(edit.news[edit.cursor].width())
    else:
      edit.fullRedraw()

proc forward(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    inc edit.cursor
    if edit.news.width(edit.shift, edit.cursor) < edit.maxwidth:
      var n = 1
      if edit.news.len > edit.cursor:
        n = edit.news[edit.cursor].width()
      edit.forward0(n)
    else:
      edit.fullRedraw()

proc prevWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  let oc = edit.cursor
  while edit.cursor > 0:
    dec edit.cursor
    if edit.news[edit.cursor].breaksWord(check):
      break
  if edit.cursor != oc:
    if edit.cursor > edit.shift or edit.shift == 0:
      edit.backward0(edit.news.width(edit.cursor, oc))
    else:
      edit.fullRedraw()

proc nextWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  let oc = edit.cursor
  let ow = edit.news.width(edit.shift, edit.cursor)
  while edit.cursor < edit.news.len:
    inc edit.cursor
    if edit.cursor < edit.news.len:
      if edit.news[edit.cursor].breaksWord(check):
        break
  if edit.cursor != oc:
    let dw = edit.news.width(oc, edit.cursor)
    if ow + dw < edit.maxwidth:
      edit.forward0(dw)
    else:
      edit.fullRedraw()

proc clearWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  var i = edit.cursor
  if i > 0:
    # point to the previous character
    dec i
  while i > 0:
    dec i
    if edit.news[i].breaksWord(check):
      inc i
      break
  if i != edit.cursor:
    edit.news.delete(i..<edit.cursor)
    edit.cursor = i
    edit.fullRedraw()

proc killWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  var i = edit.cursor
  if i < edit.news.len and edit.news[i].breaksWord(check):
    inc i
  while i < edit.news.len:
    if edit.news[i].breaksWord(check):
      break
    inc i
  if i != edit.cursor:
    edit.news.delete(edit.cursor..<i)
    edit.fullRedraw()

proc begin(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    if edit.shift == 0:
      edit.backward0(edit.news.width(0, edit.cursor))
      edit.cursor = 0
    else:
      edit.cursor = 0
      edit.fullRedraw()

proc `end`(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    if edit.news.width(edit.shift, edit.news.len) < edit.maxwidth:
      edit.forward0(edit.news.width(edit.cursor, edit.news.len))
      edit.cursor = edit.news.len
    else:
      edit.cursor = edit.news.len
      edit.fullRedraw()

proc prevHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex > 0:
    if edit.news.len > 0:
      edit.histtmp = $edit.news
    dec edit.histindex
    edit.news = edit.hist.lines[edit.histindex].toRunes()
    edit.begin()
    edit.end()
    edit.fullRedraw()

proc nextHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex + 1 < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.hist.lines[edit.histindex].toRunes()
    edit.begin()
    edit.end()
    edit.fullRedraw()
  elif edit.histindex < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.histtmp.toRunes()
    edit.begin()
    edit.end()
    edit.fullRedraw()
    edit.histtmp = ""

proc readLine*(prompt: string, termwidth: int, current = "",
               disallowed: set[char] = {}, hide = false,
               term: Terminal, hist: LineHistory): LineEdit =
  result = LineEdit(
    prompt: prompt,
    promptw: prompt.width(),
    current: current,
    news: current.toRunes(),
    minlen: prompt.width(),
    disallowed: disallowed,
    hide: hide,
    term: term,
    isnew: true
  )
  result.cursor = result.news.width()
  result.maxwidth = termwidth - result.promptw
  result.displen = result.cursor
  result.hist = hist
  result.histindex = result.hist.lines.len

proc addLineEditModule*(ctx: JSContext) =
  ctx.registerType(LineEdit)
