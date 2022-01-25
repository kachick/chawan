import tables
import os
import strutils
import streams

import config/toml
import utils/twtstr

type
  TwtAction* =
    enum
    NO_ACTION,
    ACTION_FEED_NEXT,
    ACTION_QUIT,
    ACTION_CURSOR_UP, ACTION_CURSOR_DOWN, ACTION_CURSOR_LEFT, ACTION_CURSOR_RIGHT,
    ACTION_CURSOR_LINEEND, ACTION_CURSOR_LINEBEGIN,
    ACTION_CURSOR_NEXT_WORD, ACTION_CURSOR_PREV_WORD,
    ACTION_CURSOR_NEXT_LINK, ACTION_CURSOR_PREV_LINK,
    ACTION_PAGE_DOWN, ACTION_PAGE_UP, ACTION_PAGE_LEFT, ACTION_PAGE_RIGHT,
    ACTION_HALF_PAGE_DOWN, ACTION_HALF_PAGE_UP,
    ACTION_SCROLL_DOWN, ACTION_SCROLL_UP, ACTION_SCROLL_LEFT, ACTION_SCROLL_RIGHT,
    ACTION_CLICK,
    ACTION_CHANGE_LOCATION,
    ACTION_PREV_BUFFER, ACTION_NEXT_BUFFER, ACTION_DISCARD_BUFFER,
    ACTION_RELOAD, ACTION_RESHAPE, ACTION_REDRAW, ACTION_TOGGLE_SOURCE,
    ACTION_CURSOR_FIRST_LINE, ACTION_CURSOR_LAST_LINE,
    ACTION_CURSOR_TOP, ACTION_CURSOR_MIDDLE, ACTION_CURSOR_BOTTOM,
    ACTION_CURSOR_RIGHT_EDGE, ACTION_CURSOR_VERT_MIDDLE, ACTION_CURSOR_LEFT_EDGE,
    ACTION_CENTER_LINE, ACTION_LINE_INFO,
    ACTION_LINED_SUBMIT, ACTION_LINED_CANCEL,
    ACTION_LINED_BACKSPACE, ACTION_LINED_DELETE,
    ACTION_LINED_CLEAR, ACTION_LINED_KILL, ACTION_LINED_KILL_WORD,
    ACTION_LINED_BACK, ACTION_LINED_FORWARD,
    ACTION_LINED_PREV_WORD, ACTION_LINED_NEXT_WORD,
    ACTION_LINED_BEGIN, ACTION_LINED_END,
    ACTION_LINED_ESC

  ActionMap = Table[string, TwtAction]
  Config = object
    nmap*: ActionMap
    lemap*: ActionMap
    stylesheet*: string
    ambiguous_double*: bool

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

func getAction(s: string): TwtAction =
  if s == "NULL":
    return NO_ACTION
  return parseEnum[TwtAction]("ACTION_" & s)

func getLineAction(s: string): TwtAction =
  if s == "NULL":
    return NO_ACTION
  return parseEnum[TwtAction]("ACTION_LINED_" & s)

proc readUserStylesheet(dir, file: string): string =
  if file.len == 0:
    return ""
  if file[0] == '~' or file[0] == '/':
    var f: File
    if f.open(expandPath(file)):
      result = f.readAll()
      f.close()
  else:
    var f: File
    if f.open(dir / file):
      result = f.readAll()
      f.close()

proc parseConfig(config: var Config, dir: string, t: TomlValue) =
  if "general" in t:
    let general = t["general"]
    if "double-width-ambiguous" in general:
      config.ambiguous_double = general["double-width-ambiguous"].b
  if "page" in t:
    for k, v in t["page"].pairs:
      config.nmap[getRealKey(k)] = getAction(v.s)
  if "line" in t:
    for k, v in t["line"].pairs:
      config.lemap[getRealKey(k)] = getLineAction(v.s)
  if "css" in t:
    let css = t["css"]
    if "include" in css:
      let val = css["include"]
      case val.vt
      of VALUE_STRING:
        config.stylesheet &= readUserStylesheet(dir, val.s)
      of VALUE_ARRAY:
        for child in val.a:
          config.stylesheet &= readUserStylesheet(dir, child.s)
      else: discard
    if "inline" in css:
      config.stylesheet &= css["inline"].s

proc parseConfig(config: var Config, dir: string, stream: Stream) =
  config.parseConfig(dir, parseToml(stream))

proc parseConfig*(config: var Config, dir: string, s: string) =
  config.parseConfig(dir, newStringStream(s))

proc staticReadConfig(): Config =
  result.parseConfig("res", staticRead"res/config.toml")

const defaultConfig = staticReadConfig()
var gconfig* = defaultConfig

proc readConfig(dir: string) =
  let fs = newFileStream(dir / "config.toml")
  if fs != nil:
    gconfig.parseConfig(dir, fs)

proc getNormalAction*(s: string): TwtAction =
  if gconfig.nmap.hasKey(s):
    return gconfig.nmap[s]
  return NO_ACTION

proc getLinedAction*(s: string): TwtAction =
  if gconfig.lemap.hasKey(s):
    return gconfig.lemap[s]
  return NO_ACTION

proc readConfig*() =
  when defined(debug):
    readConfig(getCurrentDir() / "res")
  readConfig(getConfigDir() / "chawan")
