import js/javascript
import loader/request
import types/referrer
import types/url

type
  ParserMetadata* = enum
    PARSER_INSERTED, NOT_PARSER_INSERTED

  ScriptType* = enum
    NO_SCRIPTTYPE, CLASSIC, MODULE, IMPORTMAP

  ScriptResultType* = enum
    RESULT_NULL, RESULT_SCRIPT, RESULT_IMPORT_MAP_PARSE, RESULT_FETCHING

type
  EnvironmentSettings* = ref object
    scripting*: bool
    moduleMap*: ModuleMap

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

proc find*(moduleMap: ModuleMap, url: URL, moduleType: string): int =
  let surl = $url
  for i, entry in moduleMap:
    if entry.key.moduleType == moduleType and entry.key.url == surl:
      return i
  return -1

func fetchDestinationFromModuleType*(defaultDestination: RequestDestination,
    moduleType: string): RequestDestination =
  if moduleType == "json":
    return RequestDestination.JSON
  if moduleType == "css":
    return RequestDestination.STYLE
  return defaultDestination
