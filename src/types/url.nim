#See https://url.spec.whatwg.org/#url-parsing.
import strutils
import tables
import options
import unicode
import math

import utils/twtstr

type
  UrlState = enum
    SCHEME_START_STATE, SCHEME_STATE, NO_SCHEME_STATE, FILE_STATE,
    SPECIAL_RELATIVE_OR_AUTHORITY_STATE, SPECIAL_AUTHORITY_SLASHES_STATE,
    PATH_OR_AUTHORITY_STATE, OPAQUE_PATH_STATE, FRAGMENT_STATE, RELATIVE_STATE,
    SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE, AUTHORITY_STATE, PATH_STATE,
    RELATIVE_SLASH_STATE, QUERY_STATE, HOST_STATE, HOSTNAME_STATE,
    FILE_HOST_STATE, PORT_STATE, PATH_START_STATE, FILE_SLASH_STATE

  Blob* = object

  BlobUrlEntry* = object
    obj: Blob #TODO

  UrlPath* = object
    case opaque*: bool
    of true:
      s*: string
    else:
      ss*: seq[string]

  Host = object
    domain: string
    ipv4: Option[uint32]
    ipv6: Option[array[8, uint16]]
    opaquehost: string

  Url* = object
    encoding: int #TODO
    scheme*: string
    username: string
    password: string
    port: Option[uint16]
    host: Option[Host]
    path*: UrlPath
    query: Option[string]
    fragment: Option[string]
    blob: Option[BlobUrlEntry]

const EmptyPath = UrlPath(opaque: true, s: "")
const EmptyHost = Host(domain: "").some

const SpecialSchemes = {
  "ftp": 21u16.some,
  "file": none(uint16),
  "http": 80u16.some,
  "https": 443u16.some,
  "ws": 80u16.some,
  "wss": 443u16.some,
}.toTable()

func parseIpv6(input: string): Option[array[8, uint16]] =
  var pieceindex = 0
  var compress = -1
  var pointer = 0
  var address: array[8, uint16]

  template c(i = 0): char = input[pointer + i]
  template has(i = 0): bool = (pointer + i < input.len)
  template failure(): Option[array[8, uint16]] = none(array[8, uint16])
  if c == ':':
    if not has(1) or c(1) != ':':
      #TODO validation error
      return failure
    pointer += 2
    inc pieceindex
    compress = pieceindex
  while has:
    if pieceindex == 8:
      #TODO validation error
      return failure
    if c == ':':
      if compress != -1:
        #TODO validation error
        return failure
      inc pointer
      inc pieceindex
      compress = pieceindex
      continue
    var value: uint16 = 0
    var length = 0
    while length < 4 and has and c in HexDigits:
      value = value * 0x10 + uint16(c.hexValue)
      inc pointer
      inc length
    if has and c == '.':
      if length == 0:
        #TODO validation error
        return failure
      pointer -= length
      if pieceindex > 6:
        #TODO validation error
        return failure
      var numbersseen = 0
      while has:
        var ipv4piece = -1
        if numbersseen > 0:
          if c == '.' and numbersseen < 4:
            inc pointer
          else:
            #TODO validation error
            return failure
        if not has or c notin Digits:
          #TODO validation error
          return failure
        while has and c in Digits:
          if ipv4piece == -1:
            ipv4piece = c.decValue
          elif ipv4piece == 0:
            #TODO validation error
            return failure
          else:
            ipv4piece = ipv4piece * 10 + c.decValue
          if ipv4piece > 255:
            #TODO validation error
            return failure
          inc pointer
        address[pieceindex] = address[pieceindex] * 0x100 + uint16(ipv4piece)
        inc numbersseen
        if numbersseen == 2 or numbersseen == 4:
          inc pieceindex
      if numbersseen != 4:
        #TODO validation error
        return failure
      break
    elif has and c == ':':
      inc pointer
      if not has:
        #TODO validation error
        return failure
      address[pieceindex] = value
      inc pieceindex
  if compress != -1:
    var swaps = pieceindex - compress
    pieceindex = 7
    while pieceindex != 0 and swaps > 0:
      let sp = address[pieceindex]
      address[pieceindex] = address[compress + swaps - 1]
      address[compress + swaps - 1] = sp
      dec pieceindex
      dec swaps
  elif pieceindex != 8:
    #TODO validation error
    return failure
  return address.some

