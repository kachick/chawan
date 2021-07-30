import terminal
import tables
import unicode
import strutils
import sequtils

import ../utils/twtstr
import ../utils/radixtree

import ../config

template print*(s: varargs[string, `$`]) =
  for x in s:
    stdout.write(x)

template printesc*(s: string) =
  for r in s.runes:
    if r.isControlChar():
      stdout.write(('^' & $($r)[0].getControlLetter())
                   .ansiFgColor(fgBlue).ansiStyle(styleBright).ansiReset())
    else:
      stdout.write($r)

template printspc(i: int) =
  print(' '.repeat(i))

template eprint*(s: varargs[string, `$`]) = {.cast(noSideEffect).}:
  var a = false
  for x in s:
    if not a:
      a = true
    else:
      stderr.write(' ')
    stderr.write(x)
  stderr.write('\n')

proc termGoto*(x: int, y: int) =
  setCursorPos(stdout, x, y)

proc getNormalAction*(s: string): TwtAction =
  if normalActionRemap.hasKey(s):
    return normalActionRemap[s]
  return NO_ACTION

proc getLinedAction*(s: string): TwtAction =
  if linedActionRemap.hasKey(s):
    return linedActionRemap[s]
  return NO_ACTION

type LineState = object
  news: seq[Rune]
  s: string
  feedNext: bool
  escNext: bool
  comp: bool
  compn: RadixNode[string]
  compa: int
  comps: string
  cursor: int
  shift: int
  minlen: int
  maxlen: int
  displen: int
  spaces: seq[string]

proc backward(state: LineState, i: int) =
  if i == 1:
    print('\b')
  else:
    cursorBackward(i)

proc forward(state: LineState, i: int) =
  cursorForward(i)

proc begin(state: LineState) =
  print('\r')

  state.forward(state.minlen)

proc space(state: LineState, i: int) =
  print(state.spaces[i])

proc kill(state: LineState) =
  when defined(windows):
    let w = min(state.news.width(state.cursor), state.displen)
    state.space(w)
    state.backward(w)
  else:
    print("\e[K")

proc fullRedraw(state: var LineState) =
    state.displen = state.maxlen - 1
    if state.cursor > state.shift:
      var shiftw = state.news.width(state.shift, state.cursor)
      while shiftw > state.maxlen - 1:
        inc state.shift
        shiftw -= state.news[state.shift].width()
    else:
      state.shift = max(state.cursor - 1, 0)

    var dispw = state.news.width(state.shift, state.shift + state.displen)
    if state.shift + state.displen > state.news.len:
      state.displen = state.news.len - state.shift
    while dispw > state.maxlen - 1:
      dispw -= state.news[state.shift + state.displen - 1].width()
      dec state.displen

    state.begin()
    let os = state.news.substr(state.shift, state.shift + state.displen)
    printesc($os)
    state.space(max(state.maxlen - os.width(), 0))

    state.begin()
    state.forward(state.news.width(state.shift, state.cursor))

proc zeroShiftRedraw(state: var LineState) =
  state.shift = 0
  state.displen = state.maxlen - 1

  var dispw = state.news.width(0, state.displen)
  if state.displen > state.news.len:
    state.displen = state.news.len
  while dispw > state.maxlen - 1:
    dispw -= state.news[state.displen - 1].width()
    dec state.displen

  state.begin()
  let os = state.news.substr(0, state.displen)
  printesc($os)
  state.space(max(state.maxlen - os.width(), 0))

  state.begin()
  state.forward(state.news.width(0, state.cursor))

proc insertCharseq(state: var LineState, cs: var seq[Rune]) =
  let escNext = state.escNext
  cs.keepIf(func(r: Rune): bool = escNext or not r.isControlChar())
  state.escNext = false
  if cs.len == 0:
    return
  elif state.cursor >= state.news.len and state.news.width(state.shift, state.cursor) + cs.width() < state.displen:
    state.news &= cs
    state.cursor += cs.len
    printesc($cs)
  else:
    state.news.insert(cs, state.cursor)
    state.cursor += cs.len
    state.fullRedraw()

