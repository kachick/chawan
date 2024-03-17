import std/options
import std/os
import std/streams
import std/tables

import config/chapath
import config/mailcap
import config/mimetypes
import config/toml
import js/error
import js/fromjs
import js/javascript
import js/propertyenumlist
import js/regex
import loader/headers
import types/cell
import types/color
import types/cookie
import types/opt
import types/urimethodmap
import types/url
import utils/mimeguess
import utils/twtstr

import chagashi/charset

type
  ColorMode* = enum
    MONOCHROME, ANSI, EIGHT_BIT, TRUE_COLOR

  FormatMode* = set[FormatFlags]

  ChaPathResolved* = distinct string

  ActionMap = object
    t: Table[string, string]

  SiteConfig* = object
    url*: Opt[Regex]
    host*: Opt[Regex]
    rewrite_url*: (proc(s: URL): JSResult[URL])
    cookie*: Opt[bool]
    third_party_cookie*: seq[Regex]
    share_cookie_jar*: Opt[string]
    referer_from*: Opt[bool]
    scripting*: Opt[bool]
    document_charset*: seq[Charset]
    images*: Opt[bool]
    stylesheet*: Opt[string]
    proxy*: Opt[URL]

  OmniRule* = object
    match*: Regex
    substitute_url*: (proc(s: string): JSResult[string])

  StartConfig = object
    visual_home* {.jsgetset.}: string
    startup_script* {.jsgetset.}: string
    headless* {.jsgetset.}: bool
    console_buffer* {.jsgetset.}: bool

  CSSConfig = object
    stylesheet* {.jsgetset.}: string

  SearchConfig = object
    wrap* {.jsgetset.}: bool
    ignore_case* {.jsgetset.}: bool

  EncodingConfig = object
    display_charset* {.jsgetset.}: Opt[Charset]
    document_charset* {.jsgetset.}: seq[Charset]

  ExternalConfig = object
    tmpdir* {.jsgetset.}: ChaPathResolved
    editor* {.jsgetset.}: string
    mailcap* {.jsgetset.}: seq[ChaPathResolved]
    mime_types* {.jsgetset.}: seq[ChaPathResolved]
    cgi_dir* {.jsgetset.}: seq[ChaPathResolved]
    urimethodmap* {.jsgetset.}: seq[ChaPathResolved]
    download_dir* {.jsgetset.}: string
    w3m_cgi_compat* {.jsgetset.}: bool

  InputConfig = object
    vi_numeric_prefix* {.jsgetset.}: bool
    use_mouse* {.jsgetset.}: bool

  NetworkConfig = object
    max_redirect* {.jsgetset.}: int32
    prepend_https* {.jsgetset.}: bool
    prepend_scheme* {.jsgetset.}: string
    proxy* {.jsgetset.}: Opt[string]
    default_headers* {.jsgetset.}: Table[string, string]

  DisplayConfig = object
    color_mode* {.jsgetset.}: Opt[ColorMode]
    format_mode* {.jsgetset.}: Opt[FormatMode]
    no_format_mode* {.jsgetset.}: FormatMode
    emulate_overline* {.jsgetset.}: bool
    alt_screen* {.jsgetset.}: Opt[bool]
    highlight_color* {.jsgetset.}: RGBAColor
    highlight_marks* {.jsgetset.}: bool
    double_width_ambiguous* {.jsgetset.}: bool
    minimum_contrast* {.jsgetset.}: int32
    force_clear* {.jsgetset.}: bool
    set_title* {.jsgetset.}: bool
    default_background_color* {.jsgetset.}: Opt[RGBColor]
    default_foreground_color* {.jsgetset.}: Opt[RGBColor]
    query_da1* {.jsgetset.}: bool
    columns* {.jsgetset.}: int32
    lines* {.jsgetset.}: int32
    pixels_per_column* {.jsgetset.}: int32
    pixels_per_line* {.jsgetset.}: int32
    force_columns* {.jsgetset.}: bool
    force_lines* {.jsgetset.}: bool
    force_pixels_per_column* {.jsgetset.}: bool
    force_pixels_per_line* {.jsgetset.}: bool

  Config* = ref object
    jsctx: JSContext
    configdir {.jsget.}: string
    `include` {.jsget.}: seq[ChaPathResolved]
    start* {.jsget.}: StartConfig
    search* {.jsget.}: SearchConfig
    css* {.jsget.}: CSSConfig
    encoding* {.jsget.}: EncodingConfig
    external* {.jsget.}: ExternalConfig
    network* {.jsget.}: NetworkConfig
    input* {.jsget.}: InputConfig
    display* {.jsget.}: DisplayConfig
    #TODO getset
    siteconf*: seq[SiteConfig]
    omnirule*: seq[OmniRule]
    page* {.jsget.}: ActionMap
    line* {.jsget.}: ActionMap

  ForkServerConfig* = object
    tmpdir*: string
    ambiguous_double*: bool