func parseIpv4Number(s: string): tuple[num: int, validationError: bool] =
  if s == "": return (-1, true)
  var input = s
  var R = 10
  var validationerror = false
  if input.len >= 2 and input[0] == '0':
    if input[1] in {'x', 'X'}:
      validationerror = true
      input = input.substr(2)
      R = 16
    else:
      validationerror = true
      input = input.substr(1)
      R = 8
  if input == "":
    return (0, true)

  var output = 0
  try:
    case R
    of 8: output = parseOctInt(input)
    of 10: output = parseInt(input)
    of 16: output = parseHexInt(input)
    else: discard
  except ValueError: return (-1, true)
  return (output, validationerror)

func parseIpv4(input: string): Option[uint32] =
  var validationerror = false
  var parts = input.split('.')
  if parts[^1] == "":
    validationerror = true
    if parts.len > 1:
      discard parts.pop()
  if parts.len > 4:
    #TODO validation error
    return none(uint32)
  var numbers: seq[int]
  for i in low(parts)..high(parts):
    let part = parts[i]
    let pp = parseIpv4Number(part)
    if pp[0] < 0: 
      #TODO validation error
      return none(uint32)
    if pp[0] > 255:
      validationerror = true
      if i != high(parts):
        #TODO validation error
        return none(uint32)
    if pp[1]:
      validationerror = true
    numbers.add(pp[0])
  #TODO validation error if validationerror
  if numbers[^1] >= 256^(5-numbers.len):
    #TODO validation error
    return none(uint32)
  var ipv4 = uint32(numbers[^1])
  discard numbers.pop()
  for i in 0..numbers.high:
    let n = uint32(numbers[i])
    ipv4 += n * (256u32 ^ (3 - i))
  return ipv4.some

const ForbiddenHostChars = {
  chr(0x00), '\t', '\n', '\r', ' ', '#', '%', '/', ':', '<', '>', '?', '@',
  '[', '\\', ']', '^', '|'
}
func opaqueParseHost(input: string): Option[Host] =
  for c in input:
    if c in ForbiddenHostChars:
      return none(Host)
    #TODO If input contains a code point that is not a URL code point and not
    #U+0025 (%), validation error.
    #TODO If input contains a U+0025 (%) and the two code points following it
    #are not ASCII hex digits, validation error.
  var o = ""
  for c in input:
    o.percentEncode(c, ControlPercentEncodeSet)

func endsInNumber(input: string): bool =
  var parts = input.split('.')
  if parts[^1] == "":
    if parts.len == 1: return false
    discard parts.pop()
  if parts.len == 0: return false
  var last = parts[^1]
  if last != "":
    if last.len == 2 and last[0] in Digits and last[1].tolower() == 'x':
      last = last.substr(2)
    for c in last:
      if c notin Digits:
        return false
    return true
  return false

func domainToAscii*(domain: string, bestrict = false): Option[string] =
  var needsprocessing = false
  for s in domain.split('.'):
    var i = 0
    var xn = 0
    while i < s.len:
      if s[i] notin Ascii:
        needsprocessing = true
        break
      case i
      of 0:
        if s[i] == 'x': inc xn
      of 1:
        if s[i] == 'n': inc xn
      of 2:
        if s[i] == '-': inc xn
      of 3:
        if s[i] == '-' and xn == 3:
          needsprocessing = true
          break
      else: discard
      inc i
    if needsprocessing:
      break
  if bestrict or needsprocessing:
    #Note: we don't implement STD3 separately, it's always true
    result = domain.unicodeToAscii(false, true, true, false, bestrict)
    if result.isnone or result.get == "":
      #TODO validation error
      return none(string)
    return result
  else:
    return domain.toAsciiLower().some

func parseHost(input: string, isnotspecial = false): Option[Host] =
  if input.len == 0: return
  if input[0] == '[':
    if input[^1] != ']':
      #TODO validation error
      return none(Host)
    return Host(ipv6: parseIpv6(input.substr(1, input.high - 1))).some
  if isnotspecial: #TODO ??
    return opaqueParseHost(input)
  let domain = percentDecode(input)
  let asciiDomain = domain.domainToAscii()
  if asciiDomain.isnone:
    #TODO validation error
    return none(Host)
  for c in asciiDomain.get:
    if c in ForbiddenHostChars:
      #TODO validation error
      return none(Host)
  if asciiDomain.get.len > 0 and asciiDomain.get.endsInNumber():
    let ipv4 = parseIpv4(asciiDomain.get)
    return Host(ipv4: ipv4).some
  return Host(domain: asciiDomain.get).some

