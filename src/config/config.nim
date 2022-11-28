import tables
import options
import os
import streams

import buffer/cell
import config/toml
import types/color
import utils/twtstr

type
  ColorMode* = enum
    MONOCHROME, ANSI, EIGHT_BIT, TRUE_COLOR

  FormatMode* = set[FormatFlags]

  ActionMap = Table[string, string]

  Config* = ref ConfigObj
  ConfigObj* = object
    nmap*: ActionMap
    lemap*: ActionMap
    stylesheet*: string
    startup*: string
    ambiguous_double*: bool
    hlcolor*: RGBAColor
    headless*: bool
    colormode*: Option[ColorMode]
    formatmode*: Option[FormatMode]
    altscreen*: Option[bool]
    mincontrast*: float
    editor*: string
    tmpdir*: string

  BufferConfig* = object
    userstyle*: string

  ForkServerConfig* = object
    tmpdir*: string
    ambiguous_double*: bool

func getForkServerConfig*(config: Config): ForkServerConfig =
  return ForkServerConfig(
    tmpdir: config.tmpdir,
    ambiguous_double: config.ambiguous_double
  )

func getBufferConfig*(config: Config): BufferConfig =
  result.userstyle = config.stylesheet

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
  for k, v in t:
    case k
    of "startup":
      config.startup = v.s
    of "headless":
      config.headless = v.b
    of "page":
      for k, v in v:
        config.nmap[getRealKey(k)] = v.s
    of "line":
      for k, v in v:
        config.lemap[getRealKey(k)] = v.s
    of "css":
      for k, v in v:
        case k
        of "include":
          case v.vt
          of VALUE_STRING:
            config.stylesheet &= readUserStylesheet(dir, v.s)
          of VALUE_ARRAY:
            for child in v.a:
              config.stylesheet &= readUserStylesheet(dir, v.s)
          else: discard
        of "inline":
          config.stylesheet &= v.s
    of "display":
      for k, v in v:
        case k
        of "alt-screen":
          if v.vt == VALUE_BOOLEAN:
            config.altscreen = some(v.b)
          elif v.vt == VALUE_STRING and v.s == "auto":
            config.altscreen = none(bool)
        of "color-mode":
          case v.s
          of "auto": config.colormode = none(ColorMode)
          of "monochrome": config.colormode = some(MONOCHROME)
          of "ansi": config.colormode = some(ANSI)
          of "8bit": config.colormode = some(EIGHT_BIT)
          of "24bit": config.colormode = some(TRUE_COLOR)
        of "format-mode":
          if v.vt == VALUE_STRING and v.s == "auto":
            config.formatmode = none(FormatMode)
          elif v.vt == VALUE_ARRAY:
            var mode: FormatMode
            for v in v.a:
              case v.s
              of "bold": mode.incl(FLAG_BOLD)
              of "italic": mode.incl(FLAG_ITALIC)
              of "underline": mode.incl(FLAG_UNDERLINE)
              of "reverse": mode.incl(FLAG_REVERSE)
              of "strike": mode.incl(FLAG_STRIKE)
              of "overline": mode.incl(FLAG_OVERLINE)
              of "blink": mode.incl(FLAG_BLINK)
            config.formatmode = some(mode)
        of "highlight-color":
          config.hlcolor = parseRGBAColor(v.s).get
        of "double-width-ambiguous":
          config.ambiguous_double = v.b
        of "minimum-contrast":
          if v.vt == VALUE_INTEGER:
            config.mincontrast = float(v.i)
          else:
            config.mincontrast = float(v.f)
    of "external":
      for k, v in v:
        case k
        of "editor": config.editor = v.s
        of "tmpdir": config.tmpdir = v.s

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
