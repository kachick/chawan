import terminal
import tables
import unicode

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
  var news = current.toRunes()
  let maxlen = termwidth - prompt.len
  var s = ""
  var feedNext = false
  var escNext = false
  var comp = false
  var compi: uint16 = 0
  var compa = 0
  var comps = ""
  var cursor = news.len
  var shift = 0
  while true:
    let rl = news.len
    if cursor < shift:
      shift = max(cursor - 1, 0)
    else:
      while news.substr(shift, shift + cursor).width() > maxlen - 1:
        shift += news[^1].width()

    eraseLine()
    printesc(prompt & $news.substr(shift, shift + maxlen - 1))

    print('\r')
    cursorForward(prompt.len + news.substr(shift, cursor).width())

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
    of ACTION_LINED_DELETE:
      if cursor > 0 and cursor < rl:
        news = news.substr(0, cursor) & news.substr(cursor + 1)
    of ACTION_LINED_ESC:
      escNext = true
    of ACTION_LINED_CLEAR:
      news = news.substr(cursor)
      cursor = 0
    of ACTION_LINED_KILL:
      news = news.substr(0, cursor)
    of ACTION_LINED_BACK:
      if cursor > 0:
        dec cursor
    of ACTION_LINED_FORWARD:
      if cursor < rl:
        inc cursor
    of ACTION_LINED_PREV_WORD:
      while cursor > 0:
        dec cursor
        if news[cursor].breaksWord():
          break
    of ACTION_LINED_NEXT_WORD:
      while cursor < rl:
        inc cursor
        if cursor < rl:
          if news[cursor].breaksWord():
            break
    of ACTION_LINED_KILL_WORD:
      var chars = 0
      while cursor > chars:
        inc chars
        if news[cursor - chars].breaksWord():
          break
      if chars > 0:
        news = news.substr(0, cursor - chars) & news.substr(cursor)
        cursor -= chars
    of ACTION_LINED_COMPOSE_ON:
      comp = true
      compi = 0
      compa = 0
      comps = ""
    of ACTION_LINED_COMPOSE_OFF:
      comp = false
      compi = 0
      compa = 0
      comps = ""
    of ACTION_LINED_COMPOSE_TOGGLE:
      comp = not comp
      compi = 0
      compa = 0
      comps = ""
    of ACTION_FEED_NEXT:
      feedNext = true
    elif comp:
      comps &= c
      let n = composeRemap.getPrefix(comps, compi)
      if n != compi:
        compi = n
        compa += comps.len
        comps = ""
      if composeRemap.hasPrefix(comps, compi) and composeRemap.nodes[n].children.len > 0:
        feedNext = true
      else:
        var cs = ""
        if composeRemap.nodes[compi].leaf:
          cs = composeRemap.nodes[compi].value
        else:
          cs = s.substr(0, compa - 1)
        comps = s.substr(compa)
        if not composeRemap.hasPrefix(comps, 0):
          cs &= comps
          comps = ""

        news = news.substr(0, cursor) & cs.toRunes() & news.substr(cursor)
        cursor += cs.runeLen()
        compi = 0
        compa = 0
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
        continue
      news = news.substr(0, cursor) & cs.toRunes() & news.substr(cursor)
      cursor += cs.runeLen()
    else:
      feedNext = true
