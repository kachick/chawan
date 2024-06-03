import monoucha/javascript
import types/referrer
import types/url

type
  ParserMetadata* = enum
    pmParserInserted, pmNotParserInserted

  ScriptType* = enum
    NO_SCRIPTTYPE, CLASSIC, MODULE, IMPORTMAP

  ScriptResultType* = enum
    RESULT_NULL, RESULT_SCRIPT, RESULT_IMPORT_MAP_PARSE, RESULT_FETCHING

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
    of RESULT_NULL:
      discard
    of RESULT_SCRIPT:
      script*: Script
    of RESULT_FETCHING:
      discard
    of RESULT_IMPORT_MAP_PARSE:
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
