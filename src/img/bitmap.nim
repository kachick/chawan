import algorithm
import math
import unicode

import bindings/zlib
import css/values
import img/path
import types/color
import types/line
import types/vector

import lib/endians2

type
  CanvasFillRule* = enum
    NON_ZERO = "nonzero"
    EVEN_ODD = "evenodd"

  Bitmap* = ref object of RootObj
    px: seq[RGBAColor]
    width*: uint64
    height*: uint64

  ImageBitmap* = ref object of Bitmap

proc newBitmap*(width, height: uint64): Bitmap =
  return ImageBitmap(
    px: newSeq[RGBAColor](width * height),
    width: width,
    height: height
  )

proc setpx(bmp: Bitmap, x, y: uint64, color: RGBAColor) {.inline.} =
  bmp.px[bmp.width * y + x] = color

proc getpx*(bmp: Bitmap, x, y: uint64): RGBAColor {.inline.} =
  return bmp.px[bmp.width * y + x]

proc setpxb(bmp: Bitmap, x, y: uint64, color: RGBAColor) {.inline.} =
  if color.a == 255:
    bmp.setpx(x, y, color)
  else:
    bmp.setpx(x, y, bmp.getpx(x, y).blend(color))

# https://en.wikipedia.org/wiki/Bresenham's_line_algorithm#All_cases
proc plotLineLow(bmp: Bitmap, x0, y0, x1, y1: int64, color: RGBAColor) =
  var dx = x1 - x0
  var dy = y1 - y0
  var yi = 1
  if dy < 0:
    yi = -1
    dy = -dy
  var D = 2 * dy - dx;
  var y = y0;
  for x in x0 ..< x1:
    if x < 0 or y < 0 or uint64(x) >= bmp.width or uint64(y) >= bmp.height:
      break
    bmp.setpxb(uint64(x), uint64(y), color)
    if D > 0:
       y = y + yi;
       D = D - 2 * dx;
    D = D + 2 * dy;

proc plotLineHigh(bmp: Bitmap, x0, y0, x1, y1: int64, color: RGBAColor) =
  var dx = x1 - x0
  var dy = y1 - y0
  var xi = 1
  if dx < 0:
    xi = -1
    dx = -dx
  var D = 2 * dx - dy
  var x = x0
  for y in y0 ..< y1:
    if x < 0 or y < 0 or uint64(x) >= bmp.width or uint64(y) >= bmp.height:
      break
    bmp.setpxb(uint64(x), uint64(y), color)
    if D > 0:
       x = x + xi
       D = D - 2 * dy
    D = D + 2 * dx

#TODO should be uint64...
proc plotLine(bmp: Bitmap, x0, y0, x1, y1: int64, color: RGBAColor) =
  if abs(y1 - y0) < abs(x1 - x0):
    if x0 > x1:
      bmp.plotLineLow(x1, y1, x0, y0, color)
    else:
      bmp.plotLineLow(x0, y0, x1, y1, color)
  else:
    if y0 > y1:
      bmp.plotLineHigh(x1, y1, x0, y0, color)
    else:
      bmp.plotLineHigh(x0, y0, x1, y1, color)

proc plotLine(bmp: Bitmap, a, b: Vector2D, color: RGBAColor) =
  bmp.plotLine(int64(a.x), int64(a.y), int64(b.x), int64(b.y), color)

proc plotLine(bmp: Bitmap, line: Line, color: RGBAColor) =
  bmp.plotLine(line.p0, line.p1, color)

proc strokePath*(bmp: Bitmap, path: Path, color: RGBAColor) =
  for line in path.lines:
    bmp.plotLine(line, color)

func isInside(windingNumber: int, fillRule: CanvasFillRule): bool =
  return case fillRule
  of NON_ZERO: windingNumber != 0
  of EVEN_ODD: windingNumber mod 2 == 0

