# See https://url.spec.whatwg.org/#url-parsing.
import std/algorithm
import std/math
import std/options
import std/strutils
import std/tables
import std/unicode

import bindings/libunicode
import js/error
import js/javascript
import lib/punycode
import types/blob
import utils/luwrap
import utils/map
import utils/twtstr

include res/map/idna_gen

type
  URLState = enum
    SCHEME_START_STATE, SCHEME_STATE, NO_SCHEME_STATE, FILE_STATE,
    SPECIAL_RELATIVE_OR_AUTHORITY_STATE, SPECIAL_AUTHORITY_SLASHES_STATE,
    PATH_OR_AUTHORITY_STATE, OPAQUE_PATH_STATE, FRAGMENT_STATE, RELATIVE_STATE,
    SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE, AUTHORITY_STATE, PATH_STATE,
    RELATIVE_SLASH_STATE, QUERY_STATE, HOST_STATE, HOSTNAME_STATE,
    FILE_HOST_STATE, PORT_STATE, PATH_START_STATE, FILE_SLASH_STATE

  BlobURLEntry* = object
    obj: Blob #TODO blob urls

  URLPath* = object
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

  URLSearchParams* = ref object
    list*: seq[tuple[name, value: string]]
    url: Option[URL]

  URL* = ref URLObj
  URLObj* = object
    encoding: int #TODO
    scheme*: string
    username* {.jsget.}: string
    password* {.jsget.}: string
    port: Option[uint16]
    host: Option[Host]
    path*: URLPath
    query*: Option[string]
    fragment: Option[string]
    blob: Option[BlobURLEntry]
    searchParams* {.jsget.}: URLSearchParams

  Origin* = Option[tuple[
    scheme: string,
    host: Host,
    port: Option[uint16],
    domain: Option[string]
  ]]

jsDestructor(URL)
jsDestructor(URLSearchParams)

const EmptyPath = URLPath(opaque: true, s: "")
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
      return failure
    pointer += 2
    inc pieceindex
    compress = pieceindex
  while has:
    if pieceindex == 8:
      return failure
    if c == ':':
      if compress != -1:
        return failure
      inc pointer
      inc pieceindex
      compress = pieceindex
      continue
    var value: uint16 = 0
    var length = 0
    while length < 4 and has and c in AsciiHexDigit:
      value = value * 0x10 + uint16(c.hexValue)
      inc pointer
      inc length
    if has and c == '.':
      if length == 0:
        return failure
      pointer -= length
      if pieceindex > 6:
        return failure
      var numbersseen = 0
      while has:
        var ipv4piece = -1
        if numbersseen > 0:
          if c == '.' and numbersseen < 4:
            inc pointer
          else:
            return failure
        if not has or c notin Digits:
          return failure
        while has and c in Digits:
          if ipv4piece == -1:
            ipv4piece = c.decValue
          elif ipv4piece == 0:
            return failure
          else:
            ipv4piece = ipv4piece * 10 + c.decValue
          if ipv4piece > 255:
            return failure
          inc pointer
        address[pieceindex] = address[pieceindex] * 0x100 + uint16(ipv4piece)
        inc numbersseen
        if numbersseen == 2 or numbersseen == 4:
          inc pieceindex
      if numbersseen != 4:
        return failure
      break
    elif has:
      if c == ':':
        inc pointer
        if not has:
          return failure
      else:
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
    return failure
  return address.some

func parseIpv4Number(s: string): int =
  if s == "": return -1
  var input = s
  var R = 10
  if input.len >= 2 and input[0] == '0':
    if input[1] in {'x', 'X'}:
      input = input.substr(2)
      R = 16
    else:
      input = input.substr(1)
      R = 8
  if input == "":
    return 0

  var output = 0
  try:
    case R
    of 8: output = parseOctInt(input)
    of 10: output = parseInt(input)
    of 16: output = parseHexInt(input)
    else: discard
  except ValueError: return -1
  return output

