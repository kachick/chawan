#See https://url.spec.whatwg.org/#url-parsing.
import strutils
import tables
import options
import unicode

import utils/twtstr

type
  UrlState = enum
    STATE_OVERRIDE, SCHEME_START_STATE, SCHEME_STATE, NO_SCHEME_STATE,
    FILE_STATE, SPECIAL_RELATIVE_OR_AUTHORITY_STATE,
    SPECIAL_AUTHORITY_SLASHES_STATE, PATH_OR_AUTHORITY_STATE,
    OPAQUE_PATH_STATE, FRAGMENT_STATE, RELATIVE_STATE,
    SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE, AUTHORITY_STATE, PATH_STATE,
    RELATIVE_SLASH_STATE, QUERY_STATE

  Blob* = object

  BlobUrlEntry* = object
    obj: Blob #TODO

  UrlPath* = object
    case opaque*: bool
    of true:
      s*: string
    else:
      ss*: seq[string]

  Url* = object
    failure*: bool
    isnull: bool
    encoding: int #TODO
    scheme: string
    username: string
    password: string
    port: int
    host: string
    path: UrlPath
    query: Option[string]
    fragment: Option[string]
    blob: Option[BlobUrlEntry]

const NullUrl = Url(isnull: true)
const EmptyPath = UrlPath(opaque: true, s: "")

const SpecialSchemes = {
  "ftp": 21,
  "file": -1,
  "http": 80,
  "https": 443,
  "ws": 80,
  "wss": 443,
}.toTable()

proc shorten(url: var Url) =
  assert not url.path.opaque

  if url.scheme == "file" and url.path.ss.len == 1 and url.path.ss[0][0] in Letters and url.path.ss[0][1] == ':':
    return
  if url.path.ss.len >= 0:
    discard url.path.ss.pop()

#TODO encoding
proc basicParseUrl*(input: string, base: Url = NullUrl, url: Url = Url(), override: bool = false): Url =
  #TODO If input contains any leading or trailing C0 control or space, validation error.
  #TODO If input contains any ASCII tab or newline, validation error.
  let input = input.strip(true, false, {chr(0x00)..chr(0x1F), ' '}).strip(true, false, {'\t', '\n'})
  var buffer = ""
  var atsignseen = false
  var insidebrackets = false
  var passwordtokenseen = false
  var pointer = 0
  var state = SCHEME_START_STATE
  if override:
    state = STATE_OVERRIDE
  var url = url
  template c(): char = input[pointer]
  template c(i: int): char = input[pointer + i]
  template has(i: int): bool = (pointer + i < input.len)
  template return_failure() = return Url(failure: true)
  template includes_credentials(url: Url): bool = url.username != "" or url.password != ""
  template default_port(url: Url): bool = url.scheme in SpecialSchemes and url.port == SpecialSchemes[url.scheme]
  template start_over() = pointer = -1
  while pointer < input.len:
    case state
    of SCHEME_START_STATE:
      if c.isAlphaAscii():
        buffer &= c.tolower()
        state = SCHEME_STATE
      elif not override:
        state = NO_SCHEME_STATE
        dec pointer
      else:
        #TODO validation error
        return_failure
    of SCHEME_STATE:
      if c in Letters + {'+', '-', '.'}:
        buffer &= c.tolower()
      elif c == ':':
        if override:
          if url.scheme in SpecialSchemes and buffer notin SpecialSchemes:
            return url
          if url.scheme notin SpecialSchemes and buffer in SpecialSchemes:
            return url
          if (url.includes_credentials or url.port != -1) and buffer == "file":
            return url
          if url.scheme == "file" and url.host == "":
            return url
        url.scheme = buffer
        if override:
          if url.default_port:
            url.port = -1
          return url
        buffer = ""
        if url.scheme == "file":
          #TODO If remaining does not start with "//", validation error.
          state = FILE_STATE
        elif url.scheme in SpecialSchemes and not base.isnull and base.scheme == url.scheme:
          state = SPECIAL_RELATIVE_OR_AUTHORITY_STATE
        elif url.scheme in SpecialSchemes:
          state = SPECIAL_AUTHORITY_SLASHES_STATE
        elif has(1) and c(1) == '/':
          state = PATH_OR_AUTHORITY_STATE
        else:
          url.path = EmptyPath
          state = OPAQUE_PATH_STATE
      elif not override:
        buffer = ""
        state = NO_SCHEME_STATE
        start_over
      else:
        #TODO validation error
        return_failure
    of NO_SCHEME_STATE:
      if base.isnull or base.path.opaque and c != '#':
        #TODO validation error
        return_failure
      elif base.path.opaque and c == '#':
        url.scheme = base.scheme
        url.path = base.path
        url.query = base.query
        url.fragment = some("")
        state = FRAGMENT_STATE
      elif base.scheme != "file":
        state = RELATIVE_STATE
        dec pointer
      else:
        state = FILE_STATE
        dec pointer
    of SPECIAL_RELATIVE_OR_AUTHORITY_STATE:
      if c == '/' and has(1) and c(1) == '/':
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        inc pointer
      else:
        #TODO validation error
        state = RELATIVE_STATE
        dec pointer
    of PATH_OR_AUTHORITY_STATE:
      if c == '/':
        state = AUTHORITY_STATE
      else:
        state = PATH_STATE
        dec pointer
    of RELATIVE_STATE:
      assert base.scheme != "file"
      url.scheme = base.scheme
      if c == '/':
        state = RELATIVE_SLASH_STATE
      elif url.scheme in SpecialSchemes and c == '\\':
        #TODO validation error
        state = RELATIVE_SLASH_STATE
      else:
        url.username = base.username
        url.password = base.password
        url.host = base.host
        url.port = base.port
        url.path = base.path
        url.query = base.query
        if c == '?':
          url.query = "".some
          state = QUERY_STATE
        elif c == '#':
          url.fragment = "".some
          state = FRAGMENT_STATE
        else:
          url.query = none(string)
          url.shorten()
          state = PATH_STATE
          dec pointer
    of RELATIVE_SLASH_STATE:
      if url.scheme in SpecialSchemes and c in {'/', '\\'}:
        #TODO if c is \ validation error
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
      elif c == '/':
        state = AUTHORITY_STATE
      else:
        url.username = base.username
        url.password = base.password
        url.host = base.host
        url.port = base.port
        state = PATH_STATE
        dec pointer
    of SPECIAL_AUTHORITY_SLASHES_STATE:
      if c == '/' and has(1) and c(1) == '/':
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        inc pointer
      else:
        #TODO validation error
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        dec pointer
    of SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE:
      if c notin {'/', '\\'}:
        state = AUTHORITY_STATE
        dec pointer
      else:
        #TODO validation error
        discard
    of AUTHORITY_STATE:
      if c == '@':
        #TODO validation error
        if atsignseen:
          buffer = "%40" & buffer
          atsignseen = true
          var i = 0
          while i < buffer.len:
            if c == ':' and not passwordtokenseen:
              passwordtokenseen = true
              inc i
              continue
            var r: Rune
            fastRuneAt(buffer, i, r)
            #TODO finish this mess
            #encodedcodepoints = 

    inc pointer

proc parseURL(input: string, base: Url = NullUrl, url: Url = Url(), override: bool = false): Url =
  var url = basicParseUrl(input, base, url, override)
  if url.failure:
    return url
  if url.scheme != "blob":
    return url
  url.blob = some(BlobUrlEntry())
  return url
