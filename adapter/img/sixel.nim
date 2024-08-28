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

import std/algorithm
import std/options
import std/os
import std/posix
import std/strutils

import types/color
import utils/sandbox
import utils/twtstr

const STDOUT_FILENO = 1

proc writeAll(data: pointer; size: int) =
  var n = 0
  while n < size:
    let i = write(STDOUT_FILENO, addr cast[ptr UncheckedArray[uint8]](data)[n],
      int(size) - n)
    assert i >= 0
    n += i

proc puts(s: string) =
  if s.len > 0:
    writeAll(unsafeAddr s[0], s.len)

proc die(s: string) {.noreturn.} =
  puts(s)
  quit(1)

const DCSSTART = "\eP"
const ST = "\e\\"

type SixelBand = object
 c: int
 data: seq[uint8]

# data is binary 0..63; the output is the final ASCII form.
proc compressSixel(band: SixelBand): string =
  var outs = newStringOfCap(band.data.len div 4 + 3)
  outs &= '#'
  outs &= $band.c
  var n = 0
  var c = char(0)
  for u in band.data:
    let cc = char(u + 0x3F)
    if c != cc:
      if n > 3:
        outs &= '!' & $n & c
      else: # for char(0) n is also 0, so it is ignored.
        for i in 0 ..< n:
          outs &= c
      c = cc
      n = 0
    inc n
  if n > 3:
    outs &= '!' & $n & c
  else:
    for i in 0 ..< n:
      outs &= c
  return outs

func find(bands: seq[SixelBand]; c: int): int =
  for i in 0 ..< bands.len:
    if bands[i].c == c:
      return i
  return -1

proc setU32BE(s: var string; n: uint32; at: int) =
  s[at] = char(n and 0xFF)
  s[at + 1] = char((n shr 8) and 0xFF)
  s[at + 2] = char((n shr 16) and 0xFF)
  s[at + 3] = char((n shr 24) and 0xFF)

proc putU32BE(s: var string; n: uint32) =
  s &= char(n and 0xFF)
  s &= char((n shr 8) and 0xFF)
  s &= char((n shr 16) and 0xFF)
  s &= char((n shr 24) and 0xFF)

type Node {.acyclic.} = ref object
  leaf: bool
  c: RGBColor
  n: uint32
  r: uint32
  g: uint32
  b: uint32
  children: array[8, Node]

proc getIdx(c: RGBColor; level: int): uint8 {.inline.} =
  let sl = 7 - level
  let idx = (((c.r shr sl) and 1) shl 2) or
    (((c.g shr sl) and 1) shl 1) or
    (c.b shr sl) and 1
  return idx

type TrimMap = array[7, seq[Node]]

# Insert a node into the octree.
# Returns true if a new leaf was inserted, false otherwise.
proc insert(parent: Node; c: RGBColor; trimMap: var TrimMap; level = 0;
    n = 1u32): bool =
  # max level is 7, because we only have ~6.5 bits (0..100, inclusive)
  # (it *is* 0-indexed, but one extra level is needed for the final leaves)
  assert not parent.leaf and level < 8
  let idx = c.getIdx(level)
  let old = parent.children[idx]
  if old == nil:
    if level == 7:
      parent.children[idx] = Node(
        leaf: true,
        c: c,
        n: n,
        r: uint32(c.r) * n,
        g: uint32(c.g) * n,
        b: uint32(c.b) * n
      )
      return true
    else:
      let container = Node(leaf: false)
      parent.children[idx] = container
      trimMap[level].add(container)
      return container.insert(c, trimMap, level + 1, n)
  elif old.leaf:
    if old.c == c:
      old.n += n
      old.r += uint32(c.r) * n
      old.g += uint32(c.g) * n
      old.b += uint32(c.b) * n
      return false
    else:
      let container = Node(leaf: false)
      parent.children[idx] = container
      let nlevel = level + 1
      container.children[old.c.getIdx(nlevel)] = old # skip an alloc :)
      trimMap[level].add(container)
      return container.insert(c, trimMap, nlevel, n)
  else:
    return old.insert(c, trimMap, level + 1, n)

