import std/strutils
import std/unicode

import monoucha/quickjs
import monoucha/javascript
import types/cell
import types/opt
import types/winattrs
import utils/luwrap
import utils/strwidth
import utils/twtstr
import utils/wordbreak

import chagashi/charset
import chagashi/decoder

type
  LineEditState* = enum
    lesEdit, lesFinish, lesCancel

  LineHistory* = ref object
    lines: seq[string]

  LineEdit* = ref object
    news*: string
    prompt: string
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
    redraw*: bool

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
  # Make the output grid +1 cell wide, so it covers the whole input area.
  result = newFixedGrid(edit.promptw + edit.maxwidth + 1)
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

proc insertCharseq(edit: LineEdit; s: string) =
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
  edit.redraw = true

proc cancel(edit: LineEdit) {.jsfunc.} =
  edit.state = lesCancel

proc submit(edit: LineEdit) {.jsfunc.} =
  if edit.hist.lines.len == 0 or edit.news != edit.hist.lines[^1]:
    edit.hist.lines.add(edit.news)
  edit.state = lesFinish

proc backspace(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    edit.news.delete(edit.cursori - len .. edit.cursori - 1)
    edit.cursori -= len
    edit.cursorx -= r.width()
    edit.redraw = true
 
proc write*(edit: LineEdit; s: string; cs: Charset): bool =
  if cs == CHARSET_UTF_8:
    if s.validateUTF8Surr() != -1:
      return false
    edit.insertCharseq(s)
  else:
    let td = newTextDecoder(cs)
    var success = false
    let s = td.decodeAll(s, success)
    if not success:
      return false
    edit.insertCharseq(s)
  return true

proc write(edit: LineEdit; s: string): bool {.jsfunc.} =
  if s.validateUTF8Surr() != -1:
    return false
  edit.insertCharseq(s)
  return true

proc delete(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    let len = edit.news.runeLenAt(edit.cursori)
    edit.news.delete(edit.cursori ..< edit.cursori + len)
    edit.redraw = true

proc escape(edit: LineEdit) {.jsfunc.} =
  edit.escNext = true

proc clear(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    edit.news.delete(0..edit.cursori - 1)
    edit.cursori = 0
    edit.cursorx = 0
    edit.redraw = true

proc kill(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    edit.news.setLen(edit.cursori)
    edit.redraw = true

proc backward(edit: LineEdit) {.jsfunc.} =
  if edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    edit.cursori -= len
    edit.cursorx -= r.width()
    if edit.cursorx < edit.shiftx:
      edit.redraw = true

proc forward(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    var r: Rune
    fastRuneAt(edit.news, edit.cursori, r)
    edit.cursorx += r.width()
    if edit.cursorx >= edit.shiftx + edit.maxwidth:
      edit.redraw = true

proc prevWord(edit: LineEdit) {.jsfunc.} =
  if edit.cursori == 0:
    return
  let ctx = LUContext()
  let (r, len) = edit.news.lastRune(edit.cursori - 1)
  if ctx.breaksWord(r):
    edit.cursori -= len
    edit.cursorx -= r.width()
  while edit.cursori > 0:
    let (r, len) = edit.news.lastRune(edit.cursori - 1)
    if ctx.breaksWord(r):
      break
    edit.cursori -= len
    edit.cursorx -= r.width()
  if edit.cursorx < edit.shiftx:
    edit.redraw = true

proc nextWord(edit: LineEdit) {.jsfunc.} =
  if edit.cursori >= edit.news.len:
    return
  let ctx = LUContext()
  let oc = edit.cursori
  var r: Rune
  fastRuneAt(edit.news, edit.cursori, r)
  if ctx.breaksWord(r):
    edit.cursorx += r.width()
  else:
    edit.cursori = oc
  while edit.cursori < edit.news.len:
    let pc = edit.cursori
    fastRuneAt(edit.news, edit.cursori, r)
    if ctx.breaksWord(r):
      edit.cursori = pc
      break
    edit.cursorx += r.width()
  if edit.cursorx >= edit.shiftx + edit.maxwidth:
    edit.redraw = true

proc clearWord(edit: LineEdit) {.jsfunc.} =
  let oc = edit.cursori
  edit.prevWord()
  if oc != edit.cursori:
    edit.news.delete(edit.cursori .. oc - 1)
    edit.redraw = true

proc killWord(edit: LineEdit) {.jsfunc.} =
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
    edit.redraw = true

proc begin(edit: LineEdit) {.jsfunc.} =
  edit.cursori = 0
  edit.cursorx = 0
  if edit.shiftx > 0:
    edit.redraw = true

proc `end`(edit: LineEdit) {.jsfunc.} =
  if edit.cursori < edit.news.len:
    edit.cursori = edit.news.len
    edit.cursorx = edit.news.notwidth()
    if edit.cursorx >= edit.shiftx + edit.maxwidth:
      edit.redraw = true

proc prevHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex > 0:
    if edit.news.len > 0:
      edit.histtmp = $edit.news
    dec edit.histindex
    edit.news = edit.hist.lines[edit.histindex]
    # The begin call is needed so the cursor doesn't get lost outside
    # the string.
    edit.begin()
    edit.end()
    edit.redraw = true

proc nextHist(edit: LineEdit) {.jsfunc.} =
  if edit.histindex + 1 < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.hist.lines[edit.histindex]
    edit.begin()
    edit.end()
    edit.redraw = true
  elif edit.histindex < edit.hist.lines.len:
    inc edit.histindex
    edit.news = edit.histtmp
    edit.begin()
    edit.end()
    edit.histtmp = ""

proc windowChange*(edit: LineEdit; attrs: WindowAttributes) =
  edit.maxwidth = attrs.width - edit.promptw - 1

proc readLine*(prompt, current: string; termwidth: int; disallowed: set[char];
    hide: bool; hist: LineHistory): LineEdit =
  let promptw = prompt.width()
  return LineEdit(
    prompt: prompt,
    promptw: promptw,
    news: current,
    disallowed: disallowed,
    hide: hide,
    redraw: true,
    cursori: current.len,
    cursorx: current.notwidth(),
    # - 1, so that the cursor always has place
    maxwidth: termwidth - promptw - 1,
    hist: hist,
    histindex: hist.lines.len
  )

proc addLineEditModule*(ctx: JSContext) =
  ctx.registerType(LineEdit)