# Mainly adapted from SerenityOS.
proc fillPath*(bmp: Bitmap, path: Path, color: RGBAColor,
    fillRule: CanvasFillRule) =
  let lines = path.getLineSegments()
  var i = 0
  var ylines: seq[LineSegment]
  for y in int64(lines.miny) .. int64(lines.maxy):
    for k in countdown(ylines.high, 0):
      if ylines[k].maxy < float64(y):
        ylines.del(k) # we'll sort anyways, so del is fine
    for j in i ..< lines.len:
      if lines[j].miny > float64(y):
        break
      if lines[j].maxy > float64(y):
        ylines.add(lines[j])
      inc i
    ylines.sort(cmpLineSegmentX)
    var w = if fillRule == NON_ZERO: 1 else: 0
    for k in 0 ..< ylines.high:
      let a = ylines[k]
      let b = ylines[k + 1]
      let sx = int64(a.minyx)
      let ex = int64(b.minyx)
      if isInside(w, fillRule) and y > 0:
        for x in sx .. ex:
          if x > 0:
            bmp.setpxb(uint64(x), uint64(y), color)
      if int64(a.p0.y) != y and int64(a.p1.y) != y and int64(b.p0.y) != y and
          int64(b.p1.y) != y and sx != ex or a.islope * b.islope < 0:
        case fillRule
        of EVEN_ODD: inc w
        of NON_ZERO:
          if a.p0.y < a.p1.y:
            inc w
          else:
            dec w
      ylines[k].minyx += ylines[k].islope
    if ylines.len > 0:
      ylines[^1].minyx += ylines[^1].islope

proc fillRect*(bmp: Bitmap, x0, x1, y0, y1: uint64, color: RGBAColor) =
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      bmp.setpxb(x, y, color)

proc strokeRect*(bmp: Bitmap, x0, x1, y0, y1: uint64, color: RGBAColor) =
  for x in x0 ..< x1:
    bmp.setpxb(x, y0, color)
    bmp.setpxb(x, y1, color)
  for y in y0 ..< y1:
    bmp.setpxb(x0, y, color)
    bmp.setpxb(x1, y, color)

proc clearRect*(bmp: Bitmap, x0, x1, y0, y1: uint64) =
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      bmp.setpx(x, y, rgba(0, 0, 0, 0))

proc clear*(bmp: Bitmap) =
  bmp.clearRect(0, bmp.width, 0, bmp.height)

#TODO clean up templates, also move png encoder to a different file
type PNGWriter = object
  buf: pointer
  i: int
  outlen: int

func pngInt(i: uint32): auto =
  doAssert i < uint32(2) ^ 31
  return i.toBytesBE()

func oq(writer: PNGWriter): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](writer.buf)

proc writeStr[T](writer: var PNGWriter, s: T) =
  if writer.outlen < writer.i + s.len:
    writer.outlen = writer.i + s.len
    writer.buf = realloc(writer.buf, writer.outlen)
  copyMem(addr writer.oq[writer.i], unsafeAddr s[0], s.len)
  writer.i += s.len

proc writeInt(writer: var PNGWriter, i: uint32) =
  writer.writeStr(i.toBytesBE())

proc writePngInt(writer: var PNGWriter, i: uint32) =
  doAssert i < uint32(2) ^ 31
  writer.writeInt(i)

proc writeChunk[T](writer: var PNGWriter, t: string, data: T) =
  var crc = uint32(crc32(0, cast[ptr uint8](unsafeAddr t[0]), cuint(t.len)))
  if data.len > 0:
    crc = uint32(crc32(crc, cast[ptr uint8](unsafeAddr data[0]),
      cuint(data.len)))
  writer.writePngInt(uint32(data.len))
  writer.writeStr(t)
  if data.len > 0:
    writer.writeStr(data)
  writer.writeInt(uint32(crc))

type PNGColorType {.size: sizeof(uint8).} = enum
  GRAYSCALE = 0
  TRUECOLOR = 2
  INDEXED_COLOR = 3
  GRAYSCALE_WITH_ALPHA = 4
  TRUECOLOR_WITH_ALPHA = 6

func u8toc(x: openArray[uint8]): string =
  #TODO ew
  var s = newString(x.len)
  copyMem(addr s[0], unsafeAddr x[0], x.len)
  return s

