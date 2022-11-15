# Interface for QuickJS libregexp.

import options
import unicode

import bindings/libregexp
import bindings/quickjs
import js/javascript
import strings/charset

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

var dummyRuntime = newJSRuntime()
var dummyContext = dummyRuntime.newJSContextRaw()

proc `=destroy`(regex: var Regex) =
  if regex.bytecode != nil:
    if regex.clone:
      dealloc(regex.bytecode)
    else:
      dummyRuntime.js_free_rt(regex.bytecode)
    regex.bytecode = nil

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

proc exec*(regex: Regex, str: string, start = 0, length = str.len): RegexResult =
  assert 0 <= start and start <= length, "Start: " & $start & ", length: " & $length & " str: " & $str

  let captureCount = lre_get_capture_count(regex.bytecode)

  var capture: ptr ptr uint8 = nil
  if captureCount > 0:
    capture = cast[ptr ptr uint8](alloc0(sizeof(ptr uint8) * captureCount * 2))

  var cstr = cstring(str)
  var ascii = true
  for c in str:
    if c > char(0x80):
      ascii = false
      break
  var ustr: string16
  if not ascii:
    if start != 0 or length != str.len:
      ustr = toUTF16(str.substr(start, length))
    else:
      ustr = toUTF16(str)
    cstr = cstring(ustr)

  let ret = lre_exec(capture, regex.bytecode,
                     cast[ptr uint8](cstr), cint(start),
                     cint(length), cint(not ascii), dummyContext)

  result.success = ret == 1 #TODO error handling? (-1)

  if result.success:
    var i = 0
    let cstrAddress = cast[int](cstr)
    while i < captureCount * sizeof(ptr uint8):
      let startPointerAddress = cast[int](capture) + i
      i += sizeof(ptr uint8)
      let endPointerAddress = cast[int](capture) + i
      i += sizeof(ptr uint8)
      let startPointer = cast[ptr ptr uint8](startPointerAddress)
      let endPointer = cast[ptr ptr uint8](endPointerAddress)
      let startAddress = cast[int](startPointer[])
      let endAddress = cast[int](endPointer[])
      var s = startAddress - cstrAddress
      var e = endAddress - cstrAddress
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
  dealloc(capture)