func parseIpv4(input: string): Option[uint32] =
  var parts = input.split('.')
  if parts[^1] == "":
    if parts.len > 1:
      discard parts.pop()
  if parts.len > 4:
    return none(uint32)
  var numbers: seq[int]
  for i in low(parts)..high(parts):
    let part = parts[i]
    let num = parseIpv4Number(part)
    if num < 0:
      return none(uint32)
    if num > 255:
      if i != high(parts):
        return none(uint32)
    numbers.add(num)
  if numbers[^1] >= 256^(5-numbers.len):
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
  var o = ""
  for c in input:
    o.percentEncode(c, ControlPercentEncodeSet)
  return some(Host(opaquehost: o))

func endsInNumber(input: string): bool =
  var parts = input.split('.')
  if parts[^1] == "":
    if parts.len == 1: return false
    discard parts.pop()
  if parts.len == 0: return false
  var last = parts[^1]
  if last != "":
    if last.len == 2 and last[0] in Digits and last[1].toLowerAscii() == 'x':
      last = last.substr(2)
    for c in last:
      if c notin Digits:
        return false
    return true
  return false

type u32pair {.packed.} = object
  a: uint32
  b: uint32

func cmpRange(x: u32pair, y: uint32): int =
  if x.a > y:
    return 1
  elif x.b < y:
    return -1
  return 0

type
  IDNATableStatus = enum
    IDNA_VALID, IDNA_IGNORED, IDNA_MAPPED, IDNA_DEVIATION, IDNA_DISALLOWED

func getIdnaTableStatus(r: Rune): IDNATableStatus =
  let i = uint32(r)
  if i <= high(uint16):
    let u = uint16(i)
    if u in IgnoredLow:
      return IDNA_IGNORED
    if u in DisallowedLow:
      return IDNA_DISALLOWED
    for item in Deviation:
      if item[0] == u:
        return IDNA_DEVIATION
    if DisallowedRangesLow.isInRange(u):
      return IDNA_DISALLOWED
    if MappedMapLow.isInMap(u):
      return IDNA_MAPPED
  else:
    if i in IgnoredHigh:
      return IDNA_IGNORED
    if i in DisallowedHigh:
      return IDNA_DISALLOWED
    if DisallowedRangesHigh.isInRange(i):
      return IDNA_DISALLOWED
    if MappedMapHigh.isInMap(uint32(i)):
      return IDNA_MAPPED
  return IDNA_VALID

func getIdnaMapped(r: Rune): string =
  let i = uint32(r)
  if i <= high(uint16):
    let u = uint16(i)
    let n = MappedMapLow.searchInMap(u)
    if n != -1:
      return $MappedMapLow[n].mapped
  let n = MappedMapHigh.searchInMap(i)
  return $MappedMapHigh[n].mapped

func getDeviationMapped(r: Rune): string =
  for item in Deviation:
    if item[0] == uint16(r):
      return $item[1]
  return ""

