import tables
import os
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
    ACTION_RELOAD, ACTION_RESHAPE, ACTION_REDRAW, ACTION_TOGGLE_SOURCE,
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
  StaticConfig = object
    nmap: ActionMap
    lemap: ActionMap
    cmap: Table[string, string]

  Config = object
    nmap*: ActionMap
    lemap*: ActionMap
    cmap*: RadixNode[string]

func getConfig(s: StaticConfig): Config =
  return Config(nmap: s.nmap, lemap: s.lemap, cmap: s.cmap.toRadixTree())

func getRealKey(key: string): string =
  var realk: string
  var control = 0
  var meta = 0
  var skip = false
  for c in key:
    if c == '\\':
      skip = true
    elif skip:
      realk &= c
      skip = false
    elif c == 'M' and meta == 0:
      inc meta
    elif c == 'C' and control == 0:
      inc control
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
      meta = 0
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

proc parseConfigLine[T](line: string, config: var T) =
  if line.len == 0 or line[0] == '#':
    return
  let cmd = line.split(' ')
  if cmd.len == 3:
    if cmd[0] == "nmap":
      config.nmap[getRealKey(cmd[1])] = parseEnum[TwtAction]("ACTION_" & cmd[2])
    elif cmd[0] == "lemap":
      config.lemap[getRealKey(cmd[1])] = parseEnum[TwtAction]("ACTION_" & cmd[2])
    elif cmd[0] == "comp":
      config.cmap[getRealKey(cmd[1])] = cmd[2]

proc staticReadConfig(): StaticConfig =
  let default = staticRead"res/config"
  for line in default.split('\n'):
    parseConfigLine(line, result)

  result.nmap = constructActionTable(result.nmap)
  result.lemap = constructActionTable(result.lemap)

const defaultConfig = staticReadConfig()
var gconfig* = getConfig(defaultConfig)

proc readConfig(filename: string) =
  var f: File
  let status = f.open(filename, fmRead)
  var nmap: ActionMap
  var lemap: ActionMap
  var compose: Table[string, string]
  if status:
    var line: TaintedString
    while f.readLine(line):
      parseConfigLine(line, gconfig)

    gconfig.nmap = constructActionTable(nmap)
    gconfig.lemap = constructActionTable(lemap)
    gconfig.cmap = compose.toRadixTree()

proc readConfig*() =
  when defined(debug):
    readConfig("res" / "config")
  readConfig(getConfigDir() / "twt" / "config")

proc getNormalAction*(s: string): TwtAction =
  if gconfig.nmap.hasKey(s):
    return gconfig.nmap[s]
  return NO_ACTION

proc getLinedAction*(s: string): TwtAction =
  if gconfig.lemap.hasKey(s):
    return gconfig.lemap[s]
  return NO_ACTION

