# Interface for QuickJS libregexp.

import options

import bindings/libregexp
import bindings/quickjs
import js/javascript

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

  RegexResult* = object
    success*: bool
    captures*: seq[tuple[s, e: int]] # start, end

var dummyRuntime = newJSRuntime()
var dummyContext = dummyRuntime.newJSContextRaw()

proc `=destroy`(regex: var Regex) =
  if regex.bytecode != nil:
    dummyRuntime.js_free_rt(regex.bytecode)
    regex.bytecode = nil

proc compileRegex*(buf: string, flags: int): Option[Regex] =
  var regex: Regex
  var len: cint
  var error_msg_size = 64
  var error_msg = cast[cstring](alloc0(error_msg_size))
  let bytecode = lre_compile(addr len, error_msg, cint(error_msg_size), cstring(buf), csize_t(buf.len), cint(flags), dummyContext)
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
      if i > 0 and str[i - 1] == '\\': break # escaped
      flagsi = i
      break
    of 'i', 'm', 's': discard
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
    else: assert false
  return compileRegex(str.substr(0, flagsi - 1), flags)

proc exec*(regex: Regex, str: string, start = 0): RegexResult =
  assert 0 <= start and start <= str.len
  let cstr = cstring(str)
  let captureCount = lre_get_capture_count(cast[ptr uint8](regex.bytecode))
  var capture: ptr ptr uint8 = nil
  if captureCount > 0:
    capture = cast[ptr ptr uint8](alloc0(sizeof(ptr uint8) * captureCount * 2))
  let ret = lre_exec(capture, regex.bytecode,
                     cast[ptr uint8](cstr), cint(start),
                     cint(str.len), cint(0), dummyContext)
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
      let s = startAddress - cstrAddress
      let e = endAddress - cstrAddress
      result.captures.add((s, e))
  dealloc(capture)