func processIdna(str: string, checkhyphens, checkbidi, checkjoiners,
    transitionalprocessing: bool): Option[string] =
  var mapped: seq[Rune]
  for r in str.runes():
    let status = getIdnaTableStatus(r)
    case status
    of IDNA_DISALLOWED: return none(string) #error
    of IDNA_IGNORED: discard
    of IDNA_MAPPED: mapped &= getIdnaMapped(r).toRunes()
    of IDNA_DEVIATION:
      if transitionalprocessing:
        mapped &= getDeviationMapped(r).toRunes()
      else:
        mapped &= r
    of IDNA_VALID: mapped &= r
  if mapped.len == 0: return
  mapped.mnormalize()
  var cr: CharRange
  {.cast(noSideEffect).}:
    cr_init(addr cr, nil, passRealloc)
    let r = unicode_general_category(addr cr, "Mark")
    assert r == 0
  var labels: seq[string]
  for label in ($mapped).split('.'):
    if label.startsWith("xn--"):
      try:
        let s = punycode.decode(label.substr("xn--".len))
        let x0 = s.toRunes()
        let x1 = normalize(x0)
        if x0 != x1:
          return none(string) #error
        if checkhyphens:
          if s.len >= 4 and s[2] == '-' and s[3] == '-':
            return none(string) #error
          if s.len > 0 and s[0] == '-' and s[^1] == '-':
            return none(string) #error
        if x0.len > 0:
          let cps = cast[ptr UncheckedArray[u32pair]](cr.points)
          let c = cast[uint32](x0[0])
          if binarySearch(toOpenArray(cps, 0, cr.len div 2 - 1), c, cmpRange) != -1:
            return none(string) #error
        for r in x0:
          if r == Rune('.'):
            return none(string) #error
          let status = getIdnaTableStatus(r)
          case status
          of IDNA_DISALLOWED, IDNA_IGNORED, IDNA_MAPPED:
            return none(string) #error
          of IDNA_DEVIATION:
            if transitionalprocessing:
              return none(string) #error
          of IDNA_VALID: discard
          #TODO check joiners
          #TODO check bidi
        labels.add(s)
      except PunyError:
        return none(string) #error
    else:
      labels.add(label)
  cr_free(addr cr)
  return some(labels.join('.'))

func unicodeToAscii(s: string, checkhyphens, checkbidi, checkjoiners,
    transitionalprocessing, verifydnslength: bool): Option[string] =
  let processed = s.processIdna(checkhyphens, checkbidi, checkjoiners,
    transitionalprocessing)
  if processed.isnone:
    return none(string) #error
  var labels: seq[string]
  var all = 0
  for label in processed.get.split('.'):
    if not label.isAscii():
      try:
        let converted = "xn--" & punycode.encode(label)
        labels.add(converted)
      except PunyError:
        return none(string) #error
    else:
      labels.add(label)
    if verifydnslength:
      let rl = labels[^1].runeLen()
      if rl notin 1..63:
        return none(string)
      all += rl
  if verifydnslength:
    if all notin 1..253:
      return none(string) #error
  return some(labels.join('.'))

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
    if result.isNone or result.get == "":
      return none(string)
    return result
  else:
    return some(domain.toLowerAscii())

func parseHost(input: string, special: bool): Option[Host] =
  if input.len == 0: return
  if input[0] == '[':
    if input[^1] != ']':
      return none(Host)
    return Host(ipv6: parseIpv6(input.substr(1, input.high - 1))).some
  if not special:
    return opaqueParseHost(input)
  let domain = percentDecode(input)
  let asciiDomain = domain.domainToAscii()
  if asciiDomain.isNone:
    return none(Host)
  for c in asciiDomain.get:
    if c in ForbiddenHostChars:
      return none(Host)
  if asciiDomain.get.len > 0 and asciiDomain.get.endsInNumber():
    let ipv4 = parseIpv4(asciiDomain.get)
    return Host(ipv4: ipv4).some
  return Host(domain: asciiDomain.get).some

func isempty(host: Host): bool =
  return host.domain == "" and host.ipv4.isNone and host.ipv6.isNone and
    host.opaquehost == ""

proc shorten_path(url: URL) {.inline.} =
  assert not url.path.opaque

  if url.scheme == "file" and url.path.ss.len == 1 and
      url.path.ss[0].len == 2 and url.path.ss[0][0] in AsciiAlpha and
      url.path.ss[0][1] == ':':
    return
  if url.path.ss.len > 0:
    discard url.path.ss.pop()

proc append(path: var URLPath, s: string) =
  if path.opaque:
    path.s &= s
  else:
    path.ss.add(s)

template includes_credentials(url: URL): bool =
  url.username != "" or url.password != ""

template is_windows_drive_letter(s: string): bool =
  s.len == 2 and s[0] in AsciiAlpha and (s[1] == ':' or s[1] == '|')

