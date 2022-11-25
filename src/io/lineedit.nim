import terminal
import unicode
import strutils
import sequtils
import sugar

import bindings/quickjs
import buffer/cell
import config/config
import js/javascript
import utils/twtstr

type
  LineEditState* = enum
    EDIT, FINISH, CANCEL

  LineEdit* = ref object
    news*: seq[Rune]
    prompt*: string
    promptw: int
    current: string
    state*: LineEditState
    escNext*: bool
    cursor: int
    shift: int
    minlen: int
    maxlen: int
    displen: int
    disallowed: set[char]
    hide: bool
    config: Config #TODO get rid of this
    tty: File

func lwidth(r: Rune): int =
  if r.isControlChar():
    return 2
  return r.width()

func lwidth(s: string): int =
  for r in s.runes():
    result += lwidth(r)

func lwidth(s: seq[Rune]): int =
  for r in s:
    result += lwidth(r)

func lwidth(s: seq[Rune], min, max: int): int =
  var i = min
  var mi = min(max, s.len)
  while i < mi:
    result += lwidth(s[i])
    inc i

func lwidth(s: seq[Rune], min: int): int =
  var i = min
  while i < s.len:
    result += lwidth(s[i])
    inc i

template kill0(edit: LineEdit, i: int) =
  edit.space(i)
  edit.backward0(i)

template kill0(edit: LineEdit) =
  let w = min(edit.news.lwidth(edit.cursor), edit.displen)
  edit.kill0(w)

proc backward0(state: LineEdit, i: int) =
  if i > 0:
    if i == 1:
      print('\b')
    else:
      cursorBackward(i)

proc forward0(state: LineEdit, i: int) =
  if i > 0:
    cursorForward(i)

proc begin0(state: LineEdit) =
  print('\r')
  state.forward0(state.minlen)

proc space(edit: LineEdit, i: int) =
  print(' '.repeat(i))

proc generateOutput*(edit: LineEdit): FixedGrid =
  result = newFixedGrid(edit.maxlen)
  let os = edit.news.substr(edit.shift, edit.shift + edit.displen)
  var x = 0
  for r in edit.prompt.runes():
    result[x].str &= $r
    x += r.lwidth()
  if edit.hide:
    for r in os:
      result[x].str = "*"
      x += r.lwidth()
  else:
    for r in os:
      result[x].str &= $r
      x += r.lwidth()

proc getCursorX*(edit: LineEdit): int =
  return edit.promptw + edit.news.lwidth(edit.shift, edit.cursor)

proc redraw(state: LineEdit) =
  var dispw = state.news.lwidth(state.shift, state.shift + state.displen)
  if state.shift + state.displen > state.news.len:
    state.displen = state.news.len - state.shift
  while dispw > state.maxlen - 1:
    dispw -= state.news[state.shift + state.displen - 1].lwidth()
    dec state.displen
  state.begin0()
  let os = state.news.substr(state.shift, state.shift + state.displen)
  if state.hide:
    printesc('*'.repeat(os.lwidth()))
  else:
    printesc($os)
  state.space(max(state.maxlen - state.minlen - os.lwidth(), 0))
  state.begin0()
  state.forward0(state.news.lwidth(state.shift, state.cursor))

proc zeroShiftRedraw(state: LineEdit) =
  state.shift = 0
  state.displen = state.maxlen - 1
  state.redraw()

proc fullRedraw*(state: LineEdit) =
  state.displen = state.maxlen - 1
  if state.cursor > state.shift:
    var shiftw = state.news.lwidth(state.shift, state.cursor)
    while shiftw > state.maxlen - 1:
      inc state.shift
      shiftw -= state.news[state.shift].lwidth()
  else:
    state.shift = max(state.cursor - 1, 0)
  state.redraw()

proc insertCharseq(state: LineEdit, cs: var seq[Rune], disallowed: set[char]) =
  let escNext = state.escNext
  cs.keepIf((r) => (escNext or not r.isControlChar) and not (r.isAscii and char(r) in disallowed))
  state.escNext = false
  if cs.len == 0:
    return

  if state.cursor >= state.news.len and state.news.lwidth(state.shift, state.cursor) + cs.lwidth() < state.displen:
    state.news &= cs
    state.cursor += cs.len
    if state.hide:
      printesc('*'.repeat(cs.lwidth()))
    else:
      printesc($cs)
  else:
    state.news.insert(cs, state.cursor)
    state.cursor += cs.len
    state.fullRedraw()

