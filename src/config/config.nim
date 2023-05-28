import tables
import options
import os
import streams

import buffer/cell
import config/toml
import data/charset
import io/request
import io/urlfilter
import js/javascript
import js/regex
import types/color
import types/cookie
import types/referer
import types/url
import utils/opt
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
    cookie: Option[bool]
    thirdpartycookie: seq[string]
    sharecookiejar: Option[string]
    refererfrom*: Option[bool]
    scripting: Option[bool]
    document_charset: seq[Charset]

  StaticOmniRule = object
    match: string
    subst: string

  SiteConfig* = object
    url*: Option[Regex]
    host*: Option[Regex]
    subst*: (proc(s: URL): Option[URL])
    cookie*: Option[bool]
    thirdpartycookie*: seq[Regex]
    sharecookiejar*: Option[string]
    refererfrom*: Option[bool]
    scripting*: Option[bool]
    document_charset*: seq[Charset]

  OmniRule* = object
    match*: Regex
    subst*: (proc(s: string): Option[string])

  StartConfig = object
    visual_home*: string
    startup_script*: string
    headless*: bool

  CSSConfig = object
    stylesheet*: string

  SearchConfig = object
    wrap*: bool

  EncodingConfig = object
    display_charset*: Option[Charset]
    document_charset*: seq[Charset]

  ExternalConfig = object
    tmpdir*: string
    editor*: string

  NetworkConfig = object
    max_redirect*: int32
    prepend_https*: bool

  DisplayConfig = object
    color_mode*: Option[ColorMode]
    format_mode*: Option[FormatMode]
    no_format_mode*: FormatMode
    emulate_overline*: bool
    alt_screen*: Option[bool]
    highlight_color*: RGBAColor
    double_width_ambiguous*: bool
    minimum_contrast*: int32
    force_clear*: bool

  #TODO: add JS wrappers for objects
  Config* = ref ConfigObj
  ConfigObj* = object
    includes: seq[string]
    start*: StartConfig
    search*: SearchConfig
    css*: CSSConfig
    encoding*: EncodingConfig
    external*: ExternalConfig
    network*: NetworkConfig
    display*: DisplayConfig
    siteconf: seq[StaticSiteConfig]
    omnirule: seq[StaticOmniRule]
    page*: ActionMap
    line*: ActionMap

  BufferConfig* = object
    userstyle*: string
    filter*: URLFilter
    cookiejar*: CookieJar
    headers*: Headers
    refererfrom*: bool
    referrerpolicy*: ReferrerPolicy
    scripting*: bool
    charsets*: seq[Charset]

  ForkServerConfig* = object
    tmpdir*: string
    ambiguous_double*: bool

const DefaultHeaders* = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
}.toTable().newHeaders()[]

func getForkServerConfig*(config: Config): ForkServerConfig =
  return ForkServerConfig(
    tmpdir: config.external.tmpdir,
    ambiguous_double: config.display.double_width_ambiguous
  )

proc getBufferConfig*(config: Config, location: URL, cookiejar: CookieJar = nil,
      headers: Headers = nil, refererfrom = false, scripting = false,
      charsets = config.encoding.document_charset): BufferConfig =
  result = BufferConfig(
    userstyle: config.css.stylesheet,
    filter: newURLFilter(scheme = some(location.scheme), default = true),
    cookiejar: cookiejar,
    headers: headers,
    refererfrom: refererfrom,
    scripting: scripting,
    charsets: charsets
  )
  new(result.headers)
  result.headers[] = DefaultHeaders

proc getSiteConfig*(config: Config, jsctx: JSContext): seq[SiteConfig] =
  for sc in config.siteconf:
    var conf = SiteConfig(
      cookie: sc.cookie,
      scripting: sc.scripting,
      sharecookiejar: sc.sharecookiejar,
      refererfrom: sc.refererfrom,
      document_charset: sc.document_charset
    )
    if sc.url.isSome:
      conf.url = compileRegex(sc.url.get, 0)
    elif sc.host.isSome:
      conf.host = compileRegex(sc.host.get, 0)
    for rule in sc.thirdpartycookie:
      conf.thirdpartycookie.add(compileRegex(rule, 0).get)
    if sc.subst.isSome:
      let fun = jsctx.eval(sc.subst.get, "<siteconf>", JS_EVAL_TYPE_GLOBAL)
      let f = getJSFunction[URL, URL](jsctx, fun)
      conf.subst = f.get
    result.add(conf)

proc getOmniRules*(config: Config, jsctx: JSContext): seq[OmniRule] =
  for rule in config.omnirule:
    let re = compileRegex(rule.match, 0)
    var conf = OmniRule(
      match: re.get
    )
    let fun = jsctx.eval(rule.subst, "<siteconf>", JS_EVAL_TYPE_GLOBAL)
    let f = getJSFunction[string, string](jsctx, fun)
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

proc parseConfig(config: Config, dir: string, stream: Stream, name = "<input>")
proc parseConfig*(config: Config, dir: string, s: string, name = "<input>")