jsDestructor(ActionMap)
jsDestructor(StartConfig)
jsDestructor(CSSConfig)
jsDestructor(SearchConfig)
jsDestructor(EncodingConfig)
jsDestructor(ExternalConfig)
jsDestructor(NetworkConfig)
jsDestructor(DisplayConfig)
jsDestructor(Config)

converter toStr*(p: ChaPathResolved): string {.inline.} =
  return string(p)

proc fromJSChaPathResolved(ctx: JSContext; val: JSValue):
    JSResult[ChaPathResolved] =
  return cast[JSResult[ChaPathResolved]](fromJS[string](ctx, val))

proc `[]=`(a: var ActionMap; b, c: string) =
  a.t[b] = c

proc `[]`*(a: ActionMap; b: string): string =
  a.t[b]

proc contains*(a: ActionMap; b: string): bool =
  return b in a.t

proc getOrDefault(a: ActionMap; b: string): string =
  return a.t.getOrDefault(b)

proc hasKeyOrPut(a: var ActionMap; b, c: string): bool =
  return a.t.hasKeyOrPut(b, c)

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
  if skip:
    realk &= '\\'
  return realk

proc getter(a: ptr ActionMap; s: string): Opt[string] {.jsgetprop.} =
  a.t.withValue(s, p):
    return opt(p[])

proc setter(a: ptr ActionMap; k, v: string) {.jssetprop.} =
  let k = getRealKey(k)
  if k == "":
    return
  a[][k] = v
  var teststr = k
  teststr.setLen(teststr.high)
  for i in countdown(k.high, 0):
    if teststr notin a[]:
      a[][teststr] = "client.feedNext()"
    teststr.setLen(i)

proc delete(a: ptr ActionMap; k: string): bool {.jsdelprop.} =
  let k = getRealKey(k)
  let ina = k in a[]
  a[].t.del(k)
  return ina

func names(ctx: JSContext, a: ptr ActionMap): JSPropertyEnumList
    {.jspropnames.} =
  let L = uint32(a[].t.len)
  var list = newJSPropertyEnumList(ctx, L)
  for key in a[].t.keys:
    list.add(key)
  return list

proc bindPagerKey(config: Config; key, action: string) {.jsfunc.} =
  (addr config.page).setter(key, action)

proc bindLineKey(config: Config; key, action: string) {.jsfunc.} =
  (addr config.line).setter(key, action)

proc hasprop(a: ptr ActionMap; s: string): bool {.jshasprop.} =
  return s in a[]

func getProxy*(config: Config): URL =
  if config.network.proxy.isSome:
    let s = config.network.proxy.get
    let x = parseURL(s)
    if x.isSome:
      return x.get
    else:
      raise newException(ValueError, "Invalid proxy URL: " & s)
  return nil

func getDefaultHeaders*(config: Config): Headers =
  return newHeaders(config.network.default_headers)

proc openFileExpand(dir, file: string): FileStream =
  if file.len == 0:
    return nil
  if file[0] == '/':
    return newFileStream(file)
  else:
    return newFileStream(dir / file)

proc readUserStylesheet(dir, file: string): string =
  let x = ChaPath(file).unquote()
  if x.isNone:
    raise newException(ValueError, x.error)
  let s = openFileExpand(dir, x.get)
  if s != nil:
    result = s.readAll()
    s.close()

