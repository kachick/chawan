import tables
import os
import streams

import config/toml
import types/color
import utils/twtstr

type
  ActionMap = Table[string, string]
  Config* = ref ConfigObj
  ConfigObj = object
    nmap*: ActionMap
    lemap*: ActionMap
    stylesheet*: string
    startup*: string
    ambiguous_double*: bool
    hlcolor*: CellColor

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
    elif control == 1:
      realk &= 'C' & c
      control = 0
    else:
      if meta == 2:
        realk &= '\e'
        meta = 0
      if control == 2:
        realk &= getControlChar(c)
        control = 0
      else:
        realk &= c
  if control == 1:
    realk &= 'C'
  if meta == 1:
    realk &= 'M'
  return realk

func constructActionTable*(origTable: Table[string, string]): Table[string, string] =
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
        result[teststr] = "client.feedNext()"
    result[realk] = v

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

proc parseConfig(config: Config, dir: string, t: TomlValue) =
  if "general" in t:
    let general = t["general"]
    if "double-width-ambiguous" in general:
      config.ambiguous_double = general["double-width-ambiguous"].b
  if "page" in t:
    for k, v in t["page"].pairs:
      config.nmap[getRealKey(k)] = v.s
  if "line" in t:
    for k, v in t["line"].pairs:
      config.lemap[getRealKey(k)] = v.s
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
  if "display" in t:
    let display = t["display"]
    if "highlight-color" in display:
      case display["highlight-color"].s
      of "black": config.hlcolor = CellColor(rgb: false, color: 40u8)
      of "red": config.hlcolor = CellColor(rgb: false, color: 41u8)
      of "green": config.hlcolor = CellColor(rgb: false, color: 42u8)
      of "yellow": config.hlcolor = CellColor(rgb: false, color: 43u8)
      of "blue": config.hlcolor = CellColor(rgb: false, color: 44u8)
      of "magenta": config.hlcolor = CellColor(rgb: false, color: 45u8)
      of "cyan": config.hlcolor = CellColor(rgb: false, color: 46u8)
      of "white": config.hlcolor = CellColor(rgb: false, color: 47u8)
      of "terminal": config.hlcolor = CellColor(rgb: false, color: 0)

proc parseConfig(config: Config, dir: string, stream: Stream) =
  config.parseConfig(dir, parseToml(stream))

proc parseConfig*(config: Config, dir: string, s: string) =
  config.parseConfig(dir, newStringStream(s))

proc staticReadConfig(): ConfigObj =
  var config = new(Config)
  config.parseConfig("res", staticRead"res/config.toml")
  return config[]

const defaultConfig = staticReadConfig()

proc readConfig(config: Config, dir: string) =
  let fs = newFileStream(dir / "config.toml")
  if fs != nil:
    config.parseConfig(dir, fs)

proc getNormalAction*(config: Config, s: string): string =
  if config.nmap.hasKey(s):
    return config.nmap[s]
  return ""

proc getLinedAction*(config: Config, s: string): string =
  if config.lemap.hasKey(s):
    return config.lemap[s]
  return ""

proc readConfig*(): Config =
  new(result)
  result[] = defaultConfig
  when defined(debug):
    result.readConfig(getCurrentDir() / "res")
  result.readConfig(getConfigDir() / "chawan")
