# Sixel codec. I'm lazy, so no decoder yet.
#
# "Regular" mode just encodes the image as a sixel image, with
# Cha-Image-Sixel-Palette colors. (TODO: maybe adjust this based on quality?)
# The encoder also has a "half-dump" mode, where the output is modified as
# follows:
#
# * DCS q set-raster-attributes is omitted.
# * 32-bit binary number in header indicates length of following palette.
# * A lookup table is appended to the file end, which includes (height + 5) / 6
#   32-bit binary numbers indicating the start index of every 6th row.
#
# This way, the image can be vertically cropped in ~constant time.

import std/options
import std/os
import std/strutils

import types/color
import utils/sandbox
import utils/twtstr

const DCSSTART = "\eP"
const ST = "\e\\"

# data is binary 0..63; the output is the final ASCII form.
proc compressSixel(data: openArray[uint8]; c: uint8): string =
  var outs = newStringOfCap(data.len div 4 + 3)
  outs &= '#'
  outs &= $c
  var n = 0
  var c = char(0)
  for u in data:
    let cc = char(u + 0x3F)
    if c != cc:
      if n > 3:
        outs &= '!' & $n & c
      else: # for char(0) n is also 0, so it is ignored.
        outs &= c.repeat(n)
      c = cc
      n = 0
    inc n
  if n > 3:
    outs &= '!' & $n & c
  else:
    outs &= c.repeat(n)
  return outs

type SixelBand = object
 c: uint8
 data: seq[uint8]

func find(bands: seq[SixelBand]; c: uint8): int =
  for i, band in bands:
    if band.c == c:
      return i
  -1

proc setU32BE(s: var string; n: uint32) =
  s[0] = char(n and 0xFF)
  s[1] = char((n shr 8) and 0xFF)
  s[2] = char((n shr 16) and 0xFF)
  s[3] = char((n shr 24) and 0xFF)

proc putU32BE(s: var string; n: uint32) =
  s &= char(n and 0xFF)
  s &= char((n shr 8) and 0xFF)
  s &= char((n shr 16) and 0xFF)
  s &= char((n shr 24) and 0xFF)

proc encode(s: string; width, height, offx, offy, cropw: int; halfdump: bool;
    bgcolor: ARGBColor; palette: int) =
  if width == 0 or height == 0:
    return # done...
  # prelude
  var outs = ""
  if halfdump: # reserve size for prelude
    outs &= "\0\0\0\0"
  else:
    outs &= DCSSTART & 'q'
    # set raster attributes
    outs &= "\"1;1;" & $width & ';' & $height
  for b in 16 ..< 256:
    # laziest possible color register allocation scheme
    #TODO obviously this produces sub-optimal results
    let rgb = EightBitColor(b).toRGB()
    let rgbq = RGBColor(uint32(rgb).fastmul(100))
    let n = b - 15
    # 2 is RGB
    outs &= '#' & $n & ";2;" & $rgbq.r & ';' & $rgbq.g & ';' & $rgbq.b
  if halfdump:
    # prepend prelude size
    let L = outs.len - 4 # subtract length field
    outs.setU32BE(uint32(L))
  stdout.write(outs)
  let W = width * 4
  let H = W * height
  var n = offy * W
  var ymap = ""
  var totalLen = 0
  while n < H:
    if halfdump:
      ymap.putU32BE(uint32(totalLen))
    var bands = newSeq[SixelBand]()
    for i in 0 ..< 6:
      if n >= H:
        break
      let mask = 1u8 shl i
      let realw = cropw - offx
      for j in 0 ..< realw:
        let m = n + (j + offx) * 4
        let r = uint8(s[m])
        let g = uint8(s[m + 1])
        let b = uint8(s[m + 2])
        let a = uint8(s[m + 3])
        var c0 = RGBAColorBE(r: r, g: g, b: b, a: a)
        if c0.a != 255:
          let c1 = bgcolor.blend(c0)
          c0 = RGBAColorBE(r: c1.r, g: c1.g, b: c1.b, a: c1.a)
        let c = uint8(c0.toEightBit())
        if (let k = bands.find(c); k != -1):
          bands[k].data[j] = bands[k].data[j] or mask
        else:
          bands.add(SixelBand(c: c, data: newSeq[uint8](realw)))
          bands[^1].data[^1] = mask
      n += W
    outs.setLen(0)
    for i in 0 ..< bands.high:
      outs &= bands[i].data.compressSixel(bands[i].c - 15) & '$'
    outs &= bands[^1].data.compressSixel(bands[^1].c - 15)
    if n >= H:
      outs &= ST
    else:
      outs &= '-'
    totalLen += outs.len
    stdout.write(outs)
  if halfdump:
    ymap.putU32BE(uint32(totalLen))
    stdout.write(ymap)

proc parseDimensions(s: string): (int, int) =
  let s = s.split('x')
  if s.len != 2:
    stdout.writeLine("Cha-Control: ConnectionError 1 wrong dimensions")
    return
  let w = parseUInt32(s[0], allowSign = false)
  let h = parseUInt32(s[1], allowSign = false)
  if w.isNone or w.isNone:
    stdout.writeLine("Cha-Control: ConnectionError 1 wrong dimensions")
    return
  return (int(w.get), int(h.get))

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  if f != "x-sixel":
    stdout.writeLine("Cha-Control: ConnectionError 1 unknown format " & f)
    return
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    stdout.writeLine("Cha-Control: ConnectionError 1 not implemented")
  of "encode":
    let headers = getEnv("REQUEST_HEADERS")
    var width = 0
    var height = 0
    var offx = 0
    var offy = 0
    var halfdump = false
    var palette = -1
    var bgcolor = rgb(0, 0, 0)
    var cropw = -1
    for hdr in headers.split('\n'):
      let s = hdr.after(':').strip()
      case hdr.until(':')
      of "Cha-Image-Dimensions":
        (width, height) = parseDimensions(s)
      of "Cha-Image-Offset":
        (offx, offy) = parseDimensions(s)
      of "Cha-Image-Crop-Width":
        let q = parseUInt32(s, allowSign = false)
        if q.isNone:
          stdout.writeLine("Cha-Control: ConnectionError 1 wrong palette")
          return
        cropw = int(q.get)
      of "Cha-Image-Sixel-Halfdump":
        halfdump = true
      of "Cha-Image-Sixel-Palette":
        let q = parseUInt16(s, allowSign = false)
        if q.isNone:
          stdout.writeLine("Cha-Control: ConnectionError 1 wrong palette")
          return
        palette = int(q.get)
      of "Cha-Image-Background-Color":
        bgcolor = parseLegacyColor0(s)
    if cropw == -1:
      cropw = width
    let s = stdin.readAll()
    stdout.write("Cha-Image-Dimensions: " & $width & 'x' & $height & "\n\n")
    s.encode(width, height, offx, offy, cropw, halfdump, bgcolor, palette)

main()