# The overall configuration will be obtained through the virtual concatenation
# of several individual configuration files known as mailcap files.
proc getMailcap*(config: Config): tuple[mailcap: Mailcap, errs: seq[string]] =
  let configDir = config.configdir
  template uq(s: string): string =
    ChaPath(s).unquote.get
  let gopherPath = "${%CHA_LIBEXEC_DIR}/gopher2html -u \\$MAILCAP_URL".uq
  let geminiPath = "${%CHA_LIBEXEC_DIR}/gmi2html".uq
  let mdPath = "${%CHA_LIBEXEC_DIR}/md2html".uq
  let ansiPath = "${%CHA_LIBEXEC_DIR}/ansi2html".uq
  var mailcap: Mailcap = @[]
  var errs: seq[string]
  var found = false
  for p in config.external.mailcap:
    let f = openFileExpand(configDir, p)
    if f != nil:
      let res = parseMailcap(f)
      if res.isSome:
        mailcap.add(res.get)
      else:
        errs.add(res.error)
      found = true
  mailcap.add(MailcapEntry(
      mt: "text",
      subt: "gopher",
      cmd: gopherPath,
      flags: {HTMLOUTPUT}
  ))
  mailcap.add(MailcapEntry(
    mt: "text",
    subt: "gemini",
    cmd: geminiPath,
    flags: {HTMLOUTPUT}
  ))
  mailcap.add(MailcapEntry(
    mt: "text",
    subt: "markdown",
    cmd: mdPath,
    flags: {HTMLOUTPUT}
  ))
  mailcap.add(MailcapEntry(
    mt: "text",
    subt: "x-ansi",
    cmd: ansiPath,
    flags: {HTMLOUTPUT}
  ))
  return (mailcap, errs)

# We try to source mime types declared in config.
# If none of these files can be found, fall back to DefaultGuess.
#TODO some error handling would be nice, to at least show a warning to
# the user. Not sure how this could be done, though.
proc getMimeTypes*(config: Config): MimeTypes =
  if config.external.mime_types.len == 0:
    return DefaultGuess
  var mimeTypes: MimeTypes
  let configDir = config.configdir
  var found = false
  for p in config.external.mime_types:
    let f = openFileExpand(configDir, p)
    if f != nil:
      mimeTypes.parseMimeTypes(f)
      found = true
  if not found:
    return DefaultGuess
  return mimeTypes

const DefaultURIMethodMap = parseURIMethodMap(staticRead"res/urimethodmap")

proc getURIMethodMap*(config: Config): URIMethodMap =
  let configDir = config.configdir
  var urimethodmap: URIMethodMap
  for p in config.external.urimethodmap:
    let f = openFileExpand(configDir, p)
    if f != nil:
      urimethodmap.parseURIMethodMap(f.readAll())
  urimethodmap.append(DefaultURIMethodMap)
  return urimethodmap

proc getForkServerConfig*(config: Config): ForkServerConfig =
  return ForkServerConfig(
    tmpdir: config.external.tmpdir,
    ambiguous_double: config.display.double_width_ambiguous
  )

type ConfigParser = object
  config: Config
  dir: string
  warnings: seq[string]

proc parseConfigValue(ctx: var ConfigParser; x: var object; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var bool; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var string; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var ChaPath; v: TomlValue;
  k: string)
proc parseConfigValue[T](ctx: var ConfigParser; x: var seq[T]; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var Charset; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var int32; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var int64; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var Opt[ColorMode];
  v: TomlValue; k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var Opt[FormatMode];
  v: TomlValue; k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var FormatMode; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var RGBAColor; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var RGBColor; v: TomlValue;
  k: string)
proc parseConfigValue[T](ctx: var ConfigParser; x: var Opt[T]; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var ActionMap; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var CSSConfig; v: TomlValue;
  k: string)
proc parseConfigValue[U; V](ctx: var ConfigParser; x: var Table[U, V];
  v: TomlValue; k: string)
proc parseConfigValue[T](ctx: var ConfigParser; x: var set[T]; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var TomlTable; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var Regex; v: TomlValue;
  k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var URL; v: TomlValue;
  k: string)
