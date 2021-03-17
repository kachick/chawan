import terminal
import tables
import unicode
import strutils

import twtstr
import config
import radixtree

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

proc readLine*(prompt: string, current: var string, termwidth: int): bool =
  let maxlen = termwidth - prompt.len
  let promptwidth = prompt.width()
  var news = current.toRunes()
  var s = ""
  var feedNext = false
  var escNext = false
  var comp = false
  var compi = composeRemap
  var compa = 0
  var comps = ""
  var cursor = news.len
  var shift = 0
  var redraw = true
  printesc(prompt)
  while true:
    if redraw:
      var displen = maxlen - 1
      if cursor >= shift:
        while news.substr(shift, cursor).width() > maxlen - 1:
          shift += 1
        while news.substr(shift, shift + displen).width() > maxlen - 1:
          displen -= 1

      shift = max(0, min(cursor - 1, shift))

      print('\r')
      cursorForward(promptwidth)
      let os = $news.substr(shift, shift + displen)
      printesc(os)
      print(' '.repeat(max(displen - os.width(), 0)))

      print('\r')
      cursorForward(promptwidth + news.substr(shift, cursor).width())
    else:
      redraw = true

    if not feedNext:
      s = ""
    else:
      feedNext = false

    let c = getch()
    s &= c

    var action = getLinedAction(s)
    if escNext:
      action = NO_ACTION
    case action
    of ACTION_LINED_CANCEL:
      return false
    of ACTION_LINED_SUBMIT:
      current = $news
      return true
    of ACTION_LINED_BACKSPACE:
      if cursor > 0:
        news = news.substr(0, cursor - 1) & news.substr(cursor)
        dec cursor
      else:
        redraw = false
    of ACTION_LINED_DELETE:
      if cursor > 0 and cursor < news.len:
        news = news.substr(0, cursor) & news.substr(cursor + 1)
      else:
        redraw = false
    of ACTION_LINED_ESC:
      escNext = true
    of ACTION_LINED_CLEAR:
      news = news.substr(cursor)
      cursor = 0
    of ACTION_LINED_KILL:
      if cursor > 0:
        news = news.substr(0, cursor)
      else:
        redraw = false
    of ACTION_LINED_BACK:
      if cursor > 0:
        dec cursor
        if cursor > shift:
          redraw = false
          cursorBackward(news[cursor].width())
      else:
        redraw = false
    of ACTION_LINED_FORWARD:
      if cursor < news.len:
        inc cursor
        if news.substr(shift, cursor).width() < maxlen:
          redraw = false
          var n = 1
          if news.len > cursor:
            n = news[cursor].width()
          cursorForward(n)
      else:
        redraw = false
    of ACTION_LINED_PREV_WORD:
      let oc = cursor
      while cursor > 0:
        dec cursor
        if news[cursor].breaksWord():
          break
      if cursor == oc:
        redraw = false
      elif cursor > shift:
        cursorBackward(news.substr(cursor, oc).width())
        redraw = false
    of ACTION_LINED_NEXT_WORD:
      let oc = cursor
      while cursor < news.len:
        inc cursor
        if cursor < news.len:
          if news[cursor].breaksWord():
            break
      if cursor == oc:
        redraw = false
      else:
        let dw = news.substr(oc, cursor).width()
        if oc + dw - shift < maxlen:
          cursorForward(dw)
          redraw = false
    of ACTION_LINED_KILL_WORD:
      var chars = 0

      while cursor > chars:
        inc chars
        if news[cursor - chars].breaksWord():
          break
      if chars > 0:
        let w = news.substr(cursor - chars, cursor).width()
        news = news.substr(0, cursor - chars) & news.substr(cursor)
        cursor -= chars
        if cursor > shift:
          redraw = false
          cursorBackward(w)
          print(' '.repeat(w))
          cursorBackward(w)
      else:
        redraw = false
    of ACTION_LINED_BEGIN:
      if cursor > 0:
        if shift == 0:
          redraw = false
          cursorBackward(news.substr(0, cursor).width())
        cursor = 0
      else:
        redraw = false
    of ACTION_LINED_END:
      if cursor < news.len:
        if news.substr(shift, news.len).width() < maxlen:
          redraw = false
          cursorForward(news.substr(shift, news.len).width())
        cursor = news.len
      else:
        redraw = false
    of ACTION_LINED_COMPOSE_TOGGLE:
      comp = not comp
      compi = composeRemap
      compa = 0
      comps = ""
      redraw = false
    of ACTION_FEED_NEXT:
      feedNext = true
      redraw = false
    elif comp:
      comps &= c
      let n = composeRemap{comps, compi}
      if n != compi:
        compi = n
        compa += comps.len
        comps = ""
      if composeRemap.hasPrefix(comps, compi) and n.children.len > 0:
        feedNext = true
      else:
        var cs = ""
        if compi.leaf:
          cs = compi.value
        else:
          cs = s.substr(0, compa - 1)
        comps = s.substr(compa)
        if comps.len > 0 and composeRemap.hasPrefix(comps):
          compa = comps.len
          compi = composeRemap{comps}
          s = comps
          comps = ""
          feedNext = true
        else:
          cs &= comps
          compa = 0
          compi = composeRemap
          comps = ""

        news = news.substr(0, cursor) & cs.toRunes() & news.substr(cursor)
        cursor += cs.runeLen()
    elif validateUtf8(s) == -1:
      var cs = ""
      for c in s:
        if not c.isControlChar():
          cs &= c
        elif escNext:
          cs &= c
          escNext = false
      escNext = false
      if cs.len == 0:
        redraw = false
        continue

      let csr = cs.toRunes()

      if cursor >= news.len and
          news.substr(shift, cursor).width() + csr.width() < maxlen - 1:
        cursor += csr.len
        news &= csr
        print(csr)
        redraw = false
      else:
        news = news.substr(0, cursor) & csr & news.substr(cursor)
        cursor += csr.len
    else:
      feedNext = true
      redraw = false