proc cancel*(edit: LineEdit) {.jsfunc.} =
  edit.state = CANCEL

proc submit*(edit: LineEdit) {.jsfunc.} =
  edit.state = FINISH

proc backspace*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    let w = edit.news[edit.cursor - 1].lwidth()
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
    edit.insertCharseq(cs, edit.disallowed)
    return true

proc delete*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor >= 0 and edit.cursor < edit.news.len:
    let w = edit.news[edit.cursor].lwidth()
    edit.news.delete(edit.cursor..edit.cursor)
    if edit.cursor == edit.news.len and edit.shift == 0:
      edit.kill0(w)
    else:
      edit.fullRedraw()

proc escape*(edit: LineEdit) {.jsfunc.} =
  edit.escNext = true

proc clear*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    edit.news.delete(0..edit.cursor - 1)
    edit.cursor = 0
    edit.zeroShiftRedraw()

proc kill*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    edit.kill0()
    edit.news.setLen(edit.cursor)

proc backward*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    dec edit.cursor
    if edit.cursor > edit.shift or edit.shift == 0:
      edit.backward0(edit.news[edit.cursor].lwidth())
    else:
      edit.fullRedraw()

proc forward*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    inc edit.cursor
    if edit.news.lwidth(edit.shift, edit.cursor) < edit.displen:
      var n = 1
      if edit.news.len > edit.cursor:
        n = edit.news[edit.cursor].lwidth()
      edit.forward0(n)
    else:
      edit.fullRedraw()

proc prevWord*(edit: LineEdit, check = none(BoundaryFunction)) {.jsfunc.} =
  let oc = edit.cursor
  while edit.cursor > 0:
    dec edit.cursor
    if edit.news[edit.cursor].breaksWord(check):
      break
  if edit.cursor != oc:
    if edit.cursor > edit.shift or edit.shift == 0:
      edit.backward0(edit.news.lwidth(edit.cursor, oc))
    else:
      edit.fullRedraw()

proc nextWord*(edit: LineEdit, check = none(BoundaryFunction)) {.jsfunc.} =
  let oc = edit.cursor
  while edit.cursor < edit.news.len:
    inc edit.cursor
    if edit.cursor < edit.news.len:
      if edit.news[edit.cursor].breaksWord(check):
        break
  if edit.cursor != oc:
    let dw = edit.news.lwidth(oc, edit.cursor)
    if oc + dw - edit.shift < edit.displen:
      edit.forward0(dw)
    else:
      edit.fullRedraw()

proc clearWord*(edit: LineEdit, check = none(BoundaryFunction)) {.jsfunc.} =
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

proc killWord*(edit: LineEdit, check = none(BoundaryFunction)) {.jsfunc.} =
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

proc begin*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor > 0:
    if edit.shift == 0:
      edit.backward0(edit.news.lwidth(0, edit.cursor))
    else:
      edit.fullRedraw()
    edit.cursor = 0

proc `end`*(edit: LineEdit) {.jsfunc.} =
  if edit.cursor < edit.news.len:
    if edit.news.lwidth(edit.shift, edit.news.len) < edit.maxlen:
      edit.forward0(edit.news.lwidth(edit.cursor, edit.news.len))
    else:
      edit.fullRedraw()
    edit.cursor = edit.news.len

proc writePrompt*(lineedit: LineEdit) =
  printesc(lineedit.prompt)

proc writeStart*(lineedit: LineEdit) =
  lineedit.writePrompt()
  if lineedit.hide:
    printesc('*'.repeat(lineedit.current.lwidth()))
  else:
    printesc(lineedit.current)

proc readLine*(prompt: string, termwidth: int, current = "",
               disallowed: set[char] = {}, hide = false, config: Config,
               tty: File): LineEdit =
  new(result)
  result.prompt = prompt
  result.promptw = prompt.lwidth()
  result.current = current
  result.news = current.toRunes()
  result.cursor = result.news.len
  result.minlen = prompt.lwidth()
  result.maxlen = termwidth - prompt.len
  result.displen = result.maxlen - 1
  result.disallowed = disallowed
  result.hide = hide
  result.config = config
  result.tty = tty

proc addLineEditModule*(ctx: JSContext) =
  ctx.registerType(LineEdit)