const PNGSignature = "\x89PNG\r\n\x1A\n"
proc writeIHDR(writer: var PNGWriter, width, height: uint32,
    bitDepth: uint8, colorType: PNGColorType,
    compressionMethod, filterMethod, interlaceMethod: uint8) =
  writer.writeStr(PNGSignature)
  let ihdr = u8toc(pngInt(width)) &
    u8toc(pngInt(height)) &
    char(bitDepth) &
    char(uint8(colorType)) &
    char(compressionMethod) &
    char(filterMethod) &
    char(interlaceMethod)
  writer.writeChunk("IHDR", ihdr)

proc writeIDAT(writer: var PNGWriter, bmp: Bitmap) =
  #TODO smaller idat chunks
  # +1 height for filter
  var idat = newSeq[uint8]((bmp.width + 1) * bmp.height * 4)
  var j = 0 # idat pointer
  for k in 0 ..< bmp.px.len:
    if k mod int(bmp.width) == 0:
      # begin row
      # For now, filter is always 0. TODO implement other filters
      inc j
    let p = bmp.px[k]
    idat[j] = uint8(p.r)
    idat[j + 1] = uint8(p.g)
    idat[j + 2] = uint8(p.b)
    idat[j + 3] = uint8(p.a)
    j += 4
  var hlen = compressBound(culong(idat.len))
  var oidat = newSeq[uint8](int(hlen))
  let res = compress(addr oidat[0], addr hlen, addr idat[0], culong(idat.len))
  doAssert res == Z_OK #TODO error handling...
  oidat.setLen(int(hlen))
  writer.writeChunk("IDAT", oidat)

proc toPNG*(bmp: Bitmap, outlen: var int): pointer =
  var writer = PNGWriter(
    buf: alloc(PNGSignature.len),
    outlen: PNGSignature.len
  )
  writer.writeIHDR(uint32(bmp.width), uint32(bmp.height), 8,
    TRUECOLOR_WITH_ALPHA, 0, 0, 0)
  writer.writeIDAT(bmp)
  writer.writeChunk("IEND", "")
  outlen = writer.outlen
  return writer.buf

type PNGReader = object
  bmp: Bitmap
  iq: ptr UncheckedArray[uint8]
  limit: int
  i: int
  bitDepth: uint8
  colorType: PNGColorType
  background: RGBColor
  isend: bool
  idatBuf: seq[uint8]
  uprow: seq[uint8]
  idatAt: int
  hasstrm: bool
  strm: z_stream
  strmend: bool
  atline: int

func width(reader: PNGReader): int {.inline.} = int(reader.bmp.width)

func height(reader: PNGReader): int {.inline.} = int(reader.bmp.height)

func spp(reader: PNGReader): int =
  case reader.colorType
  of TRUECOLOR: return 3
  of GRAYSCALE: return 1
  of INDEXED_COLOR: return 1
  of GRAYSCALE_WITH_ALPHA: return 2
  of TRUECOLOR_WITH_ALPHA: return 4

func scanlen(reader: PNGReader): int {.inline.} =
  let w = reader.width + 1
  return (w * reader.spp * int(reader.bitDepth) + 7) div 8

proc handleError(reader: var PNGReader, msg: string) =
  reader.bmp = nil
  if reader.hasstrm:
    discard inflateEnd(addr reader.strm)

template err(reader: var PNGReader, msg: string) =
  reader.handleError(msg)
  return

template readStr(reader: var PNGReader, L: int): string =
  if reader.i + L > reader.limit:
    reader.err "too short"
  var s = newString(L)
  copyMem(addr s[0], addr reader.iq[reader.i], L)
  reader.i += L
  s

template readU8(reader: var PNGReader): uint8 =
  if reader.i > reader.limit:
    reader.err "too short"
  let x = reader.iq[reader.i]
  inc reader.i
  x

