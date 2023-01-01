# Interface for QuickJS libregexp.

import options
import unicode

import bindings/libregexp
import bindings/quickjs
import js/javascript
import utils/twtstr

export
  LRE_FLAG_GLOBAL,
  LRE_FLAG_IGNORECASE,
  LRE_FLAG_MULTILINE,
  LRE_FLAG_DOTALL,
  LRE_FLAG_UTF16,
  LRE_FLAG_STICKY

type
  Regex* = object
    bytecode*: ptr uint8
    plen*: cint
    clone*: bool
    buf*: string

  RegexResult* = object
    success*: bool
    captures*: seq[tuple[s, e: int]] # start, end

  RegexReplace* = object
    regex: Regex
    rule: string
    global: bool

type string16 = distinct string

# Convert a UTF-8 string to UTF-16.
# Note: this doesn't check for (invalid) UTF-8 containing surrogates.
proc toUTF16(s: string): string16 =
  var res = ""
  var i = 0
  template put16(c: uint16) =
    res.setLen(res.len + 2)
    res[i] = cast[char](c)
    inc i
    res[i] = cast[char](c shr 8)
    inc i
  for r in s.runes:
    var c = uint32(r)
    if c < 0x10000: # ucs-2
      put16 uint16(c)
    elif c <= 0x10FFFF: # surrogate
      c -= 0x10000
      put16 uint16((c shr 10) + 0xD800)
      put16 uint16((c and 0x3FF) + 0xDC00)
    else: # invalid
      put16 uint16(0xFFFD)
  result = string16(res)

func len(s: string16): int {.borrow.}
func `[]`(s: string16, i: int): char = string(s)[i]
func `[]`(s: string16, i: BackwardsIndex): char = string(s)[i]

template fastRuneAt(s: string16, i: int, r: untyped, doInc = true, be = false) =
  if i + 1 == s.len: # unmatched byte
    when doInc: inc i
    r = Rune(0xFFFD)
  else:
    when be:
      var c1: uint32 = (uint32(s[i]) shl 8) + uint32(s[i + 1])
    else:
      var c1: uint32 = uint32(s[i]) + (uint32(s[i + 1]) shl 8)
    if c1 >= 0xD800 or c1 < 0xDC00:
      if i + 2 == s.len or i + 3 == s.len:
        when doInc: i += 2
        r = Rune(c1) # unmatched surrogate
      else:
        when be:
          var c2: uint32 = (uint32(s[i + 2]) shl 8) + uint32(s[i + 3])
        else:
          var c2: uint32 = uint32(s[i + 2]) + (uint32(s[i + 3]) shl 8)
        if c2 >= 0xDC00 and c2 < 0xE000:
          r = Rune((((c1 and 0x3FF) shl 10) or (c2 and 0x3FF)) + 0x10000)
          when doInc: i += 4
        else:
          r = Rune(c1) # unmatched surrogate
          when doInc: i += 2
    else:
      r = Rune(c1) # ucs-2
      when doInc: i += 2

var dummyRuntime = newJSRuntime()
var dummyContext = dummyRuntime.newJSContextRaw()

proc `=destroy`*(regex: var Regex) =
  if regex.bytecode != nil:
    if regex.clone:
      dealloc(regex.bytecode)
    else:
      dummyRuntime.js_free_rt(regex.bytecode)
    regex.bytecode = nil

proc `=copy`*(dest: var Regex, source: Regex) =
  if dest.bytecode != source.bytecode:
    `=destroy`(dest)
    wasMoved(dest)
    dest.bytecode = cast[ptr uint8](alloc(source.plen))
    copyMem(dest.bytecode, source.bytecode, source.plen)
    dest.clone = true
    dest.buf = source.buf
    dest.plen = source.plen

func `$`*(regex: Regex): string =
  regex.buf

