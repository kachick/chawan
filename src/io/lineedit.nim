import terminal
import unicode
import strutils
import sequtils
import sugar

import utils/twtstr
import config/config

type LineState* = object
  news*: seq[Rune]
  prompt*: string
  current: string
  s: string
  feedNext: bool
  escNext: bool
  cursor: int
  shift: int
  minlen: int
  maxlen: int
  displen: int
  disallowed: set[char]
  callback: proc(state: var LineState): bool {.closure.}

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

template kill(state: LineState, i: int) =
  state.space(i)
  state.backward(i)

template kill(state: LineState) =
  let w = min(state.news.lwidth(state.cursor), state.displen)
  state.kill(w)

proc backward(state: LineState, i: int) =
  if i > 0:
    if i == 1:
      print('\b')
    else:
      cursorBackward(i)

proc forward(state: LineState, i: int) =
  if i > 0:
    cursorForward(i)

proc begin(state: LineState) =
  print('\r')
  state.forward(state.minlen)

proc space(state: LineState, i: int) =
  print(' '.repeat(i))

proc redraw(state: var LineState) =
  var dispw = state.news.lwidth(state.shift, state.shift + state.displen)
  if state.shift + state.displen > state.news.len:
    state.displen = state.news.len - state.shift
  while dispw > state.maxlen - 1:
    dispw -= state.news[state.shift + state.displen - 1].lwidth()
    dec state.displen

  state.begin()
  let os = state.news.substr(state.shift, state.shift + state.displen)
  printesc($os)
  state.space(max(state.maxlen - state.minlen - os.lwidth(), 0))

  state.begin()
  state.forward(state.news.lwidth(state.shift, state.cursor))

proc zeroShiftRedraw(state: var LineState) =
  state.shift = 0
  state.displen = state.maxlen - 1
  state.redraw()

proc fullRedraw(state: var LineState) =
  state.displen = state.maxlen - 1
  if state.cursor > state.shift:
    var shiftw = state.news.lwidth(state.shift, state.cursor)
    while shiftw > state.maxlen - 1:
      inc state.shift
      shiftw -= state.news[state.shift].lwidth()
  else:
    state.shift = max(state.cursor - 1, 0)

  state.redraw()

proc insertCharseq(state: var LineState, cs: var seq[Rune], disallowed: set[char]) =
  let escNext = state.escNext
  cs.keepIf((r) => (escNext or not r.isControlChar) and not (r.isAscii and char(r) in disallowed))
  state.escNext = false
  if cs.len == 0:
    return

  if state.cursor >= state.news.len and state.news.lwidth(state.shift, state.cursor) + cs.lwidth() < state.displen:
    state.news &= cs
    state.cursor += cs.len
    printesc($cs)
  else:
    state.news.insert(cs, state.cursor)
    state.cursor += cs.len
    state.fullRedraw()