func isempty(host: Host): bool =
  return host.domain == "" and host.ipv4.isnone and host.ipv6.isnone and host.opaquehost == ""

proc shorten_path(url: var Url) {.inline.} =
  assert not url.path.opaque

  if url.scheme == "file" and url.path.ss.len == 1 and url.path.ss[0][0] in Letters and url.path.ss[0][1] == ':':
    return
  if url.path.ss.len > 0:
    discard url.path.ss.pop()

proc append(path: var UrlPath, s: string) =
  if path.opaque:
    path.s &= s
  else:
    path.ss.add(s)

template includes_credentials(url: Url): bool = url.username != "" or url.password != ""
template is_windows_drive_letter(s: string): bool = s.len == 2 and s[0] in Letters and (s[1] == ':' or s[1] == '|')

#TODO encoding
proc basicParseUrl*(input: string, base = none(Url), url: var Url = Url(), override: bool = false): Option[Url] =
  #TODO If input contains any leading or trailing C0 control or space, validation error.
  #TODO If input contains any ASCII tab or newline, validation error.
  let input = input.strip(true, false, {chr(0x00)..chr(0x1F), ' '}).strip(true, false, {'\t', '\n'})
  var buffer = ""
  var atsignseen = false
  var insidebrackets = false
  var passwordtokenseen = false
  var pointer = 0
  var state = SCHEME_START_STATE

  template c(i = 0): char = input[pointer + i]
  template has(i = 0): bool = (pointer + i < input.len)
  template is_special(url: Url): bool = url.scheme in SpecialSchemes
  template default_port(url: Url): Option[uint16] = SpecialSchemes[url.scheme]
  template start_over() = pointer = -1
  template starts_with_windows_drive_letter(s: string): bool = s.len >= 2 and s[0] in Letters and (s[1] == ':' or s[1] == '|')
  template is_normalized_windows_drive_letter(s: string): bool = s.len == 2 and s[0] in Letters and (s[1] == ':')
  template is_windows_drive_letter(s: string): bool = s.len == 2 and s[0] in Letters and (s[1] == ':' or s[1] == '|')
  template is_double_dot_path_segment(s: string): bool = s == ".." or s.equalsIgnoreCase(".%2e") or s.equalsIgnoreCase("%2e.") or s.equalsIgnoreCase("%2e%2e")
  template is_single_dot_path_segment(s: string): bool = s == "." or s.equalsIgnoreCase("%2e")
  template is_empty(path: UrlPath): bool = path.ss.len == 0

  while pointer <= input.len:
    case state
    of SCHEME_START_STATE:
      if has and c.isAlphaAscii():
        buffer &= c.tolower()
        state = SCHEME_STATE
      elif not override:
        state = NO_SCHEME_STATE
        dec pointer
      else:
        #TODO validation error
        return none(Url)
    of SCHEME_STATE:
      if has and c in Letters + {'+', '-', '.'}:
        buffer &= c.tolower()
      elif has and c == ':':
        if override:
          if url.scheme in SpecialSchemes and buffer notin SpecialSchemes:
            return url.some
          if url.scheme notin SpecialSchemes and buffer in SpecialSchemes:
            return url.some
          if (url.includes_credentials or url.port.issome) and buffer == "file":
            return url.some
          if url.scheme == "file" and url.host.get.isempty:
            return url.some
        url.scheme = buffer
        if override:
          if url.default_port == url.port:
            url.port = none(uint16)
          return url.some
        buffer = ""
        if url.scheme == "file":
          #TODO If remaining does not start with "//", validation error.
          state = FILE_STATE
        elif url.is_special and not base.isnone and base.get.scheme == url.scheme:
          state = SPECIAL_RELATIVE_OR_AUTHORITY_STATE
        elif url.is_special:
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
        return none(Url)
    of NO_SCHEME_STATE:
      if base.isnone or base.get.path.opaque and (not has or c != '#'):
        #TODO validation error
        return none(Url)
      elif base.get.path.opaque and has and c == '#':
        url.scheme = base.get.scheme
        url.path = base.get.path
        url.query = base.get.query
        url.fragment = "".some
        state = FRAGMENT_STATE
      elif base.get.scheme != "file":
        state = RELATIVE_STATE
        dec pointer
      else:
        state = FILE_STATE
        dec pointer
    of SPECIAL_RELATIVE_OR_AUTHORITY_STATE:
      if has(1) and c == '/' and c(1) == '/':
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
      assert base.get.scheme != "file"
      url.scheme = base.get.scheme
      if has and c == '/':
        state = RELATIVE_SLASH_STATE
      elif url.is_special and has and c == '\\':
        #TODO validation error
        state = RELATIVE_SLASH_STATE
      else:
        url.username = base.get.username
        url.password = base.get.password
        url.host = base.get.host
        url.port = base.get.port
        url.path = base.get.path
        url.query = base.get.query
        if has and c == '?':
          url.query = "".some
          state = QUERY_STATE
        elif has and c == '#':
          url.fragment = "".some
          state = FRAGMENT_STATE
        else:
          url.query = none(string)
          url.shorten_path()
          state = PATH_STATE
          dec pointer
    of RELATIVE_SLASH_STATE:
      if url.is_special and has and c in {'/', '\\'}:
        #TODO if c is \ validation error
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
      elif has and c == '/':
        state = AUTHORITY_STATE
      else:
        url.username = base.get.username
        url.password = base.get.password
        url.host = base.get.host
        url.port = base.get.port
        state = PATH_STATE
        dec pointer
    of SPECIAL_AUTHORITY_SLASHES_STATE:
      if has(1) and c == '/' and c(1) == '/':
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        inc pointer
      else:
        #TODO validation error
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        dec pointer
    of SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE:
      if has and c notin {'/', '\\'}:
        state = AUTHORITY_STATE
        dec pointer
      else:
        #TODO validation error
        discard
    of AUTHORITY_STATE:
      if has and c == '@':
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
            if passwordtokenseen:
              url.password.percentEncode(c, UserInfoPercentEncodeSet)
            else:
              url.username.percentEncode(c, UserInfoPercentEncodeSet)
          buffer = ""
      elif not has or c in {'/', '?', '#'} or (url.is_special and c == '\\'):
        if atsignseen and buffer == "":
          #TODO validation error
          return none(Url)
        pointer -= buffer.len + 1
        buffer = ""
        state = HOST_STATE
      else:
        buffer &= c
    of HOST_STATE, HOSTNAME_STATE:
      if override and url.scheme == "file":
        dec pointer
        state = FILE_HOST_STATE
      elif has and c == ':' and not insidebrackets:
        if buffer == "":
          #TODO validation error
          return none(Url)
        let host = parseHost(buffer)
        if host.isnone:
          return none(Url)
        url.host = host
        buffer = ""
        state = PORT_STATE
      elif (not has or c in {'/', '?', '#'}) or
        (url.is_special and c == '\\'):
        dec pointer
        if url.is_special and buffer == "":
          #TODO validation error
          return none(Url)
        elif override and buffer == "" and (url.includes_credentials or url.port.issome):
          return
        let host = parseHost(buffer)
        if host.isnone:
          return none(Url)
        url.host = host
        buffer = ""
        state = PATH_START_STATE
        if override:
          return
      else:
        if c == '[':
          insidebrackets = true
        elif c == ']':
          insidebrackets = false
        buffer &= c
    of PORT_STATE:
      if has and c in Digits:
        buffer &= c
      elif (not has or c in {'/', '?', '#'}) or
        (url.is_special and c == '\\') or override:
        if buffer != "":
          let i = parseInt32(buffer)
          if i notin 0..65535:
            #TODO validation error
            return none(Url)
          let port = cast[uint16](i).some
          url.port = if url.default_port == port: none(uint16) else: port
          buffer = ""
        if override:
          return
        state = PATH_START_STATE
        dec pointer
      else:
        #TODO validation error
        return none(Url)
    of FILE_STATE:
      url.scheme = "file"
      url.host = EmptyHost
      if has and (c == '/' or c == '\\'):
        #TODO if c == '\\' validation error
        state = FILE_SLASH_STATE
      elif base.issome and base.get.scheme == "file":
        url.host = base.get.host
        url.path = base.get.path
        url.query = base.get.query
        if has:
          if c == '?':
            url.query = "".some
            state = QUERY_STATE
          elif c == '#':
            url.fragment = "".some
            state = FRAGMENT_STATE
          else:
            url.query = none(string)
            if not input.substr(pointer).starts_with_windows_drive_letter():
              url.shorten_path()
            else:
              #TODO validation error
              url.path.ss.setLen(0)
            state = PATH_STATE
            dec pointer
      else:
        state = PATH_STATE
        dec pointer
    of FILE_SLASH_STATE:
      if has and (c == '/' or c == '\\'):
        #TODO if c == '\\' validation error
        state = FILE_HOST_STATE
      else:
        if base.issome and base.get.scheme == "file":
          url.host = base.get.host
          let bpath = base.get.path.ss
          if not input.substr(pointer).starts_with_windows_drive_letter() and bpath.len > 0 and bpath[0].is_normalized_windows_drive_letter():
            url.path.append(bpath[0])
          state = PATH_STATE
          dec pointer
    of FILE_HOST_STATE:
      if (not has or c in {'/', '\\', '?', '#'}):
        dec pointer
        if not override and buffer.is_windows_drive_letter:
          #TODO validation error
          state = PATH_STATE
        elif buffer == "":
          url.host = Host(domain: "").some
          if override:
            return
          state = PATH_START_STATE
        else:
          var host = parseHost(buffer)
          if host.isnone:
            return none(Url)
          if host.get.domain == "localhost":
            host.get.domain = ""
          url.host = host
          if override:
            return
          buffer = ""
          state = PATH_START_STATE
      else:
        buffer &= c
    of PATH_START_STATE:
      if url.is_special:
        #TODO if c == '\\' validation error
        state = PATH_STATE
        if not has or c notin {'/', '\\'}:
          dec pointer
      elif not override and has and c == '?':
        url.query = "".some
        state = QUERY_STATE
      elif not override and has and c == '#':
        url.fragment = "".some
        state = FRAGMENT_STATE
      elif has:
        state = PATH_STATE
        if c != '/':
          dec pointer
      elif override and url.host.isnone:
        url.path.append("")
    of PATH_STATE:
      if not has or c == '/' or (url.is_special and c == '\\') or
          (not override and c in {'?', '#'}):
        #TODO if url.is_special and c == '\\' validation error
        let slash_cond = not has or (c != '/' and not (url.is_special and c == '\\'))
        if buffer.is_double_dot_path_segment:
          url.shorten_path()
          if slash_cond:
            url.path.append("")
        elif buffer.is_single_dot_path_segment and slash_cond:
          url.path.append("")
        elif not buffer.is_single_dot_path_segment:
          if url.scheme == "file" and url.path.is_empty and buffer.is_windows_drive_letter:
            buffer[1] = ':'
          url.path.append(buffer)
        buffer = ""
        if has:
          if c == '?':
            url.query = "".some
            state = QUERY_STATE
          elif c == '#':
            url.fragment = "".some
            state = FRAGMENT_STATE
      else:
        #TODO If c is not a URL code point and not U+0025 (%), validation error.
        #TODO If c is U+0025 (%) and remaining does not start with two ASCII hex digits, validation error.
        buffer.percentEncode(c, PathPercentEncodeSet)
    of OPAQUE_PATH_STATE:
      if has:
        if c == '?':
          url.query = "".some
          state = QUERY_STATE
        elif c == '#':
          url.fragment = "".some
          state = FRAGMENT_STATE
        else:
          #TODO If c is not the EOF code point, not a URL code point, and not U+0025 (%), validation error.
          #TODO If c is U+0025 (%) and remaining does not start with two ASCII hex digits, validation error.
          url.path.append(percentEncode(c, ControlPercentEncodeSet))
    of QUERY_STATE:
      #TODO encoding
      if not has or (not override and c == '#'):
        let querypercentencodeset = if url.is_special: SpecialQueryPercentEncodeSet else: QueryPercentEncodeSet
        url.query.get.percentEncode(buffer, querypercentencodeset)
        buffer = ""
        if has and c == '#':
          url.fragment = "".some
          state = FRAGMENT_STATE
      elif has:
        #TODO If c is not a URL code point and not U+0025 (%), validation error.
        #TOOD If c is U+0025 (%) and remaining does not start with two ASCII hex digits, validation error.
        buffer &= c
    of FRAGMENT_STATE:
      if has:
        #TODO If c is not a URL code point and not U+0025 (%), validation error.
        #TOOD If c is U+0025 (%) and remaining does not start with two ASCII hex digits, validation error.
        url.fragment.get.percentEncode(c, FragmentPercentEncodeSet)
    inc pointer
  return url.some