template canHaveUsernamePasswordPort(url: URL): bool =
  url.host.isSome and url.host.get.serialize() != "" and url.scheme != "file"

#TODO encoding
proc basicParseURL*(input: string, base = none(URL), url: URL = URL(),
    stateOverride = none(URLState)): Option[URL] =
  const NoStrip = AllChars - C0Controls - {' '}
  let starti0 = input.find(NoStrip)
  let starti = if starti0 == -1: 0 else: starti0
  let endi0 = input.rfind(NoStrip)
  let endi = if endi0 == -1: input.len else: endi0 + 1
  var buffer = ""
  var atsignseen = false
  var insidebrackets = false
  var passwordtokenseen = false
  var pointer = starti
  let override = stateOverride.isSome
  var state = SCHEME_START_STATE
  if override:
    state = stateOverride.get

  template c(i = 0): char = input[pointer + i]
  template has(i = 0): bool = (pointer + i < endi)
  template is_special(url: URL): bool = url.scheme in SpecialSchemes
  template default_port(url: URL): Option[uint16] = SpecialSchemes[url.scheme]
  template start_over() =
    pointer = starti
    continue # skip pointer inc
  template starts_with_windows_drive_letter(i: int): bool =
    i + 2 <= endi and input[i] in AsciiAlpha and input[i + 1] in {':', '|'}
  template is_normalized_windows_drive_letter(s: string): bool =
    s.len == 2 and s[0] in AsciiAlpha and s[1] == ':'
  template is_double_dot_path_segment(s: string): bool =
    s == ".." or s.equalsIgnoreCase(".%2e") or s.equalsIgnoreCase("%2e.") or
      s.equalsIgnoreCase("%2e%2e")
  template is_single_dot_path_segment(s: string): bool =
    s == "." or s.equalsIgnoreCase("%2e")
  template is_empty(path: URLPath): bool = path.ss.len == 0

  while pointer <= endi:
    assert pointer >= starti
    if pointer < endi and input[pointer] in {'\n', '\t'}:
      inc pointer
      continue
    case state
    of SCHEME_START_STATE:
      if has and c.isAlphaAscii():
        buffer &= c.toLowerAscii()
        state = SCHEME_STATE
      elif not override:
        state = NO_SCHEME_STATE
        dec pointer
      else:
        return none(URL)
    of SCHEME_STATE:
      if has and c in AsciiAlphaNumeric + {'+', '-', '.'}:
        buffer &= c.toLowerAscii()
      elif has and c == ':':
        if override:
          if url.scheme in SpecialSchemes and buffer notin SpecialSchemes:
            return url.some
          if url.scheme notin SpecialSchemes and buffer in SpecialSchemes:
            return url.some
          if (url.includes_credentials or url.port.isSome) and
              buffer == "file":
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
          state = FILE_STATE
        elif url.is_special and not base.isNone and
            base.get.scheme == url.scheme:
          state = SPECIAL_RELATIVE_OR_AUTHORITY_STATE
        elif url.is_special:
          state = SPECIAL_AUTHORITY_SLASHES_STATE
        elif has(1) and c(1) == '/':
          state = PATH_OR_AUTHORITY_STATE
          inc pointer
        else:
          url.path = EmptyPath
          state = OPAQUE_PATH_STATE
      elif not override:
        buffer = ""
        state = NO_SCHEME_STATE
        start_over
      else:
        return none(URL)
    of NO_SCHEME_STATE:
      if base.isNone or base.get.path.opaque and (not has or c != '#'):
        return none(URL)
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
        state = RELATIVE_STATE
        dec pointer
    of PATH_OR_AUTHORITY_STATE:
      if has and c == '/':
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
        state = SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE
        dec pointer
    of SPECIAL_AUTHORITY_IGNORE_SLASHES_STATE:
      if not has or c notin {'/', '\\'}:
        state = AUTHORITY_STATE
        dec pointer
    of AUTHORITY_STATE:
      if has and c == '@':
        if atsignseen:
          buffer = "%40" & buffer
        atsignseen = true
        for c in buffer:
          if c == ':' and not passwordtokenseen:
            passwordtokenseen = true
            continue
          if passwordtokenseen:
            url.password.percentEncode(c, UserInfoPercentEncodeSet)
          else:
            url.username.percentEncode(c, UserInfoPercentEncodeSet)
        buffer = ""
      elif not has or c in {'/', '?', '#'} or (url.is_special and c == '\\'):
        if atsignseen and buffer == "":
          return none(URL)
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
          return none(URL)
        let host = parseHost(buffer, url.is_special)
        if host.isNone:
          return none(URL)
        url.host = host
        buffer = ""
        state = PORT_STATE
      elif (not has or c in {'/', '?', '#'}) or
        (url.is_special and c == '\\'):
        dec pointer
        if url.is_special and buffer == "":
          return none(URL)
        elif override and buffer == "" and
            (url.includes_credentials or url.port.isSome):
          return
        let host = parseHost(buffer, url.is_special)
        if host.isNone:
          return none(URL)
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
          if i.isNone or i.get notin 0..65535:
            return none(URL)
          let port = cast[uint16](i.get).some
          url.port = if url.is_special and url.default_port == port:
            none(uint16)
          else:
            port
          buffer = ""
        if override:
          return
        state = PATH_START_STATE
        dec pointer
      else:
        return none(URL)
    of FILE_STATE:
      url.scheme = "file"
      url.host = EmptyHost
      if has and (c == '/' or c == '\\'):
        state = FILE_SLASH_STATE
      elif base.isSome and base.get.scheme == "file":
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
            if not starts_with_windows_drive_letter(pointer):
              url.shorten_path()
            else:
              url.path.ss.setLen(0)
            state = PATH_STATE
            dec pointer
      else:
        state = PATH_STATE
        dec pointer
    of FILE_SLASH_STATE:
      if has and (c == '/' or c == '\\'):
        state = FILE_HOST_STATE
      else:
        if base.isSome and base.get.scheme == "file":
          url.host = base.get.host
          let bpath = base.get.path.ss
          if not starts_with_windows_drive_letter(pointer) and
              bpath.len > 0 and bpath[0].is_normalized_windows_drive_letter():
            url.path.append(bpath[0])
        state = PATH_STATE
        dec pointer
    of FILE_HOST_STATE:
      if (not has or c in {'/', '\\', '?', '#'}):
        dec pointer
        if not override and buffer.is_windows_drive_letter:
          state = PATH_STATE
        elif buffer == "":
          url.host = Host(domain: "").some
          if override:
            return
          state = PATH_START_STATE
        else:
          var host = parseHost(buffer, url.is_special)
          if host.isNone:
            return none(URL)
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
      elif override and url.host.isNone:
        url.path.append("")
    of PATH_STATE:
      if not has or c == '/' or (url.is_special and c == '\\') or
          (not override and c in {'?', '#'}):
        let slash_cond = not has or (c != '/' and not url.is_special and c != '\\')
        if buffer.is_double_dot_path_segment:
          url.shorten_path()
          if slash_cond:
            url.path.append("")
        elif buffer.is_single_dot_path_segment and slash_cond:
          url.path.append("")
        elif not buffer.is_single_dot_path_segment:
          if url.scheme == "file" and url.path.is_empty and
              buffer.is_windows_drive_letter:
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
          url.path.append(percentEncode(c, ControlPercentEncodeSet))
    of QUERY_STATE:
      #TODO encoding
      if not has or (not override and c == '#'):
        let querypercentencodeset = if url.is_special:
          SpecialQueryPercentEncodeSet
        else:
          QueryPercentEncodeSet
        url.query.get.percentEncode(buffer, querypercentencodeset)
        buffer = ""
        if has and c == '#':
          url.fragment = "".some
          state = FRAGMENT_STATE
      elif has:
        buffer &= c
    of FRAGMENT_STATE:
      if has:
        url.fragment.get.percentEncode(c, FragmentPercentEncodeSet)
    inc pointer
  return url.some