template readU32(reader: var PNGReader): uint32 =
  if reader.i + 4 > reader.limit:
    reader.err "too short"
  let x = fromBytesBE(uint32, toOpenArray(reader.iq, reader.i, reader.i + 3))
  reader.i += 4
  x

template readPNGInt(reader: var PNGReader): uint32 =
  let x = reader.readU32()
  if x >= uint32(2) ^ 31:
    reader.err "int too large"
  x

template readColorType(reader: var PNGReader): PNGColorType =
  case reader.readU8()
  of 0u8: GRAYSCALE
  of 2u8: TRUECOLOR
  of 3u8: INDEXED_COLOR
  of 4u8: GRAYSCALE_WITH_ALPHA
  of 6u8: TRUECOLOR_WITH_ALPHA
  else: reader.err "unknown color type"

func bitDepthValid(colorType: PNGColorType, bitDepth: uint8): bool =
  case colorType
  of GRAYSCALE:
    return int(bitDepth) in [1, 2, 4, 8, 16]
  of INDEXED_COLOR:
    return int(bitDepth) in [1, 2, 4, 8]
  of TRUECOLOR, GRAYSCALE_WITH_ALPHA, TRUECOLOR_WITH_ALPHA:
    return int(bitDepth) in [8, 16]

proc readIHDR(reader: var PNGReader) =
  if reader.readStr(PNGSignature.len) != PNGSignature:
    reader.err "wrong signature"
  if reader.readPNGInt() != 13:
    reader.err "invalid header length"
  if reader.readStr(4) != "IHDR":
    reader.err "invalid header chunk"
  let width = reader.readPNGInt()
  let height = reader.readPNGInt()
  reader.bitDepth = reader.readU8() #TODO check?
  reader.colorType = reader.readColorType()
  if not bitDepthValid(reader.colorType, reader.bitDepth):
    reader.err "invalid bit depth"
  let compressionMethod = reader.readU8()
  if compressionMethod != 0:
    reader.err "unknown compression method"
  let filterMethod = reader.readU8()
  if filterMethod != 0:
    reader.err "unknown filter method"
  let interlaceMethod = reader.readU8()
  if interlaceMethod != 0:
    reader.err "unknown interlace method"
  let crc = crc32(0, addr reader.iq[reader.i - 17], 17)
  if uint32(crc) != reader.readU32(): reader.err "wrong crc"
  reader.bmp = newBitmap(width, height)

proc readbKGD(reader: var PNGReader) =
  case reader.colorType
  of GRAYSCALE, GRAYSCALE_WITH_ALPHA:
    discard reader.readU8() #TODO bit depth > 8
    reader.background = gray(reader.readU8())
  of TRUECOLOR, TRUECOLOR_WITH_ALPHA:
    discard reader.readU8() #TODO bit depth > 8
    let r = reader.readU8()
    discard reader.readU8()
    let g = reader.readU8()
    discard reader.readU8()
    let b = reader.readU8()
    reader.background = rgb(r, g, b)
  of INDEXED_COLOR:
    discard #TODO

proc unfilter(reader: var PNGReader, irow: openArray[uint8], bpp: int) =
  # none, sub, up -> replace uprow directly
  # average, paeth -> copy to temp array, then replace uprow
  let fil = irow[0]
  let w = reader.width
  case fil
  of 0u8: # none
    copyMem(addr reader.uprow[0], unsafeAddr irow[1], w)
  of 1u8: # sub
    for i in 1 ..< irow.len:
      let j = i - 1 # skip filter byte
      reader.uprow[j] = irow[i]
      if j - bpp >= 0:
        reader.uprow[j] += irow[j - bpp]
  of 2u8: # up
    for i in 1 ..< irow.len:
      let j = i - 1 # skip filter byte
      reader.uprow[j] += irow[i]
  of 3u8: # average
    reader.err "average not implemented yet"
  of 4u8: # paeth
    reader.err "paeth not implemented yet"
  else:
    eprint fil
    reader.err "got invalid filter"

