import tables
import strutils

import utils/twtstr
import utils/radixtree

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
    ACTION_PAGE_DOWN, ACTION_PAGE_UP, ACTION_PAGE_LEFT, ACTION_PAGE_RIGHT,
    ACTION_HALF_PAGE_DOWN, ACTION_HALF_PAGE_UP,
    ACTION_SCROLL_DOWN, ACTION_SCROLL_UP, ACTION_SCROLL_LEFT, ACTION_SCROLL_RIGHT,
    ACTION_CLICK,
    ACTION_CHANGE_LOCATION,
    ACTION_RELOAD, ACTION_RESHAPE, ACTION_REDRAW,
    ACTION_CURSOR_FIRST_LINE, ACTION_CURSOR_LAST_LINE,
    ACTION_CURSOR_TOP, ACTION_CURSOR_MIDDLE, ACTION_CURSOR_BOTTOM,
    ACTION_CENTER_LINE, ACTION_LINE_INFO,
    ACTION_LINED_SUBMIT, ACTION_LINED_CANCEL,
    ACTION_LINED_BACKSPACE, ACTION_LINED_DELETE,
    ACTION_LINED_CLEAR, ACTION_LINED_KILL, ACTION_LINED_KILL_WORD,
    ACTION_LINED_BACK, ACTION_LINED_FORWARD,
    ACTION_LINED_PREV_WORD, ACTION_LINED_NEXT_WORD,
    ACTION_LINED_BEGIN, ACTION_LINED_END,
    ACTION_LINED_COMPOSE_TOGGLE, ACTION_LINED_ESC

  ActionMap = Table[string, TwtAction]
  ComposeMap = RadixNode[string]

var normalActionRemap*: ActionMap
var linedActionRemap*: ActionMap
var composeRemap*: ComposeMap

func getRealKey(key: string): string =
  var realk: string
  var currchar: char
  var control = 0
  var meta = 0
  var skip = false
  for c in key:
    if c == '\\':
      skip = true
    elif skip:
      realk &= c
      skip = false
    elif c == 'M':
      inc meta
      currchar = c
    elif c == 'C':
      inc control
      currchar = c
    elif c == '-' and control == 1:
      inc control
    elif c == '-' and meta == 1:
      inc meta
    elif meta == 1:
      realk &= 'M' & c
      meta = 0
    elif meta == 2:
      realk &= '\e'
      realk &= c
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
  if meta == 1:
    realk &= 'M'
  return realk

func constructActionTable*(origTable: ActionMap): ActionMap =
  var newTable: ActionMap
  var strs: seq[string]
  for k in origTable.keys:
    let realk = getRealKey(k)
    var teststr = ""
    for c in realk:
      teststr &= c
      strs.add(teststr)

  for k, v in origTable:
    let realk = getRealKey(k)
    var teststr = ""
    for c in realk:
      teststr &= c
      if strs.contains(teststr):
        newTable[teststr] = ACTION_FEED_NEXT
    newTable[realk] = v
  return newTable

proc parseConfigLine(line: string, nmap: var ActionMap, lemap: var ActionMap,
                     compose: var Table[string, string]) =
  if line.len == 0 or line[0] == '#':
    return
  let cmd = line.split(' ')
  if cmd.len == 3:
    if cmd[0] == "nmap":
      nmap[getRealKey(cmd[1])] = parseEnum[TwtAction]("ACTION_" & cmd[2])
    elif cmd[0] == "lemap":
      lemap[getRealKey(cmd[1])] = parseEnum[TwtAction]("ACTION_" & cmd[2])
    elif cmd[0] == "comp":
      compose[getRealKey(cmd[1])] = cmd[2]

proc staticReadKeymap(): (ActionMap, ActionMap, Table[string, string]) =
  let config = staticRead"../res/config"
  var nmap: ActionMap
  var lemap: ActionMap
  var compose: Table[string, string]
  for line in config.split('\n'):
    parseConfigLine(line, nmap, lemap, compose)

  nmap = constructActionTable(nmap)
  lemap = constructActionTable(lemap)
  return (nmap, lemap, compose)

const (normalActionMap, linedActionMap, composeMap) = staticReadKeymap()
normalActionRemap = normalActionMap
linedActionRemap = linedActionMap
composeRemap = composeMap.toRadixTree()

proc readConfig*(filename: string): bool =
  var f: File
  let status = f.open(filename, fmRead)
  var nmap: ActionMap
  var lemap: ActionMap
  var compose: Table[string, string]
  if status:
    var line: TaintedString
    while f.readLine(line):
      parseConfigLine(line, nmap, lemap, compose)

    normalActionRemap = constructActionTable(nmap)
    linedActionRemap = constructActionTable(lemap)
    composeRemap = compose.toRadixTree()
    return true
  else:
    return false
