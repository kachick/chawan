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

const breakWord = [
  Rune('\n'), Rune('/'), Rune('\\'), Rune(' '), Rune('&'), Rune('=')
]

#proc readLine*(prompt: string, current: var string, termwidth: int): bool =
#  var new = current
#  print(prompt)
#  let maxlen = termwidth - prompt.len
#  printesc(new)
#  var s = ""
#  var feedNext = false
#  var escNext = false
#  var cursor = new.runeLen
#  var shift = 0
#  while true:
#    var rl = new.runeLen()
#
#    if cursor < shift:
#      shift = cursor
#    elif cursor - shift > maxlen:
#      shift += cursor - maxlen
#
#    if not feedNext:
#      s = ""
#    else:
#      feedNext = false
#    let c = getch()
#    s &= c
#    var action = getLinedAction(s)
#    if escNext:
#      action = NO_ACTION
#    case action
#    of ACTION_LINED_CANCEL:
#      return false
#    of ACTION_LINED_SUBMIT:
#      current = new
#      return true
#    of ACTION_LINED_BACKSPACE:
#      if cursor > 0:
#        print(' '.repeat(rl - cursor + 1))
#        print('\b'.repeat(rl - cursor + 1))
#        print("\b \b")
#        new = new.runeSubstr(0, cursor - 1) & new.runeSubstr(cursor)
#        rl = new.runeLen()
#        cursor -= 1
#        printesc(new.runeSubstr(cursor))
#        print('\b'.repeat(rl - cursor))
#    of ACTION_LINED_ESC:
#      escNext = true
#    of ACTION_LINED_CLEAR:
#      print('\r')
#      print(' '.repeat(termwidth))
#      print('\r')
#      new = new.runeSubstr(cursor)
#      rl = new.runeLen()
#      printesc(prompt)
#      printesc(new.maxString(maxlen + 1))
#      print('\r')
#      printesc(prompt)
#      cursor = 0
#    of ACTION_LINED_KILL:
#      print(' '.repeat(rl - cursor + 1))
#      print('\b'.repeat(rl - cursor + 1))
#      new = new.runeSubstr(0, cursor)
#    of ACTION_LINED_BACK:
#      if cursor > 0:
#        if cursor < maxlen:
#          print('\b')
#        dec cursor
#    of ACTION_LINED_FORWARD:
#      if cursor < rl:
#        if cursor + 1 < maxlen:
#          var rune: Rune
#          new.fastRuneAt(cursor, rune, false)
#          printesc($rune)
#        elif cursor + 1 == maxlen:
#          print('$')
#        inc cursor
#    of ACTION_LINED_PREV_WORD:
#      while cursor > 0:
#        print('\b')
#        cursor -= 1
#        var rune: Rune
#        new.fastRuneAt(cursor, rune, false)
#        if rune in breakWord:
#          break
#    of ACTION_LINED_NEXT_WORD:
#      while cursor < rl:
#        var rune: Rune
#        new.fastRuneAt(cursor, rune, false)
#        printesc($rune)
#        inc cursor
#        if cursor < rl:
#          new.fastRuneAt(cursor, rune, false)
#          if rune in breakWord:
#            break
#    of ACTION_LINED_KILL_WORD:
#      var chars = 0
#      while cursor > chars:
#        inc chars
#        var rune: Rune
#        new.fastRuneAt(cursor - chars, rune, false)
#        if rune in breakWord:
#          break
#      if chars > 0:
#        print(' '.repeat(rl - cursor + 1))
#        print('\b'.repeat(rl - cursor + 1))
#        print("\b \b".repeat(chars))
#        new = new.runeSubstr(0, cursor - chars) & new.runeSubstr(cursor)
#        rl = new.runeLen()
#        cursor -= chars
#        printesc(new.runeSubstr(cursor))
#        print('\b'.repeat(rl - cursor))
#    of ACTION_FEED_NEXT:
#      feedNext = true
#    elif validateUtf8(s) == -1:
#      var cs = ""
#      for c in s:
#        if not c.isControlChar():
#          cs &= c
#        elif escNext:
#          cs &= c
#          escNext = false
#      escNext = false
#      if cs.len == 0:
#        continue
#      if rl + 1 < maxlen:
#        print(' '.repeat(rl - cursor + 1))
#        print('\b'.repeat(rl - cursor + 1))
#      new = new.runeSubstr(0, cursor) & cs & new.runeSubstr(cursor)
#      rl = new.runeLen()
#      if cursor - shift > maxlen:
#        shift += maxlen - cursor
#      if shift == 0:
#        printesc(new.runeSubstr(cursor, min(maxlen - cursor - 1, rl)))
#        print('\b'.repeat(max(min(maxlen - cursor - 2, rl - cursor - 1), 0)))
#      else:
#        print('\r')
#        print(' '.repeat(termwidth))
#        print('\r')
#        print(prompt)
#        print(new.runeSubstr(shift, min(maxlen - 1, rl - shift)))
#        if maxlen < rl - shift:
#          print(new.runeSubstr(shift, maxlen - 1))
#          print('\b'.repeat(maxlen - cursor + shift))
#        else:
#          print(new.runeSubstr(shift, rl - shift))
#          print('\b'.repeat(rl + shift - cursor))
#      inc cursor
#    else:
#      feedNext = true

proc readLine*(prompt: string, current: var string, termwidth: int): bool =
  var new = current
  print(prompt)
  let maxlen = termwidth - prompt.len
  printesc(new)
  var s = ""
  var feedNext = false
  var escNext = false
  var cursor = new.runeLen
  var shift = 0
  while true:
    var rl = new.runeLen()
    print('\r')
    print(' '.repeat(termwidth))
    print('\r')
    printesc(prompt & new)
    print('\r')
    cursorForward(prompt.len + cursor)

    if cursor < shift:
      shift = cursor
    elif cursor - shift > maxlen:
      shift += cursor - maxlen

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
      current = new
      return true
    of ACTION_LINED_BACKSPACE:
      if cursor > 0:
        new = new.runeSubstr(0, cursor - 1) & new.runeSubstr(cursor)
        rl = new.runeLen()
        dec cursor
    of ACTION_LINED_ESC:
      escNext = true
    of ACTION_LINED_CLEAR:
      new = new.runeSubstr(cursor)
      rl = new.runeLen()
      cursor = 0
    of ACTION_LINED_KILL:
      new = new.runeSubstr(0, cursor)
    of ACTION_LINED_BACK:
      if cursor > 0:
        dec cursor
    of ACTION_LINED_FORWARD:
      if cursor < rl:
        inc cursor
    of ACTION_LINED_PREV_WORD:
      while cursor > 0:
        dec cursor
        var rune: Rune
        new.fastRuneAt(cursor, rune, false)
        if rune in breakWord:
          break
    of ACTION_LINED_NEXT_WORD:
      while cursor < rl:
        var rune: Rune
        inc cursor
        if cursor < rl:
          new.fastRuneAt(cursor, rune, false)
          if rune in breakWord:
            break
    of ACTION_LINED_KILL_WORD:
      var chars = 0
      while cursor > chars:
        inc chars
        var rune: Rune
        new.fastRuneAt(cursor - chars, rune, false)
        if rune in breakWord:
          break
      if chars > 0:
        new = new.runeSubstr(0, cursor - chars) & new.runeSubstr(cursor)
        rl = new.runeLen()
        cursor -= chars
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
      new = new.runeSubstr(0, cursor) & cs & new.runeSubstr(cursor)
      rl = new.runeLen()
      inc cursor
    else:
      feedNext = true