proc writepxs(reader: var PNGReader, crow: var openArray[RGBAColor]) =
  case reader.colorType
  of GRAYSCALE:
    var i = 0
    var j = 0
    for x in 0 ..< crow.len:
      let u = reader.uprow[i]
      let n = case reader.bitDepth
      of 1: ((u shr (7 - j)) and 1) * 255
      of 2: ((u shr (6 - j)) and 3) * 85
      of 4: ((u shr (6 - j)) and 15) * 17
      of 8: u
      of 16: u # we ignore the lower 8 bits.
      else: 0
      j += int(reader.bitDepth)
      i += j div 8
      j = j mod 8
      let nn = int(n)
      crow[x] = rgba(nn, nn, nn, 255)
  else: discard

proc readIDAT(reader: var PNGReader) =
  if reader.idatAt == reader.idatBuf.len:
    reader.err "idat buffer already filled"
  if reader.strmend:
    reader.err "stream already ended"
  reader.strm.avail_in = cuint(reader.limit - reader.i)
  reader.strm.next_in = addr reader.iq[reader.i]
  let olen = reader.idatBuf.len - reader.idatAt
  reader.strm.avail_out = cuint(olen)
  reader.strm.next_out = addr reader.idatBuf[reader.idatAt]
  let res = inflate(addr reader.strm, Z_NO_FLUSH)
  doAssert res != Z_STREAM_ERROR
  case res
  of Z_NEED_DICT, Z_DATA_ERROR, Z_MEM_ERROR, Z_BUF_ERROR:
    # Z_BUF_ERROR is fatal here, as outlen is at least as large as idat.
    reader.err "error decompressing idat stream"
  of Z_STREAM_END:
    reader.strmend = true
  of Z_OK:
    if reader.strm.avail_out == 0:
      reader.err "not enough space for output; is width or height wrong?"
  else: doAssert false
  reader.idatAt = int(reader.strm.total_out)
  reader.i = reader.limit
  let maxline = reader.idatAt div int(reader.scanlen)
  let bmp = reader.bmp
  let bps = if reader.bitDepth <= 8: 1 else: 2 # else 16 bit
  let bpp = bps * reader.spp
  let sl = int(reader.scanlen)
  for y in reader.atline ..< maxline:
    let yi = y * sl
    assert yi + sl - 1 < reader.idatAt
    reader.unfilter(toOpenArray(reader.idatBuf, yi, yi + sl - 1), bpp)
    if unlikely(reader.bmp == nil): return
    let yj = y * reader.width
    reader.writepxs(toOpenArray(bmp.px, yj, yj + reader.width - 1))

proc readIEND(reader: var PNGReader) =
  if reader.i < reader.limit:
    reader.err "IEND too long"
  reader.isend = true

proc readUnknown(reader: var PNGReader, s: string) =
  if (int(s[0]) and 0x20) == 0:
    reader.err "unrecognized critical chunk " & s
  #else: eprint "warning: unknown chunk " & s #debug
  reader.i = reader.limit

proc zlibAlloc(opaque: pointer, items: cuint, size: cuint): pointer {.cdecl.} =
  return alloc(items * size)

proc zlibFree(opaque: pointer, address: pointer) {.cdecl.} =
  dealloc(address)

proc initZStream(reader: var PNGReader) =
  let bps = max(int(reader.bitDepth) div 8, 1)
  reader.idatBuf = newSeq[uint8](reader.scanlen * reader.height * bps)
  reader.uprow = newSeq[uint8](reader.width * bps)
  reader.strm = z_stream(
    zalloc: zlibAlloc,
    zfree: zlibFree
  )
  let ret = inflateInit(addr reader.strm)
  if ret != Z_OK:
    reader.err "failed to init inflate: " & $ret
  reader.hasstrm = true

