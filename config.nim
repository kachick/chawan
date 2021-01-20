import tables
import strutils
import macros

type
  TwtAction* =
    enum
    NO_ACTION,
    ACTION_FEED_NEXT,
    ACTION_QUIT,
    ACTION_CURSOR_UP, ACTION_CURSOR_DOWN, ACTION_CURSOR_LEFT, ACTION_CURSOR_RIGHT,
    ACTION_CURSOR_LINEEND, ACTION_CURSOR_LINEBEGIN,
    ACTION_CURSOR_NEXT_WORD, ACTION_CURSOR_PREV_WORD,
    ACTION_CURSOR_NEXT_NODE, ACTION_CURSOR_PREV_NODE,
    ACTION_CURSOR_NEXT_LINK, ACTION_CURSOR_PREV_LINK,
    ACTION_PAGE_DOWN, ACTION_PAGE_UP,
    ACTION_HALF_PAGE_DOWN, ACTION_HALF_PAGE_UP,
    ACTION_SCROLL_DOWN, ACTION_SCROLL_UP,
    ACTION_CLICK,
    ACTION_CHANGE_LOCATION,
    ACTION_RELOAD, ACTION_RESHAPE, ACTION_REDRAW,
    ACTION_CURSOR_FIRST_LINE, ACTION_CURSOR_LAST_LINE,
    ACTION_CURSOR_TOP, ACTION_CURSOR_MIDDLE, ACTION_CURSOR_BOTTOM,
    ACTION_LINED_SUBMIT, ACTION_LINED_CANCEL,
    ACTION_LINED_BACKSPACE, ACTION_LINED_CLEAR, ACTION_LINED_KILL, ACTION_LINED_KILL_WORD,
    ACTION_LINED_BACK, ACTION_LINED_FORWARD,
    ACTION_LINED_PREV_WORD, ACTION_LINED_NEXT_WORD,
    ACTION_LINED_ESC

var normalActionRemap*: Table[string, TwtAction]
var linedActionRemap*: Table[string, TwtAction]

func getControlChar(c: char): char =
  if int(c) >= int('a'):
    return char(int(c) - int('a') + 1)
  elif c == '?':
    return char(127)
  assert(false)

proc getRealKey(key: string): string =
  var realk: string
  var currchar: char
  var control = 0
  var skip = false
  for c in key:
    if c == '\\':
      skip = true
    elif skip:
      if c == 'e':
        realk &= '\e'
      else:
        realk &= c
      skip = false
    elif c == 'C':
      control += 1
      currchar = c
    elif c == '-' and control == 1:
      control += 1
    elif control == 1:
      realk &= 'C' & c
      control = 0
    elif control == 2:
      realk &= getControlChar(c)
      control = 0
    else:
      realk &= c
  if control == 1:
    realk &= 'C'
  return realk

proc constructActionTable*(origTable: var Table[string, TwtAction]): Table[string, TwtAction] =
  var newTable: Table[string, TwtAction]
  var strs = newSeq[string](0)
  for k in origTable.keys:
    let realk = getRealKey(k)
    var teststr = ""
    for c in realk:
      teststr &= c
      strs.add(teststr)

  for k, v in origTable.mpairs:
    let realk = getRealKey(k)
    var teststr = ""
    for c in realk:
      teststr &= c
      if strs.contains(teststr):
        newTable[teststr] = ACTION_FEED_NEXT
    newTable[realk] = v
  return newTable

var keymapStr*: string
macro staticReadKeymap(): untyped =
  var keymap = staticRead"keymap"

  let keymapLit = newLit(keymap)
  result = quote do:
    keymapStr = `keymapLit`

staticReadKeymap()

proc readKeymap*(filename: string): bool =
  var f: File
  let status = f.open(filename, fmRead)
  var normalActionMap: Table[string, TwtAction]
  var linedActionMap: Table[string, TwtAction]
  if status:
    var line: TaintedString
    while f.readLine(line):
      if line.string.len == 0 or line.string[0] == '#':
        continue
      let cmd = line.split(' ')
      if cmd.len == 3:
        if cmd[0] == "nmap":
          normalActionMap[getRealKey(cmd[1])] = parseEnum[TwtAction](cmd[2])
        elif cmd[0] == "lemap":
          linedActionMap[getRealKey(cmd[1])] = parseEnum[TwtAction](cmd[2])

    normalActionRemap = constructActionTable(normalActionMap)
    linedActionRemap = constructActionTable(linedActionMap)
    return true
  else:
    return false

proc parseKeymap*(keymap: string) =
  var normalActionMap: Table[string, TwtAction]
  var linedActionMap: Table[string, TwtAction]
  for line in keymap.split('\n'):
    if line.len == 0 or line[0] == '#':
      continue
    let cmd = line.split(' ')
    if cmd.len == 3:
      if cmd[0] == "nmap":
        normalActionMap[getRealKey(cmd[1])] = parseEnum[TwtAction](cmd[2])
      elif cmd[0] == "lemap":
        linedActionMap[getRealKey(cmd[1])] = parseEnum[TwtAction](cmd[2])

  normalActionRemap = constructActionTable(normalActionMap)
  linedActionRemap = constructActionTable(linedActionMap)
