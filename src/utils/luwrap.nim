import std/strutils
import std/unicode

import bindings/libunicode
import utils/charcategory

proc passRealloc(opaque: pointer, p: pointer, size: csize_t): pointer
    {.cdecl.} =
  return realloc(p, size)

proc mnormalize*(rs: var seq[Rune], form = UNICODE_NFC) = {.cast(noSideEffect).}:
  if rs.len == 0: return
  var outbuf: ptr uint32
  let p = cast[ptr uint32](unsafeAddr rs[0])
  let out_len = unicode_normalize(addr outbuf, p, cint(rs.len), form, nil,
    passRealloc)
  if out_len < 0:
    raise newException(Defect, "Unicode normalization failed")
  if out_len == 0:
    return
  rs = cast[seq[Rune]](newSeqUninitialized[uint32](out_len))
  copyMem(addr rs[0], outbuf, out_len * sizeof(uint32))
  dealloc(outbuf)

#TODO maybe a utf8 normalization procedure?
proc mnormalize*(s: var string) =
  if NonAscii notin s:
    return # no need to normalize ascii
  var rs = s.toRunes()
  rs.mnormalize()
  s = $rs

func normalize*(rs: seq[Rune], form = UNICODE_NFC): seq[Rune] =
  {.cast(noSideEffect).}:
    if rs.len == 0: return
    var outbuf: ptr uint32
    let p = cast[ptr uint32](unsafeAddr rs[0])
    let out_len = unicode_normalize(addr outbuf, p, cint(rs.len), form,
      nil, passRealloc)
    if out_len < 0:
      raise newException(Defect, "Unicode normalization failed")
    if out_len == 0:
      return
    result = cast[seq[Rune]](newSeqUninitialized[uint32](out_len))
    copyMem(addr result[0], outbuf, out_len * sizeof(uint32))
    dealloc(outbuf)