proc fromPNG*(iq: openArray[uint8]): Bitmap =
  if iq.len == 0: return
  var reader = PNGReader(
    iq: cast[ptr UncheckedArray[uint8]](unsafeAddr iq[0]),
    limit: iq.len
  )
  reader.readIHDR()
  if reader.bmp == nil: return
  if reader.width == 0 or reader.height == 0:
    reader.err "invalid zero sized png"
  if reader.colorType != GRAYSCALE:
    reader.err "only grayscale is implemented"
  reader.initZStream()
  while reader.i < iq.len and not reader.isend:
    let len = int(reader.readPNGInt())
    if reader.i + len > iq.len:
      reader.err "chunk too long"
    let j = reader.i
    let t = reader.readStr(4)
    reader.limit = reader.i + len
    case t
    of "IHDR": reader.err "IHDR expected to be first chunk"
    of "IDAT": reader.readIDAT()
    of "IEND": reader.readIEND()
    of "bKGD": reader.readbKGD()
    else: reader.readUnknown(t)
    if reader.bmp == nil: return
    let crc = crc32(0, unsafeAddr iq[j], cuint(len + 4))
    reader.limit = iq.len
    let y = reader.readU32()
    if uint32(crc) != y:
      reader.err "wrong crc"
  if not reader.isend:
    reader.err "IEND not found"
  return reader.bmp

const unifont = readFile"res/unifont_jp-15.0.05.png"
var unifontBitmap: Bitmap
var glyphCache: seq[tuple[u: uint32, bmp: Bitmap]]
var glyphCacheI = 0
proc getCharBmp(u: uint32): Bitmap =
  # We only have the BMP.
  let u = if u <= 0xFFFF: u else: 0xFFFD
  if unifontBitmap == nil:
    unifontBitmap = fromPNG(toOpenArrayByte(unifont, 0, unifont.high))
  for (cu, bmp) in glyphCache:
    if cu == u:
      return bmp
  # Unifont glyphs start at x: 32, y: 64, and are of 8x16/16x16 size
  let gx = uint64(32 + 16 * (u mod 0xFF))
  let gy = uint64(64 + 16 * (u div 0xFF))
  var fullwidth = false
  const white = rgba(255, 255, 255, 255)
  block loop:
    # hack to recognize full width characters
    for y in 0 ..< 16u64:
      for x in 8 ..< 16u64:
        if unifontBitmap.getpx(gx + x, gy + y) != white:
          fullwidth = true
          break loop
  let bmp = newBitmap(if fullwidth: 16 else: 8, 16)
  for y in 0 ..< bmp.height:
    for x in 0 ..< bmp.width:
      let c = unifontBitmap.getpx(gx + x, gy + y)
      if c != white:
        bmp.setpx(x, y, c)
  if glyphCache.len < 256:
    glyphCache.add((u, bmp))
  else:
    glyphCache[glyphCacheI] = (u, bmp)
    inc glyphCacheI
    if glyphCacheI >= glyphCache.len:
      glyphCacheI = 0
  return bmp

proc drawBitmap(a, b: Bitmap, p: Vector2D) =
  for y in 0 ..< b.height:
    for x in 0 ..< b.width:
      let ax = uint64(p.x) + x
      let ay = uint64(p.y) + y
      if ax >= 0 and ay >= y and ax < a.width and ay < a.height:
        a.setpxb(ax, ay, b.getpx(x, y))

proc fillText*(bmp: Bitmap, text: string, x, y: float64, color: RGBAColor,
    textAlign: CSSTextAlign) =
  var w = 0f64
  var glyphs: seq[Bitmap]
  for r in text.runes:
    let glyph = getCharBmp(uint32(r))
    glyphs.add(glyph)
    w += float64(glyph.width)
  var x = x
  #TODO rtl
  case textAlign
  of TEXT_ALIGN_LEFT, TEXT_ALIGN_START: discard
  of TEXT_ALIGN_RIGHT, TEXT_ALIGN_END: x -= w
  of TEXT_ALIGN_CENTER: x -= w / 2
  else: doAssert false
  for glyph in glyphs:
    bmp.drawBitmap(glyph, Vector2D(x: x, y: y - 8))
    x += float64(glyph.width)

proc strokeText*(bmp: Bitmap, text: string, x, y: float64, color: RGBAColor,
    textAlign: CSSTextAlign) =
  #TODO
  bmp.fillText(text, x, y, color, textAlign)