func anchor*(url: URL): string =
  if url.fragment.isSome:
    return url.fragment.get
  return ""

proc parseURL*(input: string, base = none(URL), override = none(URLState)):
    Option[URL] =
  let url = basicParseURL(input, base, stateOverride = override)
  if url.isNone:
    return url
  if url.get.scheme == "blob":
    url.get.blob = some(BlobURLEntry())
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
    result &= toHexLower(ipv6[i])
    if i != high(ipv6):
      result &= ':'

func serialize(host: Host): string =
  if host.ipv4.isSome:
    return serializeip(host.ipv4.get)
  if host.ipv6.isSome:
    return "[" & serializeip(host.ipv6.get) & "]"
  if host.opaquehost != "":
    return host.opaquehost
  return host.domain

func serialize*(path: URLPath): string {.inline.} =
  if path.opaque:
    return path.s
  for s in path.ss:
    result &= '/'
    result &= s

when defined(windows) or defined(OS2) or defined(DOS):
  func serialize_unicode_dos(path: URLPath): string =
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
  func serialize_unicode*(path: URLPath): string =
    return path.serialize_unicode_dos()
else:
  func serialize_unicode*(path: URLPath): string =
    if path.opaque:
      return percentDecode(path.s)
    for s in path.ss:
      result &= '/'
      result &= percentDecode(s)

