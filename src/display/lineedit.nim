import streams
import strutils
import unicode

import bindings/quickjs
import js/javascript
import types/cell
import types/opt
import utils/twtstr

import chakasu/charset
import chakasu/decoderstream
import chakasu/encoderstream

type
  LineEditState* = enum
    EDIT, FINISH, CANCEL

  LineHistory* = ref object
    lines: seq[string]

  LineEdit* = ref object
    news*: string
    prompt*: string
    promptw: int
    state*: LineEditState
    escNext*: bool
    cursorx: int # 0 ..< news.notwidth
    cursori: int # 0 ..< news.len
    shiftx: int # 0 ..< news.notwidth
    shifti: int # 0 ..< news.len
    padding: int # 0 or 1
    maxwidth: int
    disallowed: set[char]
    hide: bool
    hist: LineHistory
    histindex: int
    histtmp: string
    invalid*: bool

jsDestructor(LineEdit)

func newLineHistory*(): LineHistory =
  return LineHistory()

# Note: capped at edit.maxwidth.
func getDisplayWidth(edit: LineEdit): int =
  var dispw = 0
  var i = edit.shifti
  var r: Rune
  while i < edit.news.len and dispw < edit.maxwidth:
    fastRuneAt(edit.news, i, r)
    dispw += r.width()
  return dispw

proc shiftView(edit: LineEdit) =
  # Shift view so it contains the cursor.
  if edit.cursorx < edit.shiftx:
    edit.shiftx = edit.cursorx
    edit.shifti = edit.cursori
  # Shift view so it is completely filled.
  if edit.shiftx > 0:
    let dispw = edit.getDisplayWidth()
    if dispw < edit.maxwidth:
      let targetx = edit.shiftx - edit.maxwidth + dispw
      if targetx <= 0:
        edit.shiftx = 0
        edit.shifti = 0
      else:
        while edit.shiftx > targetx:
          let (r, len) = edit.news.lastRune(edit.shifti - 1)
          edit.shiftx -= r.width()
          edit.shifti -= len
  edit.padding = 0
  # Shift view so it contains the cursor. (act 2)
  if edit.shiftx < edit.cursorx - edit.maxwidth:
    while edit.shiftx < edit.cursorx - edit.maxwidth and
        edit.shifti < edit.news.len:
      var r: Rune
      fastRuneAt(edit.news, edit.shifti, r)
      edit.shiftx += r.width()
    if edit.shiftx > edit.cursorx - edit.maxwidth:
      # skipped over a cell because of a double-width char
      edit.padding = 1

proc generateOutput*(edit: LineEdit): FixedGrid =
  edit.shiftView()
  result = newFixedGrid(edit.promptw + edit.maxwidth)
  var x = 0
  for r in edit.prompt.runes:
    result[x].str &= $r
    x += r.width()
    if x >= result.width: break
  for i in 0 ..< edit.padding:
    if x < result.width:
      result[x].str = " "
      inc x
  var i = edit.shifti
  while i < edit.news.len:
    var r: Rune
    fastRuneAt(edit.news, i, r)
    if not edit.hide:
      let w = r.width()
      if x + w > result.width: break
      if r.isControlChar():
        result[x].str &= '^'
        inc x
        result[x].str &= char(r).getControlLetter()
        inc x
      else:
        result[x].str &= $r
        x += w
    else:
      if x + 1 > result.width: break
      result[x].str &= '*'
      inc x

proc getCursorX*(edit: LineEdit): int =
  return edit.promptw + edit.cursorx + edit.padding - edit.shiftx

proc insertCharseq(edit: LineEdit, s: string) =
  let s = if edit.escNext:
    s
  else:
    deleteChars(s, edit.disallowed)
  edit.escNext = false
  if s.len == 0:
    return
  let rem = edit.news.substr(edit.cursori)
  edit.news.setLen(edit.cursori)
  edit.news &= s
  edit.news &= rem
  edit.cursori += s.len
  edit.cursorx += s.notwidth()
  edit.invalid = true

proc cancel(edit: LineEdit) {.jsfunc.} =
  edit.state = CANCEL

proc submit(edit: LineEdit) {.jsfunc.} =
  if edit.hist.lines.len == 0 or edit.news != edit.hist.lines[^1]:
    edit.hist.lines.add(edit.news)
  edit.state = FINISH

