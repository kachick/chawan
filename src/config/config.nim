import tables
import options
import os
import streams

import buffer/cell
import config/toml
import io/request
import io/urlfilter
import js/javascript
import js/regex
import types/color
import types/cookie
import types/url
import utils/twtstr

type
  ColorMode* = enum
    MONOCHROME, ANSI, EIGHT_BIT, TRUE_COLOR

  FormatMode* = set[FormatFlags]

  ActionMap = Table[string, string]

  StaticSiteConfig = object
    url: Option[string]
    host: Option[string]
    subst: Option[string]
    cookie: bool

  StaticOmniRule = object
    match: string
    subst: string

  SiteConfig* = object
    url*: Option[Regex]
    host*: Option[Regex]
    subst*: (proc(s: URL): Option[URL])
    cookie*: bool

  OmniRule* = object
    match*: Regex
    subst*: (proc(s: string): Option[string])

  Config* = ref ConfigObj
  ConfigObj* = object
    maxredirect*: int
    prependhttps*: bool
    termreload*: bool
    nmap*: ActionMap
    lemap*: ActionMap
    stylesheet*: string
    startup*: string
    ambiguous_double*: bool
    hlcolor*: RGBAColor
    headless*: bool
    colormode*: Option[ColorMode]
    formatmode*: Option[FormatMode]
    noformatmode*: FormatMode
    altscreen*: Option[bool]
    mincontrast*: int
    editor*: string
    tmpdir*: string
    siteconf: seq[StaticSiteConfig]
    omnirules: seq[StaticOmniRule]
    forceclear*: bool
    emulateoverline*: bool
    visualhome*: string

  BufferConfig* = object
    userstyle*: string
    filter*: URLFilter
    cookiejar*: CookieJar
    headers*: HeaderList

  ForkServerConfig* = object
    tmpdir*: string
    ambiguous_double*: bool

func getForkServerConfig*(config: Config): ForkServerConfig =
  return ForkServerConfig(
    tmpdir: config.tmpdir,
    ambiguous_double: config.ambiguous_double
  )

func getBufferConfig*(config: Config, location: URL, cookiejar: CookieJar): BufferConfig =
  result.userstyle = config.stylesheet
  result.filter = newURLFilter(scheme = some(location.scheme))
  result.cookiejar = cookiejar

proc getSiteConfig*(config: Config, jsctx: JSContext): seq[SiteConfig] =
  for sc in config.siteconf:
    var conf = SiteConfig(
      cookie: sc.cookie,
    )
    if sc.url.isSome:
      conf.url = compileRegex(sc.url.get, 0)
    elif sc.host.isSome:
      conf.host = compileRegex(sc.host.get, 0)
    if sc.subst.isSome:
      let fun = jsctx.eval(sc.subst.get, "<siteconf>", JS_EVAL_TYPE_GLOBAL)
      let f = getJSFunction[URL, URL](jsctx, fun.val)
      conf.subst = f.get
    result.add(conf)

proc getOmniRules*(config: Config, jsctx: JSContext): seq[OmniRule] =
  for rule in config.omnirules:
    let re = compileRegex(rule.match, 0)
    var conf = OmniRule(
      match: re.get
    )
    let fun = jsctx.eval(rule.subst, "<siteconf>", JS_EVAL_TYPE_GLOBAL)
    let f = getJSFunction[string, string](jsctx, fun.val)
    conf.subst = f.get
    result.add(conf)

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

proc parseConfig(config: Config, dir: string, stream: Stream)
proc parseConfig*(config: Config, dir: string, s: string)

proc loadConfig*(config: Config, s: string) {.jsfunc.} =
  let s = if s.len > 0 and s[0] == '/':
    s
  else:
    getCurrentDir() / s
  if not fileExists(s): return
  config.parseConfig(parentDir(s), newFileStream(s))

proc bindPagerKey*(config: Config, key, action: string) {.jsfunc.} =
  let k = getRealKey(key)
  config.nmap[k] = action
  var teststr = ""
  for c in k:
    teststr &= c
    if teststr notin config.nmap:
      config.nmap[teststr] = "client.feedNext()"

proc bindLineKey*(config: Config, key, action: string) {.jsfunc.} =
  let k = getRealKey(key)
  config.lemap[k] = action
  var teststr = ""
  for c in k:
    teststr &= c
    if teststr notin config.nmap:
      config.lemap[teststr] = "client.feedNext()"

proc parseConfig(config: Config, dir: string, t: TomlValue) =
  for k, v in t:
    case k
    of "include":
      if v.vt == VALUE_STRING:
        when nimvm:
          config.loadConfig(v.s)
        else:
          config.loadConfig(v.s)
      elif t.vt == VALUE_ARRAY:
        for v in t.a:
          when nimvm:
            config.parseConfig(parentDir(v.s), staticRead(v.s))
          else:
            config.parseConfig(parentDir(v.s), newFileStream(v.s))
    of "start":
      for k, v in v:
        case k
        of "visual-home":
          config.visualhome = v.s
        of "run-script":
          config.startup = v.s
        of "headless":
          config.headless = v.b
    of "network":
      for k, v in v:
        case k
        of "max-redirects":
          config.maxredirect = int(v.i)
        of "prepend-https":
          config.prependhttps = v.b
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
      template get_format_mode(v: TomlValue): FormatMode =
        var mode: FormatMode
        for vv in v.a:
          case vv.s
          of "bold": mode.incl(FLAG_BOLD)
          of "italic": mode.incl(FLAG_ITALIC)
          of "underline": mode.incl(FLAG_UNDERLINE)
          of "reverse": mode.incl(FLAG_REVERSE)
          of "strike": mode.incl(FLAG_STRIKE)
          of "overline": mode.incl(FLAG_OVERLINE)
          of "blink": mode.incl(FLAG_BLINK)
        mode
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
            config.formatmode = some(get_format_mode v)
        of "no-format-mode":
          config.noformatmode = get_format_mode v
        of "highlight-color":
          config.hlcolor = parseRGBAColor(v.s).get
        of "double-width-ambiguous":
          config.ambiguous_double = v.b
        of "minimum-contrast":
          config.mincontrast = int(v.i)
        of "force-clear": config.forceclear = v.b
        of "emulate-overline": config.emulateoverline = v.b
    of "external":
      for k, v in v:
        case k
        of "editor": config.editor = v.s
        of "tmpdir": config.tmpdir = v.s
    of "siteconf":
      for v in v:
        var conf = StaticSiteConfig()
        for k, v in v:
          case k
          of "url": conf.url = some(v.s)
          of "host": conf.host = some(v.s)
          of "rewrite-url": conf.subst = some(v.s)
          of "cookie": conf.cookie = v.b
        assert conf.url.isSome != conf.host.isSome
        config.siteconf.add(conf)
    of "omnirule":
      if v.vt == VALUE_ARRAY and v.a.len == 0:
        config.omnirules.setLen(0)
      else:
        for v in v:
          var rule = StaticOmniRule()
          for k, v in v:
            case k
            of "match": rule.match = v.s
            of "substitute": rule.subst = v.s
          if rule.match != "":
            config.omnirules.add(rule)

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

proc addConfigModule*(ctx: JSContext) =
  ctx.registerType(Config)