func serialize*(url: URL, excludefragment = false, excludepassword = false):
    string =
  result = url.scheme & ':'
  if url.host.isSome:
    result &= "//"
    if url.includes_credentials:
      result &= url.username
      if not excludepassword and url.password != "":
        result &= ':' & url.password
      result &= '@'
    result &= url.host.get.serialize
    if url.port.isSome:
      result &= ':' & $url.port.get
  elif not url.path.opaque and url.path.ss.len > 1 and url.path.ss[0] == "":
    result &= "/."
  result &= url.path.serialize()
  if url.query.isSome:
    result &= '?' & url.query.get
  if not excludefragment and url.fragment.isSome:
    result &= '#' & url.fragment.get

func serialize*(url: Option[URL], excludefragment = false): string =
  if url.isNone:
    return ""
  return url.get.serialize()

func equals*(a, b: URL, excludefragment = false): bool =
  return a.serialize(excludefragment) == b.serialize(excludefragment)

func `$`*(url: URL): string {.jsfunc.} = url.serialize()

func `$`*(path: URLPath): string {.inline.} = path.serialize()

func href(url: URL): string {.jsfget.} =
  return $url

func toJSON(url: URL): string {.jsfget.} =
  return $url

# from a to b
proc cloneInto(a, b: URL) =
  b[] = a[]
  if a.searchParams != nil: #TODO ideally this would never be false
    b.searchParams = URLSearchParams()
    b.searchParams[] = a.searchParams[]
    b.searchParams.url = some(b)

proc newURL*(url: URL): URL =
  result = URL()
  url.cloneInto(result)

proc setHref(url: URL, s: string): Err[JSError] {.jsfset: "href".} =
  let purl = basicParseURL(s)
  if purl.isNone:
    return err(newTypeError(s & " is not a valid URL"))
  purl.get.cloneInto(url)

func isIP*(url: URL): bool =
  if url.host.isNone:
    return false
  let host = url.host.get
  return host.ipv4.isSome or host.ipv6.isSome