proc backspace(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    edit.news.delete(edit.cursori - len .. edit.cursori - 1)
    dec edit.cursori
    edit.cursorx -= r.width()
    edit.invalid = true

proc write*(edit: LineEdit, s: string, cs: Charset): bool =
  if cs == CHARSET_UTF_8:
    if s.validateUtf8() != -1:
      return false
    edit.insertCharseq(s)
  else:
    let ss = newStringStream(s)
    let ds = newDecoderStream(ss, cs, errormode = DECODER_ERROR_MODE_FATAL)
    let es = newEncoderStream(ds, CHARSET_UTF_8)
    let s = es.readAll()
    if ds.failed or es.failed:
      return false
    edit.insertCharseq(s)
  return true

proc write(edit: LineEdit, s: string): bool {.jsfunc.} =
  edit.write(s, CHARSET_UTF_8)

proc delete(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    let len = edit.news.runeLenAt(edit.cursori)
    edit.news.delete(edit.cursori ..< edit.cursori + len)
    edit.invalid = true

proc escape(edit: LineEdit) {.jsfunc.} =
  edit.escNext = true

proc clear(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    edit.news.delete(0..edit.cursori - 1)
    edit.cursori = 0
    edit.cursorx = 0
    edit.invalid = true

proc kill(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0 and edit.cursori < edit.news.len:
    edit.news.setLen(edit.cursori - 1)
    edit.invalid = true

proc backward(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    edit.cursori -= len
    edit.cursorx -= r.width()
    if edit.cursorx < edit.shiftx:
      edit.invalid = true

proc forward(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    var r: Rune
    fastRuneAt(edit.news, edit.cursori, r)
    edit.cursorx += r.width()
    if edit.cursorx >= edit.shiftx + edit.maxwidth:
      edit.invalid = true

proc prevWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  if edit.cursori == 0:
    return
  let (r, len) = edit.news.lastRune(edit.cursori - 1)
  if r.breaksWord(check):
    edit.cursori -= len
    edit.cursorx -= r.width()
  while edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    if r.breaksWord(check):
      break
    edit.cursori -= len
    edit.cursorx -= r.width()
  if edit.cursorx < edit.shiftx:
    edit.invalid = true

proc nextWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  if edit.cursori >= edit.news.len:
    return
  let oc = edit.cursori
  var r: Rune
  fastRuneAt(edit.news, edit.cursori, r)
  if r.breaksWord(check):
    edit.cursorx += r.width()
  else:
    edit.cursori = oc
  while edit.cursori < edit.news.len:
    let pc = edit.cursori
    fastRuneAt(edit.news, edit.cursori, r)
    if r.breaksWord(check):
      edit.cursori = pc
      break
    edit.cursorx += r.width()
  if edit.cursorx >= edit.shiftx + edit.maxwidth:
    edit.invalid = true

proc clearWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  let oc = edit.cursori
  edit.prevWord(check)
  if oc != edit.cursori:
    edit.news.delete(edit.cursori .. oc - 1)
    edit.invalid = true

proc killWord(edit: LineEdit, check = opt(BoundaryFunction)) {.jsfunc.} =
  if edit.cursori >= edit.news.len:
    return
  let oc = edit.cursori
  let ox = edit.cursorx
  edit.nextWord()
  if edit.cursori != oc:
    if edit.cursori < edit.news.len:
      let len = edit.news.runeLenAt(edit.cursori)
      edit.news.delete(oc ..< edit.cursori + len)
    else:
      edit.news.delete(oc ..< edit.cursori)
    edit.cursori = oc
    edit.cursorx = ox
    edit.invalid = true

proc begin(edit: LineEdit) {.jsfunc.} =
  edit.cursori = 0
  edit.cursorx = 0
  if edit.shiftx > 0:
    edit.invalid = true

proc `end`(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    edit.cursori = edit.news.len
    edit.cursorx = edit.news.notwidth()
    if edit.cursorx >= edit.shiftx + edit.maxwidth:
      edit.invalid = true

proc prevHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex > 0:
    if edit.news.len > 0:
      edit.histtmp = $edit.news
    dec edit.histindex
    edit.news = edit.hist.lines[edit.histindex]
    edit.end()
    edit.invalid = true

proc nextHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex + 1 < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.hist.lines[edit.histindex]
    edit.end()
    edit.invalid = true
  elif edit.histindex < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.histtmp
    edit.end()
    edit.histtmp = ""

proc readLine*(prompt: string, termwidth: int, current = "",
    disallowed: set[char] = {}, hide = false, hist: LineHistory): LineEdit =
  result = LineEdit(
    prompt: prompt,
    promptw: prompt.width(),
    news: current,
    disallowed: disallowed,
    hide: hide,
    invalid: true
  )
  result.cursori = result.news.len
  result.cursorx = result.news.notwidth()
  # - 1, so that the cursor always has place
  result.maxwidth = termwidth - result.promptw - 1
  result.hist = hist
  result.histindex = result.hist.lines.len

proc addLineEditModule*(ctx: JSContext) =
  ctx.registerType(LineEdit)
