import std/algorithm
import std/strutils
import std/unicode

import monoucha/libunicode
import utils/charcategory

proc passRealloc(opaque, p: pointer; size: csize_t): pointer {.cdecl.} =
  return realloc(p, size)

proc normalize*(rs: seq[Rune]; form = UNICODE_NFC): seq[Rune] =
  {.cast(noSideEffect).}:
    if rs.len == 0:
      return @[]
    var outbuf: ptr uint32
    let p = cast[ptr uint32](unsafeAddr rs[0])
    let out_len = unicode_normalize(addr outbuf, p, cint(rs.len), form, nil,
      passRealloc)
    if out_len < 0:
      raise newException(Defect, "Unicode normalization failed")
    if out_len == 0:
      return
    var rs = cast[seq[Rune]](newSeqUninitialized[uint32](out_len))
    copyMem(addr rs[0], outbuf, out_len * sizeof(uint32))
    dealloc(outbuf)
    return rs

proc mnormalize*(s: var string) =
  if NonAscii notin s:
    return # no need to normalize ascii
  s = $s.toRunes().normalize()

# n == 0: upper, 1: lower, 2: case fold
proc toUpperLU(s: string; n: cint): string =
  result = newStringOfCap(s.len)
  for r in s.runes:
    var outa: array[LRE_CC_RES_LEN_MAX, uint32]
    let n = lre_case_conv(cast[ptr UncheckedArray[uint32]](addr outa[0]),
      uint32(r), n)
    for i in 0 ..< n:
      result &= $Rune(outa[i])

proc toUpperLU*(s: string): string =
  return s.toUpperLU(0)

proc toLowerLU*(s: string): string =
  return s.toUpperLU(1)

proc capitalizeLU*(s: string): string =
  result = newStringOfCap(s.len)
  var wordStart = true
  for r in s.runes:
    if lre_is_space(uint32(r)) == 1:
      wordStart = true
      result &= $r
    elif wordStart:
      var outa: array[LRE_CC_RES_LEN_MAX, uint32]
      let n = lre_case_conv(cast[ptr UncheckedArray[uint32]](addr outa[0]),
        uint32(r), 0)
      for i in 0 ..< n:
        result &= $Rune(outa[i])
      wordStart = false
    else:
      result &= $r

type u32pair* {.packed.} = object
  a: uint32
  b: uint32

func cmpRange*(x: u32pair; y: uint32): int =
  if x.a > y:
    return 1
  elif x.b < y:
    return -1
  return 0

func contains(cr: CharRange; r: Rune): bool =
  let cps = cast[ptr UncheckedArray[u32pair]](cr.points)
  let L = cr.len div 2 - 1
  return cps.toOpenArray(0, L).binarySearch(uint32(r), cmpRange) != -1

type
  LURangeType = enum
    lurLetter = "Letter"
    lurSeparator = "Separator"
    lurHan = "Han"
    lurHiragana = "Hiragana"
    lurKatakana = "Katakana"
    lurHangul = "Hangul"

  LUContextObj = object
    crs: array[LURangeType, CharRange]
    inited: set[LURangeType]

  LUContext* = ref LUContextObj

{.warning[Deprecated]: off.}:
  proc `=destroy`*(ctx: var LUContextObj) =
    for lur, cr in ctx.crs.mpairs:
      if lur in ctx.inited:
        cr_free(addr cr)
    ctx.inited = {}

proc initGeneralCategory(ctx: LUContext; lur: LURangeType) =
  if lur notin ctx.inited:
    let p = addr ctx.crs[lur]
    cr_init(p, nil, passRealloc)
    doAssert unicode_general_category(p, cstring($lur)) == 0
    ctx.inited.incl(lur)

proc initScript(ctx: LUContext; lur: LURangeType) =
  if lur notin ctx.inited:
    let p = addr ctx.crs[lur]
    cr_init(p, nil, passRealloc)
    doAssert unicode_script(p, cstring($lur), 0) == 0
    ctx.inited.incl(lur)

proc isAlphaLU*(ctx: LUContext; r: Rune): bool =
  ctx.initGeneralCategory(lurLetter)
  return r in ctx.crs[lurLetter]

proc isWhiteSpaceLU*(ctx: LUContext; r: Rune): bool =
  ctx.initGeneralCategory(lurSeparator)
  return r in ctx.crs[lurSeparator]

proc isHan*(ctx: LUContext; r: Rune): bool =
  ctx.initScript(lurHan)
  return r in ctx.crs[lurHan]

proc isHiragana*(ctx: LUContext; r: Rune): bool =
  ctx.initScript(lurHiragana)
  return r in ctx.crs[lurHiragana]

proc isKatakana*(ctx: LUContext; r: Rune): bool =
  ctx.initScript(lurKatakana)
  return r in ctx.crs[lurKatakana]

proc isHangul*(ctx: LUContext; r: Rune): bool =
  ctx.initScript(lurHangul)
  return r in ctx.crs[lurHangul]