proc readLine(state: var LineState): bool =
  printesc(state.prompt)
  printesc(state.current)

  while true:
    if not state.feedNext:
      state.s = ""
    else:
      state.feedNext = false

    let c = getch()
    state.s &= c

    var action = getLinedAction(state.s)
    if state.escNext:
      action = NO_ACTION
    case action
    of ACTION_LINED_CANCEL:
      return false
    of ACTION_LINED_SUBMIT:
      return true
    of ACTION_LINED_BACKSPACE:
      if state.cursor > 0:
        let w = state.news[state.cursor - 1].lwidth()
        state.news.delete(state.cursor - 1..state.cursor - 1)
        dec state.cursor
        if state.cursor == state.news.len and state.shift == 0:
          state.backward(w)
          state.kill(w)
        else:
          state.fullRedraw()
    of ACTION_LINED_DELETE:
      if state.cursor > 0 and state.cursor < state.news.len:
        let w = state.news[state.cursor - 1].lwidth()
        state.news.delete(state.cursor..state.cursor)
        if state.cursor == state.news.len and state.shift == 0:
          state.kill(w)
        else:
          state.fullRedraw()
    of ACTION_LINED_ESC:
      state.escNext = true
    of ACTION_LINED_CLEAR:
      if state.cursor > 0:
        state.news.delete(0..state.cursor - 1)
        state.cursor = 0
        state.zeroShiftRedraw()
    of ACTION_LINED_KILL:
      if state.cursor < state.news.len:
        state.kill()
        state.news.setLen(state.cursor)
    of ACTION_LINED_BACK:
      if state.cursor > 0:
        dec state.cursor
        if state.cursor > state.shift or state.shift == 0:
          state.backward(state.news[state.cursor].lwidth())
        else:
          state.fullRedraw()
    of ACTION_LINED_FORWARD:
      if state.cursor < state.news.len:
        inc state.cursor
        if state.news.lwidth(state.shift, state.cursor) < state.displen:
          var n = 1
          if state.news.len > state.cursor:
            n = state.news[state.cursor].lwidth()
          state.forward(n)
        else:
          state.fullRedraw()
    of ACTION_LINED_PREV_WORD:
      let oc = state.cursor
      while state.cursor > 0:
        dec state.cursor
        if state.news[state.cursor].breaksWord():
          break
      if state.cursor != oc:
        if state.cursor > state.shift or state.shift == 0:
          state.backward(state.news.lwidth(state.cursor, oc))
        else:
          state.fullRedraw()
    of ACTION_LINED_NEXT_WORD:
      let oc = state.cursor
      while state.cursor < state.news.len:
        inc state.cursor
        if state.cursor < state.news.len:
          if state.news[state.cursor].breaksWord():
            break

      if state.cursor != oc:
        let dw = state.news.lwidth(oc, state.cursor)
        if oc + dw - state.shift < state.displen:
          state.forward(dw)
        else:
          state.fullRedraw()
    of ACTION_LINED_KILL_WORD:
      var chars = 0
      if state.cursor > chars:
        inc chars

      while state.cursor > chars:
        inc chars
        if state.news[state.cursor - chars].breaksWord():
          dec chars
          break
      if chars > 0:
        let w = state.news.lwidth(state.cursor - chars, state.cursor)
        state.news.delete(state.cursor - chars..state.cursor - 1)
        state.cursor -= chars
        if state.cursor == state.news.len and state.shift == 0:
          state.backward(w)
          state.kill(w)
        else:
          state.fullRedraw()
    of ACTION_LINED_BEGIN:
      if state.cursor > 0:
        if state.shift == 0:
          state.backward(state.news.lwidth(0, state.cursor))
        else:
          state.fullRedraw()
        state.cursor = 0
    of ACTION_LINED_END:
      if state.cursor < state.news.len:
        if state.news.lwidth(state.shift, state.news.len) < state.maxlen:
          state.forward(state.news.lwidth(state.cursor, state.news.len))
        else:
          state.fullRedraw()
        state.cursor = state.news.len
    of ACTION_FEED_NEXT:
      state.feedNext = true
    elif validateUtf8(state.s) == -1:
      var cs = state.s.toRunes()
      state.insertCharseq(cs, state.disallowed)
      if state.callback(state):
        state.fullRedraw()
    else:
      state.feedNext = true

proc readLine*(prompt: string, current: var string, termwidth: int,
               disallowed: set[char],
               callback: proc(state: var LineState): bool {.closure.}): bool =
  var state: LineState

  state.prompt = prompt
  state.current = current
  state.news = current.toRunes()
  state.cursor = state.news.len
  state.minlen = prompt.lwidth()
  state.maxlen = termwidth - prompt.len
  state.displen = state.maxlen - 1
  state.disallowed = disallowed
  state.callback = callback

  if state.readLine():
    current = $state.news
    return true
  return false

proc readLine*(prompt: string, current: var string, termwidth: int,
               disallowed: set[char] = {}): bool =
  readLine(prompt, current, termwidth, disallowed, (proc(state: var LineState): bool = false))