proc parseConfigValue[T](ctx: var ConfigParser; x: var proc(x: T): JSResult[T];
  v: TomlValue; k: string)
proc parseConfigValue(ctx: var ConfigParser; x: var ChaPathResolved;
  v: TomlValue; k: string)

proc typeCheck(v: TomlValue, vt: ValueType, k: string) =
  if v.vt != vt:
    raise newException(ValueError, "invalid type for key " & k &
      " (got " & $v.vt & ", expected " & $vt & ")")

proc typeCheck(v: TomlValue, vt: set[ValueType], k: string) =
  if v.vt notin vt:
    raise newException(ValueError, "invalid type for key " & k &
      " (got " & $v.vt & ", expected " & $vt & ")")

proc parseConfigValue(ctx: var ConfigParser; x: var object; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_TABLE, k)
  for fk, fv in x.fieldPairs:
    when typeof(fv) isnot JSContext:
      let kebabk = snakeToKebabCase(fk)
      if kebabk in v:
        let kkk = if k != "":
          k & "." & fk
        else:
          fk
        ctx.parseConfigValue(fv, v[kebabk], kkk)

proc parseConfigValue[U, V](ctx: var ConfigParser; x: var Table[U, V];
    v: TomlValue; k: string) =
  typeCheck(v, VALUE_TABLE, k)
  x.clear()
  for kk, vv in v:
    var y: V
    let kkk = k & "[" & kk & "]"
    ctx.parseConfigValue(y, vv, kkk)
    x[kk] = y

proc parseConfigValue(ctx: var ConfigParser; x: var bool; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_BOOLEAN, k)
  x = v.b