proc compileRegex*(buf: string, flags: int): Option[Regex] =
  var regex: Regex
  var error_msg_size = 64
  var error_msg = cast[cstring](alloc0(error_msg_size))
  let bytecode = lre_compile(addr regex.plen, error_msg, cint(error_msg_size), cstring(buf), csize_t(buf.len), cint(flags), dummyContext)
  regex.buf = buf
  if error_msg != nil:
    #TODO error handling?
    dealloc(error_msg)
    error_msg = nil
  if bytecode == nil:
    return none(Regex) # Failed to compile.
  regex.bytecode = bytecode
  return some(regex)

proc compileSearchRegex*(str: string): Option[Regex] =
  # Parse any applicable flags in regex/<flags>. The last forward slash is
  # dropped when <flags> is empty, and interpreted as a character when the
  # flags are is invalid.

  var i = str.high
  var flagsi = -1
  while i >= 0:
    case str[i]
    of '/':
      flagsi = i
      break
    of 'i', 'm', 's', 'u': discard
    else: break # invalid flag
    dec i

  var flags = LRE_FLAG_GLOBAL # for easy backwards matching

  if flagsi == -1:
    return compileRegex(str, flags)

  for i in flagsi..str.high:
    case str[i]
    of '/': discard
    of 'i': flags = flags or LRE_FLAG_IGNORECASE
    of 'm': flags = flags or LRE_FLAG_MULTILINE
    of 's': flags = flags or LRE_FLAG_DOTALL
    of 'u': flags = flags or LRE_FLAG_UTF16
    else: assert false
  return compileRegex(str.substr(0, flagsi - 1), flags)

proc exec*(regex: Regex, str: string, start = 0, length = -1, nocaps = false): RegexResult =
  let length = if length == -1:
    str.len
  else:
    length
  assert 0 <= start and start <= length, "Start: " & $start & ", length: " & $length & " str: " & $str

  let captureCount = lre_get_capture_count(regex.bytecode)
  var capture: ptr ptr uint8 = nil
  if captureCount > 0:
    capture = cast[ptr ptr uint8](alloc0(sizeof(ptr uint8) * captureCount * 2))
  var cstr = cstring(str)
  let ascii = str.isAscii()
  var ustr: string16
  if not ascii:
    if start != 0 or length != str.len:
      ustr = toUTF16(str.substr(start, length))
    else:
      ustr = toUTF16(str)
    cstr = cstring(ustr)
  let flags = lre_get_flags(regex.bytecode)
  var start = start
  while true:
    let ret = lre_exec(capture, regex.bytecode,
                       cast[ptr uint8](cstr), cint(start),
                       cint(length), cint(not ascii), dummyContext)
    if ret != 1: #TODO error handling? (-1)
      break
    result.success = true
    if captureCount == 0 or nocaps:
      break
    let cstrAddress = cast[int](cstr)
    start = cast[ptr int](cast[int](capture) + sizeof(ptr uint8))[] - cstrAddress
    var i = 0
    while i < captureCount * sizeof(ptr uint8):
      let s = cast[ptr int](cast[int](capture) + i)[] - cstrAddress
      i += sizeof(ptr uint8)
      let e = cast[ptr int](cast[int](capture) + i)[] - cstrAddress
      i += sizeof(ptr uint8)
      if ascii:
        result.captures.add((s, e))
      else:
        var s8 = 0
        var e8 = 0
        var i = 0
        var r: Rune
        while i < s and i < ustr.len:
          fastRuneAt(ustr, i, r)
          let si = r.size()
          s8 += si
          e8 += si
        while i < e and i < ustr.len:
          fastRuneAt(ustr, i, r)
          e8 += r.size()
        result.captures.add((s8, e8))
    if (flags and LRE_FLAG_GLOBAL) != 1:
      break
  if captureCount > 0:
    dealloc(capture)

proc match*(regex: Regex, str: string, start = 0, length = str.len): bool =
  return regex.exec(str, start, length, nocaps = true).success
