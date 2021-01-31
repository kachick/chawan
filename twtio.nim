import terminal
import tables
import strutils
import unicode

import twtstr
import config

template print*(s: varargs[string, `$`]) =
  for x in s:
    stdout.write(x)

template printesc*(s: string) =
  for ruby in s:
    if ($ruby)[0].isControlChar():
      stdout.write(($($ruby)[0].getControlLetter()).ansiFgColor(fgBlue).ansiStyle(styleBright).ansiReset())
    else:
      stdout.write($ruby)

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

proc readLine*(prompt: string, current: var string): bool =
  var new = current
  print(prompt)
  print(' ')
  printesc(new)
  var s = ""
  var feedNext = false
  var escNext = false
  var cursor = new.runeLen
  while true:
    if not feedNext:
      s = ""
    else:
      feedNext = false
    let c = getch()
    s &= c
    var rl = new.runeLen()
    var action = getLinedAction(s)
    if escNext:
      action = NO_ACTION
    case action
    of ACTION_LINED_CANCEL:
      return false
    of ACTION_LINED_SUBMIT:
      current = new
      return true
    of ACTION_LINED_BACKSPACE:
      if cursor > 0:
        print(' '.repeat(rl - cursor + 1))
        print('\b'.repeat(rl - cursor + 1))
        print("\b \b")
        new = new.runeSubstr(0, cursor - 1) & new.runeSubstr(cursor)
        rl = new.runeLen()
        cursor -= 1
        printesc(new.runeSubstr(cursor))
        print('\b'.repeat(rl - cursor))
    of ACTION_LINED_ESC:
      escNext = true
    of ACTION_LINED_CLEAR:
      print(' '.repeat(rl - cursor + 1))
      print('\b'.repeat(rl - cursor + 1))
      print('\b'.repeat(cursor))
      print(' '.repeat(cursor))
      print('\b'.repeat(cursor))
      new = new.runeSubstr(cursor)
      rl = new.runeLen()
      printesc(new)
      print('\b'.repeat(rl))
      cursor = 0
    of ACTION_LINED_KILL:
      print(' '.repeat(rl - cursor + 1))
      print('\b'.repeat(rl - cursor + 1))
      new = new.runeSubstr(0, cursor)
    of ACTION_LINED_BACK:
      if cursor > 0:
        cursor -= 1
        print("\b")
    of ACTION_LINED_FORWARD:
      if cursor < rl:
        var rune: Rune
        new.fastRuneAt(cursor, rune, false)
        printesc($rune)
        inc cursor
    of ACTION_LINED_PREV_WORD:
      while cursor > 0:
        print('\b')
        cursor -= 1
        var rune: Rune
        new.fastRuneAt(cursor, rune, false)
        if rune == Rune(' '):
          break
    of ACTION_LINED_NEXT_WORD:
      while cursor < rl:
        var rune: Rune
        new.fastRuneAt(cursor, rune, false)
        printesc($rune)
        inc cursor
        if cursor < rl:
          new.fastRuneAt(cursor, rune, false)
          if rune == Rune(' '):
            break
    of ACTION_LINED_KILL_WORD:
      var chars = 0
      while cursor > chars:
        inc chars
        var rune: Rune
        new.fastRuneAt(cursor - chars, rune, false)
        if rune == Rune(' '):
          break
      if chars > 0:
        print(' '.repeat(rl - cursor + 1))
        print('\b'.repeat(rl - cursor + 1))
        print("\b \b".repeat(chars))
        new = new.runeSubstr(0, cursor - chars) & new.runeSubstr(cursor)
        rl = new.runeLen()
        cursor -= chars
        printesc(new.runeSubstr(cursor))
        print('\b'.repeat(rl - cursor))
    of ACTION_FEED_NEXT:
      feedNext = true
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
      print(' '.repeat(rl - cursor + 1))
      print('\b'.repeat(rl - cursor + 1))
      new = new.runeSubstr(0, cursor) & cs & new.runeSubstr(cursor)
      rl = new.runeLen()
      printesc(new.runeSubstr(cursor))
      print('\b'.repeat(rl - cursor - 1))
      inc cursor
    else:
      feedNext = true