proc loadConfig*(config: Config, s: string) {.jsfunc.} =
  let s = if s.len > 0 and s[0] == '/':
    s
  else:
    getCurrentDir() / s
  if not fileExists(s): return
  config.parseConfig(parentDir(s), newFileStream(s))

proc bindPagerKey*(config: Config, key, action: string) {.jsfunc.} =
  let k = getRealKey(key)
  config.page[k] = action
  var teststr = ""
  for c in k:
    teststr &= c
    if teststr notin config.page:
      config.page[teststr] = "client.feedNext()"

proc bindLineKey*(config: Config, key, action: string) {.jsfunc.} =
  let k = getRealKey(key)
  config.line[k] = action
  var teststr = ""
  for c in k:
    teststr &= c
    if teststr notin config.line:
      config.line[teststr] = "client.feedNext()"

proc parseConfigValue(x: var object, v: TomlValue, k: string)
proc parseConfigValue(x: var bool, v: TomlValue, k: string)
proc parseConfigValue(x: var string, v: TomlValue, k: string)
proc parseConfigValue(x: var seq[object], v: TomlValue, k: string)
proc parseConfigValue[T](x: var seq[T], v: TomlValue, k: string)
proc parseConfigValue(x: var Charset, v: TomlValue, k: string)
proc parseConfigValue(x: var int32, v: TomlValue, k: string)
proc parseConfigValue(x: var int64, v: TomlValue, k: string)
proc parseConfigValue(x: var Option[ColorMode], v: TomlValue, k: string)
proc parseConfigValue(x: var Option[FormatMode], v: TomlValue, k: string)
proc parseConfigValue(x: var FormatMode, v: TomlValue, k: string)
proc parseConfigValue(x: var RGBAColor, v: TomlValue, k: string)
proc parseConfigValue[T](x: var Option[T], v: TomlValue, k: string)
proc parseConfigValue(x: var ActionMap, v: TomlValue, k: string)
proc parseConfigValue(x: var CSSConfig, v: TomlValue, k: string)

proc typeCheck(v: TomlValue, vt: ValueType, k: string) =
  if v.vt != vt:
    raise newException(ValueError, "invalid type for key " & k &
      " (got " & $v.vt & ", expected " & $vt & ")")

proc typeCheck(v: TomlValue, vt: set[ValueType], k: string) =
  if v.vt notin vt:
    raise newException(ValueError, "invalid type for key " & k &
      " (got " & $v.vt & ", expected " & $vt & ")")

proc parseConfigValue(x: var object, v: TomlValue, k: string) =
  typeCheck(v, VALUE_TABLE, k)
  for fk, fv in x.fieldPairs:
    let kebabk = snakeToKebabCase(fk)
    if kebabk in v:
      let kkk = if k != "":
        k & "." & fk
      else:
        fk
      parseConfigValue(fv, v[kebabk], kkk)

proc parseConfigValue(x: var bool, v: TomlValue, k: string) =
  typeCheck(v, VALUE_BOOLEAN, k)
  x = v.b

proc parseConfigValue(x: var string, v: TomlValue, k: string) =
  typeCheck(v, VALUE_STRING, k)
  x = v.s

proc parseConfigValue(x: var seq[object], v: TomlValue, k: string) =
  typeCheck(v, {VALUE_TABLE_ARRAY, VALUE_ARRAY}, k)
  if v.vt == VALUE_ARRAY:
    #TODO if array and size != 0
    # actually, arrays and table arrays should be the same data type
    assert v.a.len == 0
    x.setLen(0)
  else:
    for i in 0 ..< v.ta.len:
      var y: typeof(x[0])
      let tab = TomlValue(vt: VALUE_TABLE, t: v.ta[i])
      parseConfigValue(y, tab, k & "[" & $i & "]")
      x.add(y)

proc parseConfigValue[T](x: var seq[T], v: TomlValue, k: string) =
  typeCheck(v, {VALUE_STRING, VALUE_ARRAY}, k)
  if v.vt != VALUE_ARRAY:
    var y: T
    parseConfigValue(y, v, k)
    x.add(y)
  else:
    for i in 0 ..< v.a.len:
      var y: T
      parseConfigValue(y, v.a[i], k & "[" & $i & "]")
      x.add(y)

proc parseConfigValue(x: var Charset, v: TomlValue, k: string) =
  typeCheck(v, VALUE_STRING, k)
  x = getCharset(v.s)
  if x == CHARSET_UNKNOWN:
    raise newException(ValueError, "unknown charset '" & v.s & "' for key " &
      k)

proc parseConfigValue(x: var int32, v: TomlValue, k: string) =
  typeCheck(v, VALUE_INTEGER, k)
  x = int32(v.i)

proc parseConfigValue(x: var int64, v: TomlValue, k: string) =
  typeCheck(v, VALUE_INTEGER, k)
  x = v.i