proc trim(trimMap: var TrimMap; K: var int) =
  var node: Node = nil
  for i in countdown(trimMap.high, 0):
    if trimMap[i].len > 0:
      node = trimMap[i].pop()
      break
  assert node != nil
  var r = 0u32
  var g = 0u32
  var b = 0u32
  var n = 0u32
  var k = K + 1
  for child in node.children.mitems:
    if child != nil:
      assert child.leaf
      r += child.r
      g += child.g
      b += child.b
      n += child.n
      child = nil
      dec k
  node.leaf = true
  node.c = rgb(uint8(r div n), uint8(g div n), uint8(b div n))
  node.r = r
  node.g = g
  node.b = b
  node.n = n
  K = k

proc getPixel(s: string; m: int; bgcolor: ARGBColor): RGBColor {.inline.} =
  let r = uint8(s[m])
  let g = uint8(s[m + 1])
  let b = uint8(s[m + 2])
  let a = uint8(s[m + 3])
  var c0 = RGBAColorBE(r: r, g: g, b: b, a: a)
  if c0.a != 255:
    let c1 = bgcolor.blend(c0)
    return RGBColor(uint32(rgb(c1.r, c1.g, c1.b)).fastmul(100))
  return RGBColor(uint32(rgb(c0.r, c0.g, c0.b)).fastmul(100))

proc quantize(s: string; bgcolor: ARGBColor; palette: int): Node =
  let root = Node(leaf: false)
  # number of leaves
  var K = 0
  # map of non-leaves for each level.
  # (note: somewhat confusingly, this actually starts at level 1.)
  var trimMap: array[7, seq[Node]]
  # batch together insertions of color runs
  var pc0 = RGBColor(0)
  var pcs = 0u32
  for i in 0 ..< s.len div 4:
    let m = i * 4
    let c0 = s.getPixel(m, bgcolor)
    inc pcs
    if pc0 != c0:
      K += int(root.insert(c0, trimMap, n = pcs))
      pcs = 0
    while K > palette:
      # trim the tree.
      trimMap.trim(K)
  if pcs > 0:
    K += int(root.insert(pc0, trimMap, n = pcs))
    while K > palette:
      # trim the tree.
      trimMap.trim(K)
  return root

type
  QuantMap = object
    map: array[4096, seq[tuple[idx: int; c: RGBColor]]]
    imap: array[4096, int]

  ColorPair = tuple[c: RGBColor; n: uint32]

func quantHash(c: RGBColor): int =
  # take top 4 bits of each component - note this means bits 4..7,
  # the 8th bit is always 0 (as 100 is the highest color component).
  return ((int(c.r shr 3) and 0xF) shl 8) or
    ((int(c.g shr 3) and 0xF) shl 4) or
    (int(c.b shr 3) and 0xF)

proc flatten(node: Node; map: var QuantMap; cols: var seq[ColorPair]) =
  if node.leaf:
    cols.add((node.c, node.n))
  else:
    for child in node.children:
      if child != nil:
        child.flatten(map, cols)

proc flatten(node: Node; outs: var string; palette: int): QuantMap =
  var map: QuantMap
  var cols = newSeqOfCap[ColorPair](palette)
  node.flatten(map, cols)
  # try to set the most common colors as the smallest numbers (so we write less)
  cols.sort(proc(a, b: ColorPair): int = cmp(a.n, b.n), order = Descending)
  for n, it in cols:
    let n = n + 1
    let c = it.c
    # 2 is RGB
    outs &= '#' & $n & ";2;" & $c.r & ';' & $c.g & ';' & $c.b
    let i = quantHash(c)
    map.map[i].add((n, c))
  # for empty buckets in the hash map: copy over the closest match
  var todo: seq[int] = @[]
  var pi = -9999 # make sure this gets overridden in imap
  for i, it in map.map.mpairs:
    if it.len == 0:
      if pi >= 0:
        map.imap[i] = pi
      todo.add(i)
    else:
      for j in todo:
        if abs(j - pi) > abs(j - i):
          map.imap[j] = i
      todo.setLen(0)
      pi = i
  return map

