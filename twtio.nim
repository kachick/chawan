import terminal
import tables
import strutils

import twtstr
import config

template print*(s: varargs[string, `$`]) =
  for x in s:
    stdout.write(x)

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
  print(new)
  var s = ""
  var feedNext = false
  var cursor = new.len
  while true:
    if not feedNext:
      s = ""
    else:
      feedNext = false
    let c = getch()
    s &= c
    let action = getLinedAction(s)
    case action
    of ACTION_LINED_CANCEL:
      return false
    of ACTION_LINED_SUBMIT:
      current = new
      return true
    of ACTION_LINED_BACKSPACE:
      if cursor > 0:
        print(' '.repeat(new.len - cursor + 1))
        print('\b'.repeat(new.len - cursor + 1))
        print("\b \b")
        new = new.substr(0, cursor - 2) & new.substr(cursor, new.len)
        cursor -= 1
        print(new.substr(cursor, new.len))
        print('\b'.repeat(new.len - cursor))
    of ACTION_LINED_ESC:
      new &= c
      print("^[".addAnsiFgColor(fgBlue).addAnsiStyle(styleBright))
    of ACTION_LINED_CLEAR:
      print(' '.repeat(new.len - cursor + 1))
      print('\b'.repeat(new.len - cursor + 1))
      print('\b'.repeat(cursor))
      print(' '.repeat(cursor))
      print('\b'.repeat(cursor))
      new = new.substr(cursor, new.len)
      print(new)
      print('\b'.repeat(new.len))
      cursor = 0
    of ACTION_LINED_KILL:
      print(' '.repeat(new.len - cursor + 1))
      print('\b'.repeat(new.len - cursor + 1))
      new = new.substr(0, cursor - 1)
    of ACTION_LINED_BACK:
      if cursor > 0:
        cursor -= 1
        print("\b")
    of ACTION_LINED_FORWARD:
      if cursor < new.len:
        print(new[cursor])
        cursor += 1
    of ACTION_LINED_PREV_WORD:
      while cursor > 0:
        print('\b')
        cursor -= 1
        if new[cursor] == ' ':
          break
    of ACTION_LINED_NEXT_WORD:
      while cursor < new.len:
        print(new[cursor])
        cursor += 1
        if cursor < new.len and new[cursor] == ' ':
          break
    of ACTION_LINED_KILL_WORD:
      var chars = 0
      while cursor > chars:
        chars += 1
        if new[cursor - chars] == ' ':
          break
      if chars > 0:
        print(' '.repeat(new.len - cursor + 1))
        print('\b'.repeat(new.len - cursor + 1))
        print("\b \b".repeat(chars))
        new = new.substr(0, cursor - 1 - chars) & new.substr(cursor, new.len)
        cursor -= chars
        print(new.substr(cursor, new.len))
        print('\b'.repeat(new.len - cursor))
    of ACTION_FEED_NEXT:
      feedNext = true
    else:
      print(' '.repeat(new.len - cursor + 1))
      print('\b'.repeat(new.len - cursor + 1))
      new = new.substr(0, cursor - 1) & c & new.substr(cursor, new.len)
      print(new.substr(cursor, new.len))
      print('\b'.repeat(new.len - cursor - 1))
      cursor += 1