proc parseConfigValue(x: var Option[ColorMode], v: TomlValue, k: string) =
  typeCheck(v, VALUE_STRING, k)
  case v.s
  of "auto": x = none(ColorMode)
  of "monochrome": x = some(MONOCHROME)
  of "ansi": x = some(ANSI)
  of "8bit": x = some(EIGHT_BIT)
  of "24bit": x = some(TRUE_COLOR)
  else:
    raise newException(ValueError, "unknown color mode '" & v.s &
      "' for key " & k)

proc parseConfigValue(x: var Option[FormatMode], v: TomlValue, k: string) =
  typeCheck(v, {VALUE_STRING, VALUE_ARRAY}, k)
  if v.vt == VALUE_STRING and v.s == "auto":
    x = none(FormatMode)
  else:
    var y: FormatMode
    parseConfigValue(y, v, k)
    x = some(y)

proc parseConfigValue(x: var FormatMode, v: TomlValue, k: string) =
  typeCheck(v, VALUE_ARRAY, k)
  for i in 0 ..< v.a.len:
    let s = v.a[i].s
    let kk = k & "[" & $i & "]"
    case s
    of "bold": x.incl(FLAG_BOLD)
    of "italic": x.incl(FLAG_ITALIC)
    of "underline": x.incl(FLAG_UNDERLINE)
    of "reverse": x.incl(FLAG_REVERSE)
    of "strike": x.incl(FLAG_STRIKE)
    of "overline": x.incl(FLAG_OVERLINE)
    of "blink": x.incl(FLAG_BLINK)
    else:
      raise newException(ValueError, "unknown format mode '" & s &
        "' for key " & kk)

proc parseConfigValue(x: var RGBAColor, v: TomlValue, k: string) =
  typeCheck(v, VALUE_STRING, k)
  let c = parseRGBAColor(v.s)
  if c.isNone:
      raise newException(ValueError, "invalid color '" & v.s &
        "' for key " & k)
  x = c.get

proc parseConfigValue[T](x: var Option[T], v: TomlValue, k: string) =
  if v.vt == VALUE_STRING and v.s == "auto":
    x = none(T)
  else:
    var y: T
    parseConfigValue(y, v, k)
    x = some(y)

proc parseConfigValue(x: var ActionMap, v: TomlValue, k: string) =
  typeCheck(v, VALUE_TABLE, k)
  for kk, vv in v:
    typeCheck(vv, VALUE_STRING, k & "[" & kk & "]")
    x[getRealKey(kk)] = vv.s

var gdir {.compileTime.}: string
proc parseConfigValue(x: var CSSConfig, v: TomlValue, k: string) =
  typeCheck(v, VALUE_TABLE, k)
  let dir = gdir
  for kk, vv in v:
    let kkk = if k != "":
      k & "." & kk
    else:
      kk
    case kk
    of "include":
      typeCheck(vv, {VALUE_STRING, VALUE_ARRAY}, kkk)
      case vv.vt
      of VALUE_STRING:
        x.stylesheet &= readUserStylesheet(dir, vv.s)
      of VALUE_ARRAY:
        for child in vv.a:
          x.stylesheet &= readUserStylesheet(dir, vv.s)
      else: discard
    of "inline":
      typeCheck(vv, VALUE_STRING, kkk)
      x.stylesheet &= vv.s

proc parseConfig(config: Config, dir: string, t: TomlValue) =
  gdir = dir
  parseConfigValue(config[], t, "")
  while config.includes.len > 0:
    #TODO: warn about recursive includes
    let includes = config.includes
    config.includes.setLen(0)
    for s in includes:
      when nimvm:
        config.parseConfig(dir, staticRead(dir / s))
      else:
        config.parseConfig(dir, newFileStream(dir / s))
  #TODO: for omnirule/siteconf, check if substitution rules are specified?

proc parseConfig(config: Config, dir: string, stream: Stream, name = "<input>") =
  let toml = parseToml(stream, dir / name)
  if toml.isOk:
    config.parseConfig(dir, toml.get)
  else:
    eprint("Fatal error: Failed to parse config\n")
    eprint(toml.error & "\n")
    quit(1)

proc parseConfig*(config: Config, dir: string, s: string, name = "<input>") =
  config.parseConfig(dir, newStringStream(s), name)

proc staticReadConfig(): ConfigObj =
  var config = new(Config)
  config.parseConfig("res", staticRead"res/config.toml", "config.toml")
  return config[]

const defaultConfig = staticReadConfig()

proc readConfig(config: Config, dir: string) =
  let fs = newFileStream(dir / "config.toml")
  if fs != nil:
    config.parseConfig(dir, fs)

proc getNormalAction*(config: Config, s: string): string =
  if config.page.hasKey(s):
    return config.page[s]
  return ""

proc getLinedAction*(config: Config, s: string): string =
  if config.line.hasKey(s):
    return config.line[s]
  return ""

proc readConfig*(): Config =
  new(result)
  result[] = defaultConfig
  when defined(debug):
    result.readConfig(getCurrentDir() / "res")
  result.readConfig(getConfigDir() / "chawan")

proc addConfigModule*(ctx: JSContext) =
  ctx.registerType(Config)