#https://url.spec.whatwg.org/#concept-urlencoded-serializer
proc parseApplicationXWWWFormUrlEncoded(input: string): seq[(string, string)] =
  for s in input.split('&'):
    if s == "":
      continue
    var name = ""
    var value = ""
    for i in 0..<s.len:
      if s[i] == '=':
        name = s.substr(0, i - 1)
        value = s.substr(i + 1)
        break
    if name == "":
      name = s
    for i in 0..<name.len:
      if name[i] == '+':
        name[i] = ' '
    for i in 0..<value.len:
      if value[i] == '+':
        value[i] = ' '
    result.add((percentDecode(name), percentDecode(value)))

#https://url.spec.whatwg.org/#concept-urlencoded-serializer
proc serializeApplicationXWWWFormUrlEncoded*(kvs: seq[(string, string)],
    spaceAsPlus = true): string =
  for it in kvs:
    let (name, value) = it
    if result != "":
      result &= '&'
    result.percentEncode(name, ApplicationXWWWFormUrlEncodedSet, spaceAsPlus)
    result &= '='
    result.percentEncode(value, ApplicationXWWWFormUrlEncodedSet, spaceAsPlus)

proc initURLSearchParams(params: URLSearchParams, init: string) =
  params.list = parseApplicationXWWWFormUrlEncoded(init)

proc newURLSearchParams[
      T: seq[(string, string)]|
      Table[string, string]|
      string
    ](init: T = ""): URLSearchParams {.jsctor.} =
  result = URLSearchParams()
  when T is seq[(string, string)]:
    result.list = init
  elif T is Table[string, string]:
    for k, v in init:
      result.list.add((k, v))
  elif T is string:
    let init = if init.len > 0 and init[0] == '?':
      init.substr(1)
    else:
      init
    result.initURLSearchParams(init)

proc `$`*(params: URLSearchParams): string {.jsfunc.} =
  return serializeApplicationXWWWFormUrlEncoded(params.list)

proc update(params: URLSearchParams) =
  if params.url.isNone:
    return
  let serializedQuery = $params
  if serializedQuery == "":
    params.url.get.query = none(string)
  else:
    params.url.get.query = some(serializedQuery)

proc append*(params: URLSearchParams, name: string, value: string) {.jsfunc.} =
  params.list.add((name, value))
  params.update()

proc delete*(params: URLSearchParams, name: string) {.jsfunc.} =
  for i in countdown(params.list.high, 0):
    if params.list[i][0] == name:
      params.list.delete(i)

proc get*(params: URLSearchParams, name: string): Option[string] {.jsfunc.} =
  for it in params.list:
    if it[0] == name:
      return some(it[1])

proc getAll*(params: URLSearchParams, name: string): seq[string] {.jsfunc.} =
  for it in params.list:
    if it[0] == name:
      result.add(it[1])

proc set*(params: URLSearchParams, name: string, value: string) {.jsfunc.} =
  var first = true
  for i in 0..params.list.high:
    if params.list[i][0] == name:
      if first:
        first = false
        params.list[i][1] = value

proc parseAPIURL(s: string, base: Option[string]): JSResult[URL] =
  let baseURL = if base.isSome:
    let x = parseURL(base.get)
    if x.isNone:
      return err(newTypeError(base.get & " is not a valid URL"))
    x
  else:
    none(URL)
  let url = parseURL(s, baseURL)
  if url.isNone:
    return err(newTypeError(s & " is not a valid URL"))
  return ok(url.get)

proc newURL*(s: string, base: Option[string] = none(string)):
    JSResult[URL] {.jsctor.} =
  let url = ?parseAPIURL(s, base)
  url.searchParams = newURLSearchParams()
  url.searchParams.url = some(url)
  url.searchParams.initURLSearchParams(url.query.get(""))
  return ok(url)

proc origin0*(url: URL): Origin =
  case url.scheme
  of "blob":
    if url.blob.isSome:
      #TODO
      discard
    let pathURL = parseURL($url.path)
    if pathURL.isNone:
      return # opaque
    return pathURL.get.origin0
  of "ftp", "http", "https", "ws", "wss":
    return some((url.scheme, url.host.get, url.port, none(string)))
  of "file":
    #???
    return # opaque
  else:
    return # opaque

