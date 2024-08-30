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
  idx: int
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
    if pc0 != c0:
      if pcs > 0:
        K += int(root.insert(pc0, trimMap, n = pcs))
      pcs = 0
      pc0 = c0
    inc pcs
    while K > palette:
      # trim the tree.
      trimMap.trim(K)
  if pcs > 0:
    K += int(root.insert(pc0, trimMap, n = pcs))
    while K > palette:
      # trim the tree.
      trimMap.trim(K)
  return root

proc flatten(node: Node; cols: var seq[Node]) =
  if node.leaf:
    cols.add(node)
  else:
    for child in node.children:
      if child != nil:
        child.flatten(cols)

proc flatten(node: Node; outs: var string; palette: int): seq[Node] =
  var cols = newSeqOfCap[Node](palette)
  node.flatten(cols)
  # try to set the most common colors as the smallest numbers (so we write less)
  cols.sort(proc(a, b: Node): int = cmp(a.n, b.n), order = Descending)
  for n, it in cols:
    let n = n + 1 # skip 0 - that's transparent
    let c = it.c
    # 2 is RGB
    outs &= '#' & $n & ";2;" & $c.r & ';' & $c.g & ';' & $c.b
    it.idx = n
  return cols

type
  DitherDiff = tuple[r, g, b: int32]

  Dither = object
    d1: seq[DitherDiff]
    d2: seq[DitherDiff]

proc getColor(node: Node; c: RGBColor; nodes: seq[Node]; diff: var DitherDiff;
    level = 0): Node =
  if node.leaf:
    let r = int32(c.r) - int32(node.c.r)
    let g = int32(c.g) - int32(node.c.g)
    let b = int32(c.b) - int32(node.c.b)
    diff = (r, g, b)
    return node
  let idx = int(c.getIdx(level))
  var child = node.children[idx]
  let nlevel = level + 1
  if child == nil:
    var minDist = uint32.high
    for node in nodes:
      let rd = int32(c.r) - int32(node.c.r)
      let gd = int32(c.g) - int32(node.c.g)
      let bd = int32(c.b) - int32(node.c.b)
      let d = uint32(abs(rd)) + uint32(abs(gd)) + uint32(abs(bd))
      if d < minDist:
        minDist = d
        child = node
        diff = (rd, gd, bd)
    node.children[idx] = child
    return child
  return child.getColor(c, nodes, diff, nlevel)

proc correctDither(c: RGBColor; x: int; dither: Dither): RGBColor =
  let (rd, gd, bd) = dither.d1[x + 1]
  let r = uint8(clamp(int32(c.r) + rd div 16, 0, 100))
  let g = uint8(clamp(int32(c.g) + gd div 16, 0, 100))
  let b = uint8(clamp(int32(c.b) + bd div 16, 0, 100))
  return rgb(r, g, b)

proc fs(dither: var Dither; x: int; d: DitherDiff) =
  let x = x + 1 # skip first bounds check
  template at(p, mul: untyped) =
    var (rd, gd, bd) = p
    p = (rd + d.r * mul, gd + d.g * mul, bd + d.b * mul)
  at(dither.d1[x + 1], 7)
  at(dither.d2[x - 1], 3)
  at(dither.d2[x], 5)
  at(dither.d2[x + 1], 1)

type
  SixelBand = seq[ptr SixelChunk]

  SixelChunk = object
    x: int
    c: int
    nrow: int
    data: seq[uint8]

# data is binary 0..63; the output is the final ASCII form.
proc compressSixel(outs: var string; band: SixelBand) =
  var x = 0
  for chunk in band:
    outs &= '#'
    outs &= $chunk.c
    let diff = chunk.x - x
    if diff > 3:
      outs &= '!' & $diff & '?'
    else:
      for i in 0 ..< diff:
        outs &= '?'
    x = chunk.x + chunk.data.len
    var n = 0
    var c = char(0)
    for u in chunk.data:
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

proc createBands(bands: var seq[SixelBand]; chunkMap: seq[SixelChunk];
    nrow: int) =
  for chunk in chunkMap:
    if chunk.nrow < nrow:
      continue
    let x = chunk.x
    let ex = chunk.x + chunk.data.len
    var found = false
    for band in bands.mitems:
      if band[0].x > ex:
        band.insert(unsafeAddr chunk, 0)
        found = true
        break
      elif band[^1].x + band[^1].data.len <= x:
        band.add(unsafeAddr chunk)
        found = true
        break
    if not found:
      bands.add(@[unsafeAddr chunk])

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
  let nodes = node.flatten(outs, palette)
  if halfdump:
    # prepend prelude size
    let L = outs.len - 4 - preludeLenPos # subtract length field
    outs.setU32BE(uint32(L), preludeLenPos)
  puts(outs)
  let W = width * 4
  let H = W * height
  let realw = cropw - offx
  var n = offy * W
  var ymap = ""
  var totalLen = 0
  # add +2 so we don't have to bounds check
  var dither = Dither(
    d1: newSeq[DitherDiff](realw + 2),
    d2: newSeq[DitherDiff](realw + 2)
  )
  var chunkMap = newSeq[SixelChunk](palette)
  var nrow = 1
  while true:
    if halfdump:
      ymap.putU32BE(uint32(totalLen))
    for i in 0 ..< 6:
      if n >= H:
        break
      let mask = 1u8 shl i
      var chunk: ptr SixelChunk = nil
      for j in 0 ..< realw:
        let m = n + (offx + j) * 4
        let c0 = s.getPixel(m, bgcolor).correctDither(j, dither)
        var diff: DitherDiff
        let c = node.getColor(c0, nodes, diff).idx
        dither.fs(j, diff)
        if chunk == nil or chunk.c != c:
          chunk = addr chunkMap[c - 1]
          chunk.c = c
          if chunk.nrow < nrow:
            chunk.nrow = nrow
            chunk.x = j
            chunk.data.setLen(0)
          elif chunk.x > j:
            let diff = chunk.x - j
            chunk.x = j
            let olen = chunk.data.len
            chunk.data.setLen(olen + diff)
            moveMem(addr chunk.data[diff], addr chunk.data[0], olen)
            zeroMem(addr chunk.data[0], diff)
          elif chunk.data.len < j - chunk.x:
            chunk.data.setLen(j - chunk.x)
        let k = j - chunk.x
        if k < chunk.data.len:
          chunk.data[k] = chunk.data[k] or mask
        else:
          chunk.data.add(mask)
      n += W
      var tmp = move(dither.d1)
      dither.d1 = move(dither.d2)
      dither.d2 = move(tmp)
      zeroMem(addr dither.d2[0], dither.d2.len * sizeof(dither.d2[0]))
    var bands: seq[SixelBand] = @[]
    bands.createBands(chunkMap, nrow)
    outs.setLen(0)
    for band in bands:
      if outs.len > 0:
        outs &= '$'
      outs.compressSixel(band)
    if n >= H:
      outs &= ST
      totalLen += outs.len
      break
    else:
      outs &= '-'
      totalLen += outs.len
      puts(outs)
    inc nrow
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