func anchor*(url: Url): string =
  if url.fragment.issome:
    return url.fragment.get
  return ""

proc parseUrl*(input: string, base = none(Url), url: var Url, override: bool = false): Option[Url] =
  var url = basicParseUrl(input, base, url, override)
  if url.isnone:
    return url
  if url.get.scheme != "blob":
    return url
  url.get.blob = BlobUrlEntry().some
  return url

proc parseUrl*(input: string, base = none(Url), override: bool = false): Option[Url] =
  var url = Url().some
  url = basicParseUrl(input, base, url.get, override)
  if url.isnone:
    return url
  if url.get.scheme != "blob":
    return url
  url.get.blob = BlobUrlEntry().some
  return url

func serializeip(ipv4: uint32): string =
  var n = ipv4
  for i in 1..4:
    result = $(n mod 256) & result
    if i != 4:
      result = '.' & result
    n = n.floorDiv 256u32
  assert n == 0

func findZeroSeq(ipv6: array[8, uint16]): int =
  var maxi = -1
  var maxn = 0
  var newi = -1
  var newn = 1
  for i in low(ipv6)..high(ipv6):
    if ipv6[i] == 0:
      inc newn
      if newi == -1:
        newi = i
    else:
      if newn > maxn:
        maxn = newn
        maxi = newi
      newn = 0
      newi = -1
  if newn > maxn:
    return newi
  return maxi

