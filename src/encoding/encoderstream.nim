# Heavily based on https://encoding.spec.whatwg.org/

import algorithm
import streams
import unicode

import data/charset
import utils/map

# EncoderStream encodes utf-32 to the specified encoding.
type
  EncoderErrorMode* = enum
    ENCODER_ERROR_MODE_FATAL, ENCODER_ERROR_MODE_HTML

  ISO2022JPState = enum
    STATE_ASCII, STATE_ROMAN, STATE_JIS0208

  EncoderStream* = ref object
    source: Stream
    errormode: EncoderErrorMode
    isend: bool
    failed*: bool
    bufs: seq[seq[uint8]]
    bs: int
    bi: int
    buflen: int
    errc: uint32
    case charset: Charset
    of CHARSET_ISO_2022_JP:
      iso2022jpstate: ISO2022JPState
    else: discard

template append_byte_buf(stream: EncoderStream, c: uint8) =
  if stream.bi >= stream.buflen:
    stream.bufs.add(newSeqUninitialized[uint8](stream.buflen))
    stream.bi = 0
  stream.bufs[^1][stream.bi] = c
  inc stream.bi

template append_byte(stream: EncoderStream, c: uint8,
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  if n < olen:
    oq[n] = c
    inc n
  else:
    append_byte_buf stream, c

template append_byte(stream: EncoderStream, c: char,
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  stream.append_byte cast[uint8](c), oq, olen, n

template append_byte(stream: EncoderStream, c: uint32,
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  stream.append_byte cast[uint8](c), oq, olen, n

template append_byte(stream: EncoderStream, c: int,
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  stream.append_byte cast[uint8](c), oq, olen, n

func findPair[U, V](map: seq[(U, V)], c: uint32): int =
  return searchInMap(map, cast[U](c))

proc handleError(stream: EncoderStream, oq: ptr UncheckedArray[uint8],
    olen: int, n: var int, c: uint32) =
  case stream.errormode
  of ENCODER_ERROR_MODE_FATAL:
    stream.isend = true
    stream.failed = true
  of ENCODER_ERROR_MODE_HTML:
    stream.append_byte '&', oq, olen, n
    stream.append_byte '#', oq, olen, n
    if stream.errc == 0:
      stream.append_byte '0', oq, olen, n
    else:
      while stream.errc > 0:
        stream.append_byte cast[char](0x30 + stream.errc mod 10), oq, olen, n
        stream.errc = stream.errc div 10
    stream.append_byte ';', oq, olen, n

proc gb18030RangesPointer(c: uint32): uint32 =
  if c == 0xE7C7:
    return 7457
  # Let offset be the last pointer in index gb18030 ranges that is less than or
  # equal to pointer and code point offset its corresponding code point.
  var offset: uint32
  var p: uint32
  if c >= 0x10000:
    # omitted from the map for storage efficiency
    offset = 0x10000
    p = 189000
  elif c >= 0xFFE6:
    # Needed because upperBound returns the first element greater than pointer
    # OR last on failure, so we can't just remove one if p is e.g. 39400.
    offset = 0xFFE6
    p = 39394
  else:
    # Find the first range that is greater than p, or last if no such element
    # is found.
    # We want the last that is <=, so decrease index by one.
    let i = upperBound(Gb18030RangesEncode, c, func(a: tuple[ucs, p: uint16], b: uint32): int =
      cmp(uint32(a.ucs), b))
    let elem = Gb18030RangesEncode[i - 1]
    offset = elem.ucs
    p = elem.p
  return p + c - offset

proc encodeUTF8(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c < 0x80:
      stream.append_byte c, oq, olen, n
    else:
      var count: int
      var offset: uint8
      case c
      of 0x80..0x7FF:
        count = 1
        offset = 0xC0
      of 0x800..0xFFFF:
        count = 2
        offset = 0xE0
      of 0x10000..0x10FFFF:
        count = 3
        offset = 0xF0
      else:
        assert false
        {.linearScanEnd.}
      stream.append_byte (c shr (6 * count)) + offset, oq, olen, n
      for j in countdown(count - 1, 0):
        let tmp = c shr (6 * j)
        stream.append_byte 0x80 or (tmp and 0x3F), oq, olen, n

proc encodeSingleByte(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int,
    map: seq[tuple[ucs: uint16, val: char]]) =
  for c in iq:
    if c < 0x80:
      stream.append_byte cast[uint8](c), oq, olen, n
      continue
    let j = findPair(map, c)
    if j != -1:
      stream.append_byte cast[uint8](map[j].val) + 0x80, oq, olen, n
    else:
      stream.handleError(oq, olen, n, c)

proc encodeXUserDefined(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c < 0x80:
      stream.append_byte cast[uint8](c), oq, olen, n
      continue
    if c in 0xF780u32..0xF7FFu32:
      let b = cast[uint8](c - 0xF780 + 0x80)
      stream.append_byte b, oq, olen, n
      continue
    stream.handleError(oq, olen, n, c)

proc encodeGb18030(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int, isGBK = false) =
  for c in iq:
    if isGBK and c == 0x20AC:
      stream.append_byte 0x80, oq, olen, n
      continue
    let i = if c > 0xFFFF: -1 else: findPair(Gb18030Encode, c)
    if i != -1:
      let p = Gb18030Encode[i].p
      let lead = p div 190 + 0x81
      let trail = p mod 190
      let offset: uint8 = if trail < 0x3F: 0x40 else: 0x41
      stream.append_byte lead, oq, olen, n
      stream.append_byte cast[uint8](trail) + offset, oq, olen, n
      continue
    if isGBK:
      stream.handleError(oq, olen, n, c)
      continue
    var p = gb18030RangesPointer(c)
    let b1 = p div (10 * 126 * 10)
    p = p mod (10 * 126 * 10)
    let b2 = p div (10 * 126)
    p = p mod (10 * 126)
    let b3 = p div 10
    let b4 = p mod 10
    stream.append_byte b1, oq, olen, n
    stream.append_byte b2, oq, olen, n
    stream.append_byte b3, oq, olen, n
    stream.append_byte b4, oq, olen, n

proc encodeBig5(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c < 0x80:
      stream.append_byte c, oq, olen, n
      continue
    let i = findPair(Big5Encode, c)
    if i == -1:
      stream.handleError(oq, olen, n, c)
      continue
    let p = Big5Encode[i].p
    let lead = p div 157 + 0x81
    let trail = p mod 157
    let offset: uint8 = if trail < 0x3F: 0x40 else: 0x62
    stream.append_byte lead, oq, olen, n
    stream.append_byte cast[uint8](trail) + offset, oq, olen, n

proc encodeEUCJP(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c < 0x80:
      stream.append_byte c, oq, olen, n
    elif c == 0xA5:
      stream.append_byte 0x5C, oq, olen, n
    elif c == 0x203E:
      stream.append_byte 0x5C, oq, olen, n
    elif c in 0xFF61u32..0xFF9Fu32:
      stream.append_byte 0x8E, oq, olen, n
      stream.append_byte c - 0xFF61 + 0xA1, oq, olen, n
    else:
      let c = if c == 0x2212:
        0xFF0Du32
      else:
        c
      let i = findPair(Jis0208Encode, c)
      if i != -1:
        let p = Jis0208Encode[i].p
        let lead = p div 94 + 0xA1
        let trail = p mod 94 + 0xA1
        stream.append_byte lead, oq, olen, n
        stream.append_byte trail, oq, olen, n
      else:
        stream.handleError(oq, olen, n, c)

proc encodeISO2022JP(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  var state = stream.iso2022jpstate
  var i = 0
  while i < iq.len:
    let c = iq[i]
    if state in {STATE_ASCII, STATE_ROMAN} and
        c in [0x0Eu32, 0x0Fu32, 0x1Bu32]:
      stream.handleError(oq, olen, n, 0xFFFD)
    elif state == STATE_ASCII and c < 0x80 and c notin [0x5Cu32, 0x7Eu32] or
        c == 0xA5 or c == 0x203E:
      if c < 0x80:
        stream.append_byte c, oq, olen, n
      elif c == 0xA5:
        stream.append_byte 0xA5, oq, olen, n
      elif c == 0x203E:
        stream.append_byte 0x7E, oq, olen, n
    elif c < 0x80 and state != STATE_ASCII:
      state = STATE_ASCII
      stream.append_byte 0x1B, oq, olen, n
      stream.append_byte 0x28, oq, olen, n
      stream.append_byte 0x42, oq, olen, n
      # prepend
      continue
    elif c == 0xA5 or c == 0x203E and state != STATE_ROMAN:
      state = STATE_ROMAN
      stream.append_byte 0x1B, oq, olen, n
      stream.append_byte 0x28, oq, olen, n
      stream.append_byte 0x4A, oq, olen, n
      # prepend
      continue
    else:
      var c = c
      if c == 0x2212:
        c = 0xFF0D
      if c in 0xFF61u32..0xFF9Fu32:
        let j = findPair(ISO2022JPKatakanaEncode, c - 0xFF61)
        c = ISO2022JPKatakanaEncode[j].ucs
      let j = findPair(Jis0208Encode, c)
      if j == -1:
        if state == STATE_JIS0208:
          state = STATE_ASCII
          stream.append_byte 0x1B, oq, olen, n
          stream.append_byte 0x28, oq, olen, n
          stream.append_byte 0x42, oq, olen, n
          # prepend
          continue
        stream.handleError(oq, olen, n, c)
      else:
        let p = Jis0208Encode[j].p
        if state != STATE_JIS0208:
          state = STATE_JIS0208
          stream.append_byte 0x1B, oq, olen, n
          stream.append_byte 0x24, oq, olen, n
          stream.append_byte 0x42, oq, olen, n
          # prepend
          continue
        let lead = p div 94 + 0x21
        let trail = p mod 94 + 0x21
        stream.append_byte lead, oq, olen, n
        stream.append_byte trail, oq, olen, n
    inc i
  stream.iso2022jpstate = state

proc encodeShiftJIS(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c <= 0x80:
      stream.append_byte c, oq, olen, n
    elif c == 0xA5:
      stream.append_byte 0x5C, oq, olen, n
    elif c == 0x203E:
      stream.append_byte 0x7E, oq, olen, n
    elif c in 0xFF61u32..0xFF9Fu32:
      stream.append_byte c - 0xFF61 + 0xA1, oq, olen, n
    else:
      let c = if c == 0x2212: 0xFF0Du32 else: c
      let j = findPair(ShiftJISEncode, c)
      if j == -1:
        stream.handleError(oq, olen, n, c)
      else:
        let p = ShiftJISEncode[j].p
        let lead = p div 188
        let lead_offset = if lead < 0x1F: 0x81u16 else: 0xC1u16
        let trail = p mod 188
        let offset = if trail < 0x3F: 0x40u16 else: 0x41u16
        stream.append_byte lead + lead_offset, oq, olen, n
        stream.append_byte trail + offset, oq, olen, n

proc encodeEUCKR(stream: EncoderStream, iq: openArray[uint32],
    oq: ptr UncheckedArray[uint8], olen: int, n: var int) =
  for c in iq:
    if c < 0x80:
      stream.append_byte c, oq, olen, n
    else:
      let i = findPair(Jis0208Encode, c)
      if i != -1:
        let p = Jis0208Encode[i].p
        let lead = p div 190 + 0x81
        let trail = p mod 190 + 0x41
        stream.append_byte lead, oq, olen, n
        stream.append_byte trail, oq, olen, n
      else:
        stream.handleError(oq, olen, n, c)

# copy any data remaining from previous passes
proc copyBuffers(stream: EncoderStream, oq: ptr UncheckedArray[uint8], olen: int): int =
  if stream.bufs.len == 1:
    # one page: stream.bs ..< stream.bi
    let n = min((stream.bi - stream.bs) * sizeof(stream.bufs[0][0]), olen)
    copyMem(addr oq[0], addr stream.bufs[0][stream.bs], n)
    stream.bs += n
    if stream.bs >= stream.bi:
      # read entire page; recycle it
      stream.bs = 0
      stream.bi = 0
    return n
  else:
    # multiple pages:
    # stream.bs ..< stream.buflen
    # 0 ..< stream.buflen
    # ...
    # 0 ..< stream.bi
    let a = (stream.buflen - stream.bs) * sizeof(stream.bufs[0][0])
    if a < olen:
      copyMem(addr oq[0], addr stream.bufs[0][stream.bs], a)
      var ns = a
      stream.bs = 0
      var i = 1
      while i < stream.bufs.high:
        let n = min(stream.buflen * sizeof(stream.bufs[0][0]), olen - ns)
        copyMem(addr oq[ns], addr stream.bufs[i][0], n)
        ns += n
        if ns >= olen:
          # i'th buffer still has contents.
          stream.bs = n
          break
        stream.bs = 0
        inc i
      if ns < olen:
        # last page
        let n = min(stream.bi * sizeof(stream.bufs[0][0]), olen - ns)
        copyMem(addr oq[ns], addr stream.bufs[i][0], n)
        ns += n
        stream.bs = n
        if stream.bs >= stream.bi:
          # read entire page; recycle it
          stream.bs = 0
          stream.bi = 0
      for j in i ..< stream.bufs.len:
        stream.bufs[j - i] = stream.bufs[j]
      stream.bufs.setLen(stream.bufs.len - i)
      return ns
    elif a > olen:
      copyMem(addr oq[0], addr stream.bufs[0][stream.bs], olen)
      stream.bs += olen
      assert stream.bs < stream.buflen
      return olen
    else: # a == olen
      copyMem(addr oq[0], addr stream.bufs[0][stream.bs], a)
      stream.bs = 0
      stream.bufs.delete(0)
      return a

proc checkEnd(stream: EncoderStream, oq: ptr UncheckedArray[uint8], olen: int,
    n: var int) =
  if not stream.isend and stream.bufs.len == 1 and
      stream.bs >= stream.bi and stream.source.atEnd:
    stream.isend = true
    if stream.charset == CHARSET_ISO_2022_JP:
      if stream.iso2022jpstate != STATE_ASCII:
        stream.append_byte 0x1B, oq, olen, n
        stream.append_byte 0x28, oq, olen, n
        stream.append_byte 0x42, oq, olen, n

const ReadSize = 4096
var iq {.threadVar.}: array[ReadSize div sizeof(uint32), uint32]
proc readData*(stream: EncoderStream, buffer: pointer, olen: int): int =
  if olen == 0: return
  let oq = cast[ptr UncheckedArray[uint8]](buffer)
  result = stream.copyBuffers(oq, olen)
  let olen = olen - result
  if olen == 0 or stream.source.atEnd:
    # either output filled with buffered data; nothing to decode
    # or we're at the end of the source stream
    stream.checkEnd(oq, olen, result)
    return result
  let ilen0 = stream.source.readData(cast[pointer](addr iq[0]), ReadSize)
  #TODO what if ilen0 is 0?
  assert ilen0 != 0
  assert ilen0 mod sizeof(uint32) == 0 #TODO what to do if false?
  let ilen = ilen0 div sizeof(uint32)
  template iqoa: openArray[uint32] =
    toOpenArray(iq, 0, ilen - 1)
  case stream.charset
  of CHARSET_UTF_8:
    stream.encodeUTF8(iqoa, oq, olen, result)
  of CHARSET_IBM866:
    stream.encodeSingleByte(iqoa, oq, olen, result, IBM866Encode)
  of CHARSET_ISO_8859_2:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88592Encode)
  of CHARSET_ISO_8859_3:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88593Encode)
  of CHARSET_ISO_8859_4:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88594Encode)
  of CHARSET_ISO_8859_5:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88595Encode)
  of CHARSET_ISO_8859_6:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88596Encode)
  of CHARSET_ISO_8859_7:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88597Encode)
  of CHARSET_ISO_8859_8, CHARSET_ISO_8859_8_I:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO88598Encode)
  of CHARSET_ISO_8859_10:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO885910Encode)
  of CHARSET_ISO_8859_13:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO885913Encode)
  of CHARSET_ISO_8859_14:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO885914Encode)
  of CHARSET_ISO_8859_15:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO885915Encode)
  of CHARSET_ISO_8859_16:
    stream.encodeSingleByte(iqoa, oq, olen, result, ISO885916Encode)
  of CHARSET_KOI8_R:
    stream.encodeSingleByte(iqoa, oq, olen, result, KOI8REncode)
  of CHARSET_KOI8_U:
    stream.encodeSingleByte(iqoa, oq, olen, result, KOI8UEncode)
  of CHARSET_MACINTOSH:
    stream.encodeSingleByte(iqoa, oq, olen, result, MacintoshEncode)
  of CHARSET_WINDOWS_874:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows874Encode)
  of CHARSET_WINDOWS_1250:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1250Encode)
  of CHARSET_WINDOWS_1251:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1251Encode)
  of CHARSET_WINDOWS_1252:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1252Encode)
  of CHARSET_WINDOWS_1253:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1253Encode)
  of CHARSET_WINDOWS_1254:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1254Encode)
  of CHARSET_WINDOWS_1255:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1255Encode)
  of CHARSET_WINDOWS_1256:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1256Encode)
  of CHARSET_WINDOWS_1257:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1257Encode)
  of CHARSET_WINDOWS_1258:
    stream.encodeSingleByte(iqoa, oq, olen, result, Windows1258Encode)
  of CHARSET_X_MAC_CYRILLIC:
    stream.encodeSingleByte(iqoa, oq, olen, result, XMacCyrillicEncode)
  of CHARSET_GBK:
    stream.encodeGb18030(iqoa, oq, olen, result, true)
  of CHARSET_GB18030:
    stream.encodeGb18030(iqoa, oq, olen, result)
  of CHARSET_BIG5:
    stream.encodeBig5(iqoa, oq, olen, result)
  of CHARSET_EUC_JP:
    stream.encodeEUCJP(iqoa, oq, olen, result)
  of CHARSET_ISO_2022_JP:
    stream.encodeISO2022JP(iqoa, oq, olen, result)
  of CHARSET_SHIFT_JIS:
    stream.encodeShiftJIS(iqoa, oq, olen, result)
  of CHARSET_EUC_KR:
    stream.encodeEUCKR(iqoa, oq, olen, result)
  of CHARSET_X_USER_DEFINED:
    stream.encodeXUserDefined(iqoa, oq, olen, result)
  of CHARSET_UNKNOWN:
    doAssert false, "Somebody forgot to set the character set here"
  else: discard
  stream.checkEnd(oq, olen, result)

# Returns the number of bytes read.
proc readData*(stream: EncoderStream, buf: var seq[uint8]): int =
  return stream.readData(addr buf[0], buf.len * sizeof(buf[0]))

proc atEnd*(stream: EncoderStream): bool =
  return stream.isend

proc readAll*(stream: EncoderStream): string =
  var buf = newString(4096)
  while not stream.atEnd:
    let olen = stream.readData(addr buf[0], buf.len)
    if olen < buf.len:
      buf.setLen(olen)
      result &= buf
      break
    result &= buf

proc newEncoderStream*(source: Stream, cs = CHARSET_UTF_8, buflen = 4096,
                       errormode: EncoderErrorMode = ENCODER_ERROR_MODE_HTML): EncoderStream =
  result = EncoderStream(
    source: source,
    charset: cs,
    buflen: buflen,
    errormode: errormode
  )
  doAssert cs notin {CHARSET_UTF_16_LE, CHARSET_UTF_16_BE, CHARSET_REPLACEMENT}
  when nimvm:
    result.bufs = @[newSeq[uint8](buflen)]
  else:
    result.bufs = @[newSeqUninitialized[uint8](buflen)]