proc parseConfigValue(ctx: var ConfigParser; x: var string; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  x = v.s

proc parseConfigValue(ctx: var ConfigParser; x: var ChaPath;
    v: TomlValue; k: string) =
  typeCheck(v, VALUE_STRING, k)
  x = ChaPath(v.s)

proc parseConfigValue[T](ctx: var ConfigParser; x: var seq[T]; v: TomlValue;
    k: string) =
  typeCheck(v, {VALUE_STRING, VALUE_ARRAY}, k)
  if v.vt != VALUE_ARRAY:
    var y: T
    ctx.parseConfigValue(y, v, k)
    x = @[y]
  else:
    if not v.ad:
      x.setLen(0)
    for i in 0 ..< v.a.len:
      var y: T
      ctx.parseConfigValue(y, v.a[i], k & "[" & $i & "]")
      x.add(y)

proc parseConfigValue(ctx: var ConfigParser; x: var TomlTable; v: TomlValue;
    k: string) =
  typeCheck(v, {VALUE_TABLE}, k)
  x = v.t

proc parseConfigValue(ctx: var ConfigParser; x: var Charset; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  x = getCharset(v.s)
  if x == CHARSET_UNKNOWN:
    raise newException(ValueError, "unknown charset '" & v.s & "' for key " &
      k)

proc parseConfigValue(ctx: var ConfigParser; x: var int32; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_INTEGER, k)
  x = int32(v.i)

proc parseConfigValue(ctx: var ConfigParser; x: var int64; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_INTEGER, k)
  x = v.i

proc parseConfigValue(ctx: var ConfigParser; x: var Opt[ColorMode];
    v: TomlValue; k: string) =
  typeCheck(v, VALUE_STRING, k)
  case v.s
  of "auto": x.err()
  of "monochrome": x.ok(MONOCHROME)
  of "ansi": x.ok(ANSI)
  of "8bit", "eight-bit": x.ok(EIGHT_BIT)
  of "24bit", "true-color": x.ok(TRUE_COLOR)
  else:
    raise newException(ValueError, "unknown color mode '" & v.s &
      "' for key " & k)

proc parseConfigValue(ctx: var ConfigParser; x: var Opt[FormatMode];
    v: TomlValue; k: string) =
  typeCheck(v, {VALUE_STRING, VALUE_ARRAY}, k)
  if v.vt == VALUE_STRING and v.s == "auto":
    x.err()
  else:
    var y: FormatMode
    ctx.parseConfigValue(y, v, k)
    x.ok(y)

proc parseConfigValue(ctx: var ConfigParser; x: var FormatMode; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_ARRAY, k)
  for i in 0 ..< v.a.len:
    let kk = k & "[" & $i & "]"
    let vv = v.a[i]
    typeCheck(vv, VALUE_STRING, kk)
    case vv.s
    of "bold": x.incl(FLAG_BOLD)
    of "italic": x.incl(FLAG_ITALIC)
    of "underline": x.incl(FLAG_UNDERLINE)
    of "reverse": x.incl(FLAG_REVERSE)
    of "strike": x.incl(FLAG_STRIKE)
    of "overline": x.incl(FLAG_OVERLINE)
    of "blink": x.incl(FLAG_BLINK)
    else:
      raise newException(ValueError, "unknown format mode '" & vv.s &
        "' for key " & kk)

proc parseConfigValue(ctx: var ConfigParser; x: var RGBAColor; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  let c = parseRGBAColor(v.s)
  if c.isNone:
    raise newException(ValueError, "invalid color '" & v.s &
      "' for key " & k)
  x = c.get

proc parseConfigValue(ctx: var ConfigParser; x: var RGBColor; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  let c = parseLegacyColor(v.s)
  if c.isNone:
    raise newException(ValueError, "invalid color '" & v.s &
      "' for key " & k)
  x = c.get

proc parseConfigValue[T](ctx: var ConfigParser; x: var Opt[T]; v: TomlValue;
    k: string) =
  if v.vt == VALUE_STRING and v.s == "auto":
    x.err()
  else:
    var y: T
    ctx.parseConfigValue(y, v, k)
    x.ok(y)

proc parseConfigValue(ctx: var ConfigParser; x: var ActionMap; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_TABLE, k)
  for kk, vv in v:
    typeCheck(vv, VALUE_STRING, k & "[" & kk & "]")
    let rk = getRealKey(kk)
    var buf: string
    for i in 0 ..< rk.high:
      buf &= rk[i]
      discard x.hasKeyOrPut(buf, "client.feedNext()")
    x[rk] = vv.s

proc parseConfigValue[T: enum](ctx: var ConfigParser; x: var T; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  let e = strictParseEnum[T](v.s)
  if e.isNone:
    raise newException(ValueError, "invalid value '" & v.s & "' for key " & k)
  x = e.get

proc parseConfigValue[T](ctx: var ConfigParser; x: var set[T]; v: TomlValue;
    k: string) =
  typeCheck(v, {VALUE_STRING, VALUE_ARRAY}, k)
  if v.vt == VALUE_STRING:
    var xx: T
    xx.parseConfigValue(v, k)
    x = {xx}
  else:
    x = {}
    for i in 0 ..< v.a.len:
      let kk = k & "[" & $i & "]"
      var xx: T
      xx.parseConfigValue(v.a[i], kk)
      x.incl(xx)

proc parseConfigValue(ctx: var ConfigParser; x: var CSSConfig; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_TABLE, k)
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
        x.stylesheet &= readUserStylesheet(ctx.dir, vv.s)
      of VALUE_ARRAY:
        for child in vv.a:
          x.stylesheet &= readUserStylesheet(ctx.dir, vv.s)
      else: discard
    of "inline":
      typeCheck(vv, VALUE_STRING, kkk)
      x.stylesheet &= vv.s

proc parseConfigValue(ctx: var ConfigParser; x: var Regex; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  let y = compileMatchRegex(v.s)
  if y.isNone:
    raise newException(ValueError, "invalid regex " & k & " : " & y.error)
  x = y.get

proc parseConfigValue(ctx: var ConfigParser; x: var URL; v: TomlValue;
    k: string) =
  typeCheck(v, VALUE_STRING, k)
  let y = parseURL(v.s)
  if y.isNone:
    raise newException(ValueError, "invalid URL " & k)
  x = y.get

proc parseConfigValue[T](ctx: var ConfigParser; x: var proc(x: T): JSResult[T];
    v: TomlValue; k: string) =
  typeCheck(v, VALUE_STRING, k)
  let fun = ctx.config.jsctx.eval(v.s, "<config>", JS_EVAL_TYPE_GLOBAL)
  x = getJSFunction[T, T](ctx.config.jsctx, fun)

proc parseConfigValue(ctx: var ConfigParser; x: var ChaPathResolved;
    v: TomlValue; k: string) =
  typeCheck(v, VALUE_STRING, k)
  let y = ChaPath(v.s).unquote()
  if y.isErr:
    raise newException(ValueError, y.error)
  x = ChaPathResolved(y.get)

type ParseConfigResult* = object
  success*: bool
  warnings*: seq[string] #TODO actually use warnings
  errorMsg*: string

proc parseConfig(config: Config; dir: string; stream: Stream; name = "<input>";
  laxnames = false): ParseConfigResult

proc parseConfig(config: Config; dir: string; t: TomlValue): ParseConfigResult =
  var ctx = ConfigParser(config: config, dir: dir)
  config.configdir = dir
  try:
    var myRes = ParseConfigResult(success: true)
    ctx.parseConfigValue(config[], t, "")
    #TODO: for omnirule/siteconf, check if substitution rules are specified?
    while config.`include`.len > 0:
      #TODO: warn about recursive includes
      var includes = config.`include`
      config.`include`.setLen(0)
      for s in includes:
        let res = config.parseConfig(dir, openFileExpand(dir, s))
        if not res.success:
          return res
        myRes.warnings.add(res.warnings)
    myRes.warnings.add(ctx.warnings)
    return myRes
  except ValueError as e:
    return ParseConfigResult(
      success: false,
      warnings: ctx.warnings,
      errorMsg: e.msg
    )

proc parseConfig(config: Config; dir: string; stream: Stream; name = "<input>";
    laxnames = false): ParseConfigResult =
  let toml = parseToml(stream, dir / name, laxnames)
  if toml.isOk:
    return config.parseConfig(dir, toml.get)
  else:
    return ParseConfigResult(
      success: false,
      errorMsg: "Fatal error: failed to parse config\n" & toml.error & '\n'
    )

proc parseConfig*(config: Config; dir, s: string; name = "<input>";
    laxnames = false): ParseConfigResult =
  return config.parseConfig(dir, newStringStream(s), name, laxnames)

const defaultConfig = staticRead"res/config.toml"

proc readConfig(config: Config; dir, name: string): ParseConfigResult =
  let fs = if name.len > 0 and name[0] == '/':
    newFileStream(name)
  else:
    newFileStream(dir / name)
  if fs != nil:
    return config.parseConfig(dir, fs)
  return ParseConfigResult(success: true)

proc loadConfig*(config: Config; s: string) {.jsfunc.} =
  let s = if s.len > 0 and s[0] == '/':
    s
  else:
    getCurrentDir() / s
  if not fileExists(s):
    return
  discard config.parseConfig(parentDir(s), newFileStream(s))

proc getNormalAction*(config: Config; s: string): string =
  return config.page.getOrDefault(s)

proc getLinedAction*(config: Config; s: string): string =
  return config.line.getOrDefault(s)

proc readConfig*(pathOverride: Option[string]; jsctx: JSContext): Config =
  result = Config(jsctx: jsctx)
  discard result.parseConfig("res", newStringStream(defaultConfig)) #TODO TODO TODO
  if pathOverride.isNone:
    when defined(debug):
      discard result.readConfig(getCurrentDir() / "res", "config.toml")
    discard result.readConfig(getConfigDir() / "chawan", "config.toml")
  else:
    discard result.readConfig(getCurrentDir(), pathOverride.get)

proc addConfigModule*(ctx: JSContext) =
  ctx.registerType(ActionMap)
  ctx.registerType(StartConfig)
  ctx.registerType(CSSConfig)
  ctx.registerType(SearchConfig)
  ctx.registerType(EncodingConfig)
  ctx.registerType(ExternalConfig)
  ctx.registerType(NetworkConfig)
  ctx.registerType(DisplayConfig)
  ctx.registerType(Config)
