# Interface for QuickJS libregexp.
import std/unicode

import bindings/libregexp
import bindings/quickjs
import types/opt
import utils/twtstr

export LREFlags

type
  Regex* = object
    bytecode: seq[uint8]
    buf: string

  RegexResult* = object
    success*: bool
    captures*: seq[tuple[s, e: int]] # start, end

  RegexReplace* = object
    regex: Regex
    rule: string
    global: bool

var dummyRuntime = JS_NewRuntime()
var dummyContext = JS_NewContextRaw(dummyRuntime)

func `$`*(regex: Regex): string =
  regex.buf

proc compileRegex*(buf: string, flags: LREFlags = {}): Result[Regex, string] =
  var error_msg_size = 64
  var error_msg = newString(error_msg_size)
  prepareMutation(error_msg)
  var plen: cint
  let bytecode = lre_compile(addr plen, cstring(error_msg),
    cint(error_msg_size), cstring(buf), csize_t(buf.len), flags.toCInt,
    dummyContext)
  if bytecode == nil:
    return err(error_msg.until('\0')) # Failed to compile.
  assert plen > 0
  var bcseq = newSeqUninitialized[uint8](plen)
  copyMem(addr bcseq[0], bytecode, plen)
  dummyRuntime.js_free_rt(bytecode)
  let regex = Regex(
    buf: buf,
    bytecode: bcseq
  )
  return ok(regex)

func countBackslashes(buf: string, i: int): int =
  var j = 0
  for i in countdown(i, 0):
    if buf[i] != '\\':
      break
    inc j
  return j

# ^abcd -> ^abcd
# efgh$ -> efgh$
# ^ijkl$ -> ^ijkl$
# mnop -> ^mnop$
proc compileMatchRegex*(buf: string): Result[Regex, string] =
  if buf.len == 0:
    return compileRegex(buf)
  if buf[0] == '^':
    return compileRegex(buf)
  if buf[^1] == '$':
    # Check whether the final dollar sign is escaped.
    if buf.len == 1 or buf[^2] != '\\':
      return compileRegex(buf)
    let j = buf.countBackslashes(buf.high - 2)
    if j mod 2 == 1: # odd, because we do not count the last backslash
      return compileRegex(buf)
    # escaped. proceed as if no dollar sign was at the end
  if buf[^1] == '\\':
    # Check if the regex contains an invalid trailing backslash.
    let j = buf.countBackslashes(buf.high - 1)
    if j mod 2 != 1: # odd, because we do not count the last backslash
      return err("unexpected end")
  var buf2 = "^"
  buf2 &= buf
  buf2 &= "$"
  return compileRegex(buf2)

proc compileSearchRegex*(str: string, defaultFlags: LREFlags):
    Result[Regex, string] =
  # Emulate vim's \c/\C: override defaultFlags if one is found, then remove it
  # from str.
  # Also, replace \< and \> with \b as (a bit sloppy) vi emulation.
  var flags = defaultFlags
  var s = newStringOfCap(str.len)
  var quot = false
  for c in str:
    if quot:
      quot = false
      case c
      of 'c': flags.incl(LRE_FLAG_IGNORECASE)
      of 'C': flags.excl(LRE_FLAG_IGNORECASE)
      of '<', '>': s &= "\\b"
      else: s &= '\\' & c
    elif c == '\\':
      quot = true
    else:
      s &= c
  if quot:
    s &= '\\'
  flags.incl(LRE_FLAG_GLOBAL) # for easy backwards matching
  return compileRegex(s, flags)

proc exec*(regex: Regex, str: string, start = 0, length = -1, nocaps = false): RegexResult =
  let length = if length == -1:
    str.len
  else:
    length
  assert 0 <= start and start <= length

  let bytecode = unsafeAddr regex.bytecode[0]
  let captureCount = lre_get_capture_count(bytecode)
  var capture: ptr UncheckedArray[int] = nil
  if captureCount > 0:
    let size = sizeof(ptr uint8) * captureCount * 2
    capture = cast[ptr UncheckedArray[int]](alloc0(size))
  var cstr = cstring(str)
  let flags = lre_get_flags(bytecode).toLREFlags
  var start = start
  while true:
    let ret = lre_exec(cast[ptr ptr uint8](capture), bytecode,
      cast[ptr uint8](cstr), cint(start), cint(length), cint(3), dummyContext)
    if ret != 1: #TODO error handling? (-1)
      break
    result.success = true
    if captureCount == 0 or nocaps:
      break
    let cstrAddress = cast[int](cstr)
    let ps = start
    start = capture[1] - cstrAddress
    for i in 0 ..< captureCount:
      let s = capture[i * 2] - cstrAddress
      let e = capture[i * 2 + 1] - cstrAddress
      result.captures.add((s, e))
    if LRE_FLAG_GLOBAL notin flags:
      break
    if start >= str.len:
      break
    if ps == start:
      start += runeLenAt(str, start)
  if captureCount > 0:
    dealloc(capture)

proc match*(regex: Regex, str: string, start = 0, length = str.len): bool =
  return regex.exec(str, start, length, nocaps = true).success