proc `==`*(a, b: Origin): bool =
  if a.isNone or b.isNone: return false
  return a.get == b.get

proc `$`*(origin: Origin): string =
  if origin.isNone:
    return "null"
  let origin = origin.get
  result = origin.scheme
  result &= "://"
  result &= origin.host.serialize()
  if origin.port.isSome:
    result &= ':'
    result &= $origin.port.get

proc origin*(url: URL): string {.jsfget.} =
  return $url.origin0

proc protocol*(url: URL): string {.jsfget.} =
  return url.scheme & ':'

proc setProtocol*(url: URL, s: string) {.jsfset: "protocol".} =
  discard basicParseURL(s & ':', url = url,
    stateOverride = some(SCHEME_START_STATE))

proc username(url: URL, username: string) {.jsfset.} =
  if not url.canHaveUsernamePasswordPort:
    return
  url.username = username.percentEncode(UserInfoPercentEncodeSet)

proc password(url: URL, password: string) {.jsfset.} =
  if not url.canHaveUsernamePasswordPort:
    return
  url.password = password.percentEncode(UserInfoPercentEncodeSet)

proc host*(url: URL): string {.jsfget.} =
  if url.host.isNone:
    return ""
  if url.port.isNone:
    return url.host.get.serialize()
  return url.host.get.serialize() & ':' & $url.port.get

proc setHost*(url: URL, s: string) {.jsfset: "host".} =
  if url.path.opaque:
    return
  discard basicParseURL(s, url = url, stateOverride = some(HOST_STATE))

proc hostname*(url: URL): string {.jsfget.} =
  if url.host.isNone:
    return ""
  return url.host.get.serialize()

proc setHostname*(url: URL, s: string) {.jsfset: "hostname".} =
  if url.path.opaque:
    return
  discard basicParseURL(s, url = url, stateOverride = some(HOSTNAME_STATE))

proc port*(url: URL): string {.jsfget.} =
  if url.port.isSome:
    return $url.port.get

proc setPort*(url: URL, s: string) {.jsfset: "port".} =
  if not url.canHaveUsernamePasswordPort:
    return
  if s == "":
    url.port = none(uint16)
  else:
    discard basicParseURL(s, url = url, stateOverride = some(PORT_STATE))

proc pathname*(url: URL): string {.jsfget.} =
  return url.path.serialize()

proc setPathname*(url: URL, s: string) {.jsfset: "pathname".} =
  if url.path.opaque:
    return
  url.path.ss.setLen(0)
  discard basicParseURL(s, url = url, stateOverride = some(PATH_START_STATE))

proc search*(url: URL): string {.jsfget.} =
  if url.query.get("") == "":
    return ""
  return "?" & url.query.get

proc setSearch*(url: URL, s: string) {.jsfset: "search".} =
  if s == "":
    url.query = none(string)
    url.searchParams.list.setLen(0)
    return
  let s = if s[0] == '?': s.substr(1) else: s
  url.query = some("")
  discard basicParseURL(s, url = url, stateOverride = some(QUERY_STATE))
  url.searchParams.list = parseApplicationXWWWFormUrlEncoded(s)

proc hash*(url: URL): string {.jsfget.} =
  if url.fragment.get("") == "":
    return ""
  return '#' & url.fragment.get

proc setHash*(url: URL, s: string) {.jsfset: "hash".} =
  if s == "":
    url.fragment = none(string)
    return
  let s = if s[0] == '#': s.substr(1) else: s
  url.fragment = some("")
  discard basicParseURL(s, url = url, stateOverride = some(FRAGMENT_STATE))

proc canParse(url: string, base: Option[string]): bool {.jsstfunc: "URL".} =
  return parseAPIURL(url, base).isSome

proc addURLModule*(ctx: JSContext) =
  ctx.registerType(URL)
  ctx.registerType(URLSearchParams)