proc getColor(map: QuantMap; c: RGBColor): int =
  let i = quantHash(c)
  var minDist = uint32.high
  var resIdx = -1
  var j = i
  if map.map[j].len == 0:
    j = map.imap[i]
  for (idx, ic) in map.map[j]:
    let d = uint32(abs(int32(c.r) - int32(ic.r))) +
      uint32(abs(int32(c.g) - int32(ic.g))) +
      uint32(abs(int32(c.b) - int32(ic.b)))
    if d < minDist:
      minDist = d
      resIdx = idx
  return resIdx

proc encode(s: string; width, height, offx, offy, cropw: int; halfdump: bool;
    bgcolor: ARGBColor; palette: int) =
  # reserve one entry for transparency
  # (this is necessary so that cropping works properly when the last
  # sixel would not fit on the screen, and also for images with !(height % 6).)
  let palette = palette - 1
  let node = s.quantize(bgcolor, palette)
  # prelude
  var outs = "Cha-Image-Dimensions: " & $width & 'x' & $height & "\n\n"
  let preludeLenPos = outs.len
  if halfdump: # reserve size for prelude
    outs &= "\0\0\0\0"
  else:
    outs &= DCSSTART & 'q'
    # set raster attributes
    outs &= "\"1;1;" & $width & ';' & $height
  let map = node.flatten(outs, palette)
  if halfdump:
    # prepend prelude size
    let L = outs.len - 4 - preludeLenPos # subtract length field
    outs.setU32BE(uint32(L), preludeLenPos)
  puts(outs)
  let W = width * 4
  let H = W * height
  var n = offy * W
  var ymap = ""
  var totalLen = 0
  while true:
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
        let c0 = s.getPixel(m, bgcolor)
        let c = map.getColor(c0)
        #TODO this could be optimized a lot more, by squashing together bands
        # with empty runs at different places.
        var k = bands.find(c)
        if k == -1:
          bands.add(SixelBand(c: c, data: newSeq[uint8](realw)))
          k = bands.high
        bands[k].data[j] = bands[k].data[j] or mask
      n += W
    outs.setLen(0)
    var i = 0
    while true:
      outs &= bands[i].compressSixel()
      inc i
      if i >= bands.len:
        break
      outs &= '$'
    if n >= H:
      outs &= ST
      totalLen += outs.len
      break
    else:
      outs &= '-'
      totalLen += outs.len
      puts(outs)
  if halfdump:
    ymap.putU32BE(uint32(totalLen))
    ymap.putU32BE(uint32(ymap.len))
    outs &= ymap
    puts(outs)
  else:
    puts(outs)

proc parseDimensions(s: string): (int, int) =
  let s = s.split('x')
  if s.len != 2:
    die("Cha-Control: ConnectionError 1 wrong dimensions\n")
  let w = parseUInt32(s[0], allowSign = false)
  let h = parseUInt32(s[1], allowSign = false)
  if w.isNone or w.isNone:
    die("Cha-Control: ConnectionError 1 wrong dimensions\n")
  return (int(w.get), int(h.get))

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  if f != "x-sixel":
    die("Cha-Control: ConnectionError 1 unknown format " & f)
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    die("Cha-Control: ConnectionError 1 not implemented\n")
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
          die("Cha-Control: ConnectionError 1 wrong palette\n")
        cropw = int(q.get)
      of "Cha-Image-Sixel-Halfdump":
        halfdump = true
      of "Cha-Image-Sixel-Palette":
        let q = parseUInt16(s, allowSign = false)
        if q.isNone:
          die("Cha-Control: ConnectionError 1 wrong palette\n")
        palette = int(q.get)
      of "Cha-Image-Background-Color":
        bgcolor = parseLegacyColor0(s)
    if cropw == -1:
      cropw = width
    if palette == -1:
      palette = 16
    if width == 0 or height == 0:
      puts("Cha-Image-Dimensions: 0x0\n")
      quit(0) # done...
    let s = stdin.readAll()
    s.encode(width, height, offx, offy, cropw, halfdump, bgcolor, palette)

main()