func serializeip(ipv6: array[8, uint16]): string =
  let compress = findZeroSeq(ipv6)
  var ignore0 = false
  for i in low(ipv6)..high(ipv6):
    if ignore0:
      if ipv6[i] == 0: continue
      else: ignore0 = false
    if i == compress:
      if i == 0:
        result &= "::"
      else:
        result &= ':'
      ignore0 = true
      continue
    result &= toHex(ipv6[i])
    if i != high(ipv6):
      result &= ':'

func serialize(host: Host): string =
  if host.ipv4.issome:
    return serializeip(host.ipv4.get)
  if host.ipv6.issome:
    return "[" & serializeip(host.ipv6.get) & "]"
  if host.opaquehost != "":
    return host.opaquehost
  return host.domain

func serialize*(path: UrlPath): string {.inline.} =
  if path.opaque:
    return path.s
  for s in path.ss:
    result &= '/'
    result &= s

func serialize_unicode*(path: UrlPath): string {.inline.} =
  if path.opaque:
    return percentDecode(path.s)
  for s in path.ss:
    result &= '/'
    result &= percentDecode(s)

func serialize_unicode_dos*(path: UrlPath): string {.inline.} =
  if path.opaque:
    return percentDecode(path.s)
  var i = 0
  if i < path.ss.len:
    if path.ss[i].is_windows_drive_letter:
      result &= path.ss[i]
      inc i
  while i < path.ss.len:
    let s = path.ss[i]
    result &= '\\'
    result &= percentDecode(s)
    inc i

func serialize*(url: Url, excludefragment = false): string =
  result = url.scheme & ':'
  if url.host.issome:
    result &= "//"
    if url.includes_credentials:
      result &= url.username
      if url.password != "":
        result &= ':' & url.password
      result &= '@'
    result &= url.host.get.serialize
    if url.port.issome:
      result &= ':' & $url.port.get
  elif not url.path.opaque and url.path.ss.len > 1 and url.path.ss[0] == "":
    result &= "/."
  result &= url.path.serialize()
  if url.query.issome:
    result &= '?' & url.query.get
  if not excludefragment and url.fragment.issome:
    result &= '#' & url.fragment.get

func serialize*(url: Option[Url], excludefragment = false): string =
  if url.isnone:
    return ""
  return url.get.serialize()

func equals*(a, b: Url, excludefragment = false): bool =
  return a.serialize(excludefragment) == b.serialize(excludefragment)

func `$`*(url: Url): string {.inline.} = url.serialize()

func `$`*(path: UrlPath): string {.inline.} = path.serialize()