proc insertCompose(state: var LineState, c: char) =
  state.comps &= c
  let n = state.compn{state.comps}
  if n != state.compn:
    state.compn = n
    state.compa += state.comps.len
    state.comps = ""
  if state.compn.hasPrefix(state.comps, state.compn) and n.children.len > 0:
    state.feedNext = true
  else:
    var cs: seq[Rune]
    if state.compn.leaf:
      cs = state.compn.value.toRunes()
    else:
      cs = state.s.substr(0, state.compa - 1).toRunes()
    state.comps = state.s.substr(state.compa)
    if state.comps.len > 0 and composeRemap.hasPrefix(state.comps):
      state.compa = state.comps.len
      state.compn = composeRemap{state.comps}
      state.s = state.comps
      state.comps = ""
      state.feedNext = true
    else:
      cs &= state.comps.toRunes()
      state.compa = 0
      state.compn = composeRemap
      state.comps = ""

    state.insertCharseq(cs)

proc readLine*(current: var string, minlen: int, maxlen: int): bool =
  var state: LineState
  state.news = current.toRunes()
  state.compn = composeRemap
  state.cursor = state.news.len
  state.minlen = minlen
  state.maxlen = maxlen
  state.displen = state.maxlen - 1
  #ugh
  for i in 0..(maxlen - minlen):
    state.spaces.add(' '.repeat(i))
  printesc(current)
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
      current = $state.news
      return true
    of ACTION_LINED_BACKSPACE:
      if state.cursor > 0:
        state.news.delete(state.cursor - 1, state.cursor - 1)
        dec state.cursor
        state.fullRedraw()
    of ACTION_LINED_DELETE:
      if state.cursor > 0 and state.cursor < state.news.len:
        state.news.delete(state.cursor, state.cursor)
        state.fullRedraw()
    of ACTION_LINED_ESC:
      state.escNext = true
    of ACTION_LINED_CLEAR:
      if state.cursor > 0:
        state.news.delete(0, state.cursor - 1)
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
          state.backward(state.news[state.cursor].width())
        else:
          state.fullRedraw()
    of ACTION_LINED_FORWARD:
      if state.cursor < state.news.len:
        inc state.cursor
        if state.news.width(state.shift, state.cursor) < state.displen:
          var n = 1
          if state.news.len > state.cursor:
            n = state.news[state.cursor].width()
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
          state.backward(state.news.width(state.cursor, oc))
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
        let dw = state.news.width(oc, state.cursor)
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
        let w = state.news.width(state.cursor - chars, state.cursor)
        state.news.delete(state.cursor - chars, state.cursor - 1)
        state.cursor -= chars
        if state.cursor > state.news.len and state.shift == 0:
          state.backward(w)
          state.space(w)
          state.backward(w)
        else:
          state.fullRedraw()
    of ACTION_LINED_BEGIN:
      if state.cursor > 0:
        if state.shift == 0:
          state.backward(state.news.width(0, state.cursor))
        else:
          state.fullRedraw()
        state.cursor = 0
    of ACTION_LINED_END:
      if state.cursor < state.news.len:
        if state.news.width(state.shift, state.news.len) < maxlen:
          state.forward(state.news.width(state.cursor, state.news.len))
        else:
          state.fullRedraw()
        state.cursor = state.news.len
    of ACTION_LINED_COMPOSE_TOGGLE:
      state.comp = not state.comp
      state.compn = composeRemap
      state.compa = 0
      state.comps = ""
    of ACTION_FEED_NEXT:
      state.feedNext = true
    elif state.comp:
      state.insertCompose(c)
    elif validateUtf8(state.s) == -1:
      var cs = state.s.toRunes()
      state.insertCharseq(cs)
    else:
      state.feedNext = true

proc readLine*(prompt: string, current: var string, termwidth: int): bool =
  printesc(prompt)
  readLine(current, prompt.width(), termwidth - prompt.len)
