import math

import bindings/zlib
import img/bitmap
import types/color

import lib/endians2

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
  reader.bitDepth = reader.readU8()
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
      crow[x] = rgba(n, n, n, 255u8)
  of TRUECOLOR:
    let step = int(reader.bitdepth) div 8
    var i = 0
    for x in 0 ..< crow.len:
      let r = reader.uprow[i]
      i += step
      let g = reader.uprow[i]
      i += step
      let b = reader.uprow[i]
      i += step
      crow[x] = rgba(r, g, b, 255u8)
  of INDEXED_COLOR: discard #TODO
  of GRAYSCALE_WITH_ALPHA:
    let step = int(reader.bitDepth) div 8
    var i = 0
    for x in 0 ..< crow.len:
      let n = reader.uprow[i]
      i += step
      let a = reader.uprow[i]
      i += step
      crow[x] = rgba(n, n, n, a)
  of TRUECOLOR_WITH_ALPHA:
    let step = int(reader.bitDepth) div 8
    for x in 0 ..< crow.len:
      let r = reader.uprow[x * step]
      let g = reader.uprow[(x + 1) * step]
      let b = reader.uprow[(x + 2) * step]
      let a = reader.uprow[(x + 3) * step]
      crow[x] = rgba(r, g, b, a)

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
  if reader.colorType == INDEXED_COLOR:
    reader.err "indexed color not implemented yet"
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
