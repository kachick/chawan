import std/algorithm
import std/unicode

import css/cssvalues
import img/bitmap
import img/path
import types/color
import types/line
import types/vector

type CanvasFillRule* = enum
  cfrNonZero = "nonzero"
  cfrEvenOdd = "evenodd"

type PaintCommand* = enum
  pcSetDimensions, pcFillRect, pcStrokeRect, pcFillPath, pcStrokePath,
  pcFillText, pcStrokeText

# https://en.wikipedia.org/wiki/Bresenham's_line_algorithm#All_cases
proc plotLineLow(bmp: Bitmap; x1, y1, x2, y2: int; color: ARGBColor) =
  var dx = x2 - x1
  var dy = y2 - y1
  var yi = 1
  if dy < 0:
    yi = -1
    dy = -dy
  var D = 2 * dy - dx;
  var y = y1;
  for x in x1 ..< x2:
    if x < 0 or y < 0 or x >= bmp.width or y >= bmp.height:
      break
    bmp.setpxb(x, y, color)
    if D > 0:
       y = y + yi;
       D = D - 2 * dx;
    D = D + 2 * dy;

proc plotLineHigh(bmp: Bitmap; x1, y1, x2, y2: int; color: ARGBColor) =
  var dx = x2 - x1
  var dy = y2 - y1
  var xi = 1
  if dx < 0:
    xi = -1
    dx = -dx
  var D = 2 * dx - dy
  var x = x1
  for y in y1 ..< y2:
    if x < 0 or y < 0 or x >= bmp.width or y >= bmp.height:
      break
    bmp.setpxb(x, y, color)
    if D > 0:
       x = x + xi
       D = D - 2 * dy
    D = D + 2 * dx

proc plotLine(bmp: Bitmap; x1, y1, x2, y2: int; color: ARGBColor) =
  if abs(y2 - y1) < abs(x2 - x1):
    if x1 > x2:
      bmp.plotLineLow(x2, y2, x1, y1, color)
    else:
      bmp.plotLineLow(x1, y1, x2, y2, color)
  else:
    if y1 > y2:
      bmp.plotLineHigh(x2, y2, x1, y1, color)
    else:
      bmp.plotLineHigh(x1, y1, x2, y2, color)

proc plotLine(bmp: Bitmap; a, b: Vector2D; color: ARGBColor) =
  bmp.plotLine(int(a.x), int(a.y), int(b.x), int(b.y), color)

proc plotLine(bmp: Bitmap; line: Line; color: ARGBColor) =
  bmp.plotLine(line.p0, line.p1, color)

proc strokePath*(bmp: Bitmap; lines: seq[Line]; color: ARGBColor) =
  for line in lines:
    bmp.plotLine(line, color)

func isInside(windingNumber: int; fillRule: CanvasFillRule): bool =
  return case fillRule
  of cfrNonZero: windingNumber != 0
  of cfrEvenOdd: windingNumber mod 2 == 0

# Algorithm originally from SerenityOS.
proc fillPath*(bmp: Bitmap; lines: PathLines; color: ARGBColor;
    fillRule: CanvasFillRule) =
  var i = 0
  var ylines: seq[LineSegment] = @[]
  for y in int(lines.miny) .. int(lines.maxy):
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
      let sx = int(a.minyx)
      let ex = int(b.minyx)
      if w.isInside(fillRule) and y > 0:
        for x in sx .. ex:
          if x > 0:
            bmp.setpxb(x, y, color)
      if int(a.p0.y) != y and int(a.p1.y) != y and int(b.p0.y) != y and
          int(b.p1.y) != y and sx != ex or a.islope * b.islope < 0:
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

proc fillRect*(bmp: Bitmap; x1, y1, x2, y2: int; color: ARGBColor) =
  for y in y1 ..< y2:
    for x in x1 ..< x2:
      bmp.setpxb(x, y, color)

proc strokeRect*(bmp: Bitmap; x1, y1, x2, y2: int; color: ARGBColor) =
  for x in x1 ..< x2:
    bmp.setpxb(x, y1, color)
    bmp.setpxb(x, y2, color)
  for y in y1 ..< y2:
    bmp.setpxb(x1, y, color)
    bmp.setpxb(x2, y, color)

type GlyphCacheItem = object
  u: uint32
  bmp: Bitmap

var unifontBitmap*: Bitmap = nil
var glyphCache: seq[GlyphCacheItem] = @[]
var glyphCacheI = 0
proc getCharBmp(u: uint32): Bitmap =
  # We only have the BMP.
  let u = if u <= 0xFFFF: u else: 0xFFFD
  for it in glyphCache:
    if it.u == u:
      return it.bmp
  # Unifont glyphs start at x: 32, y: 64, and are of 8x16/16x16 size
  let gx = int(32 + 16 * (u mod 0x100))
  let gy = int(64 + 16 * (u div 0x100))
  var fullwidth = false
  const white = rgba_be(255, 255, 255, 255)
  block loop:
    # hack to recognize full width characters
    for y in 0 ..< 16:
      for x in 8 ..< 16:
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
    glyphCache.add(GlyphCacheItem(u: u, bmp: bmp))
  else:
    glyphCache[glyphCacheI] = GlyphCacheItem(u: u, bmp: bmp)
    inc glyphCacheI
    if glyphCacheI >= glyphCache.len:
      glyphCacheI = 0
  return bmp

proc drawBitmap(a, b: Bitmap; p: Vector2D) =
  for y in 0 ..< b.height:
    for x in 0 ..< b.width:
      let ax = int(p.x) + x
      let ay = int(p.y) + y
      if ax >= 0 and ay >= y and ax < a.width and ay < a.height:
        a.setpxb(ax, ay, b.getpx(x, y))

proc fillText*(bmp: Bitmap; text: string; x, y: float64; color: ARGBColor;
    textAlign: CSSTextAlign) =
  var w = 0f64
  var glyphs: seq[Bitmap] = @[]
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
