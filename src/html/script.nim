import monoucha/javascript
import types/referrer
import types/url

type
  ParserMetadata* = enum
    pmParserInserted, pmNotParserInserted

  ScriptType* = enum
    stNone, stClassic, stModule, stImportMap

  ScriptResultType* = enum
    srtNull, srtScript, srtImportMapParse, srtFetching

  RequestDestination* = enum
    rdNone = ""
    rdAudio = "audio"
    rdAudioworklet = "audioworklet"
    rdDocument = "document"
    rdEmbed = "embed"
    rdFont = "font"
    rdFrame = "frame"
    rdIframe = "iframe"
    rdImage = "image"
    rdJson = "json"
    rdManifest = "manifest"
    rdObject = "object"
    rdPaintworklet = "paintworklet"
    rdReport = "report"
    rdScript = "script"
    rdServiceworker = "serviceworker"
    rdSharedworker = "sharedworker"
    rdStyle = "style"
    rdTrack = "track"
    rdWorker = "worker"
    rdXslt = "xslt"

  CredentialsMode* = enum
    cmSameOrigin = "same-origin"
    cmOmit = "omit"
    cmInclude = "include"

type
  EnvironmentSettings* = ref object
    scripting*: bool
    moduleMap*: ModuleMap
    origin*: Origin

  Script* = object
    #TODO setings
    baseURL*: URL
    options*: ScriptOptions
    mutedErrors*: bool
    #TODO parse error/error to rethrow
    record*: JSValue

  ScriptOptions* = object
    nonce*: string
    integrity*: string
    parserMetadata*: ParserMetadata
    credentialsMode*: CredentialsMode
    referrerPolicy*: Option[ReferrerPolicy]
    renderBlocking*: bool

  ScriptResult* = ref object
    case t*: ScriptResultType
    of srtNull, srtFetching:
      discard
    of srtScript:
      script*: Script
    of srtImportMapParse:
      discard #TODO

  ModuleMapEntry = object
    key: tuple[url, moduleType: string]
    value*: ScriptResult

  ModuleMap* = seq[ModuleMapEntry]

proc find*(moduleMap: ModuleMap; url: URL; moduleType: string): int =
  let surl = $url
  for i, entry in moduleMap:
    if entry.key.moduleType == moduleType and entry.key.url == surl:
      return i
  return -1

func fetchDestinationFromModuleType*(default: RequestDestination;
    moduleType: string): RequestDestination =
  if moduleType == "json":
    return rdJson
  if moduleType == "css":
    return rdStyle
  return default

var windowConsoleError*: proc(ctx: JSContext; ss: varargs[string]) {.nimcall.}

proc logException*(ctx: JSContext) =
  windowConsoleError(ctx, ctx.getExceptionMsg())
