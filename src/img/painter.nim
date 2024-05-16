import std/algorithm
import std/unicode

import css/cssvalues
import img/bitmap
import img/path
import img/png
import types/color
import types/line
import types/vector

type CanvasFillRule* = enum
  cfrNonZero = "nonzero"
  cfrEvenOdd = "evenodd"

# https://en.wikipedia.org/wiki/Bresenham's_line_algorithm#All_cases
proc plotLineLow(bmp: Bitmap; x0, y0, x1, y1: int64; color: ARGBColor) =
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

proc plotLineHigh(bmp: Bitmap; x0, y0, x1, y1: int64; color: ARGBColor) =
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
proc plotLine(bmp: Bitmap; x0, y0, x1, y1: int64; color: ARGBColor) =
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

proc plotLine(bmp: Bitmap; a, b: Vector2D; color: ARGBColor) =
  bmp.plotLine(int64(a.x), int64(a.y), int64(b.x), int64(b.y), color)

proc plotLine(bmp: Bitmap; line: Line; color: ARGBColor) =
  bmp.plotLine(line.p0, line.p1, color)

proc strokePath*(bmp: Bitmap; path: Path; color: ARGBColor) =
  for line in path.lines:
    bmp.plotLine(line, color)

func isInside(windingNumber: int; fillRule: CanvasFillRule): bool =
  return case fillRule
  of cfrNonZero: windingNumber != 0
  of cfrEvenOdd: windingNumber mod 2 == 0

# Mainly adapted from SerenityOS.
proc fillPath*(bmp: Bitmap; path: Path; color: ARGBColor;
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
    var w = if fillRule == cfrNonZero: 1 else: 0
    for k in 0 ..< ylines.high:
      let a = ylines[k]
      let b = ylines[k + 1]
      let sx = int64(a.minyx)
      let ex = int64(b.minyx)
      if w.isInside(fillRule) and y > 0:
        for x in sx .. ex:
          if x > 0:
            bmp.setpxb(uint64(x), uint64(y), color)
      if int64(a.p0.y) != y and int64(a.p1.y) != y and int64(b.p0.y) != y and
          int64(b.p1.y) != y and sx != ex or a.islope * b.islope < 0:
        case fillRule
        of cfrEvenOdd: inc w
        of cfrNonZero:
          if a.p0.y < a.p1.y:
            inc w
          else:
            dec w
      ylines[k].minyx += ylines[k].islope
    if ylines.len > 0:
      ylines[^1].minyx += ylines[^1].islope

proc fillRect*(bmp: Bitmap; x0, x1, y0, y1: uint64, color: ARGBColor) =
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      bmp.setpxb(x, y, color)

proc strokeRect*(bmp: Bitmap; x0, x1, y0, y1: uint64, color: ARGBColor) =
  for x in x0 ..< x1:
    bmp.setpxb(x, y0, color)
    bmp.setpxb(x, y1, color)
  for y in y0 ..< y1:
    bmp.setpxb(x0, y, color)
    bmp.setpxb(x1, y, color)

proc clearRect*(bmp: Bitmap; x0, x1, y0, y1: uint64) =
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      bmp.setpx(x, y, rgba(0, 0, 0, 0))

proc clear*(bmp: Bitmap) =
  bmp.clearRect(0, bmp.width, 0, bmp.height)

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
  let gx = uint64(32 + 16 * (u mod 0x100))
  let gy = uint64(64 + 16 * (u div 0x100))
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

proc drawBitmap(a, b: Bitmap; p: Vector2D) =
  for y in 0 ..< b.height:
    for x in 0 ..< b.width:
      let ax = uint64(p.x) + x
      let ay = uint64(p.y) + y
      if ax >= 0 and ay >= y and ax < a.width and ay < a.height:
        a.setpxb(ax, ay, b.getpx(x, y))

proc fillText*(bmp: Bitmap; text: string; x, y: float64; color: ARGBColor;
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
  of TextAlignLeft, TextAlignStart: discard
  of TextAlignRight, TextAlignEnd: x -= w
  of TextAlignCenter: x -= w / 2
  else: doAssert false
  for glyph in glyphs:
    bmp.drawBitmap(glyph, Vector2D(x: x, y: y - 8))
    x += float64(glyph.width)

proc strokeText*(bmp: Bitmap; text: string; x, y: float64; color: ARGBColor;
    textAlign: CSSTextAlign) =
  #TODO
  bmp.fillText(text, x, y, color, textAlign)
