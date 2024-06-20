import types/color

type
  Bitmap* = ref object of RootObj
    px*: seq[RGBAColorBE]
    width*: uint64
    height*: uint64

  ImageBitmap* = ref object of Bitmap

  NetworkBitmap* = ref object of Bitmap
    outputId*: int
    imageId*: int

proc newBitmap*(width, height: uint64): ImageBitmap =
  return ImageBitmap(
    px: newSeq[RGBAColorBE](width * height),
    width: width,
    height: height
  )

proc setpx*(bmp: Bitmap; x, y: uint64; color: RGBAColorBE) {.inline.} =
  bmp.px[bmp.width * y + x] = color

proc setpx*(bmp: Bitmap; x, y: uint64; color: ARGBColor) {.inline.} =
  bmp.px[bmp.width * y + x] = rgba_be(color.r, color.g, color.b, color.a)

proc getpx*(bmp: Bitmap; x, y: uint64): RGBAColorBE {.inline.} =
  return bmp.px[bmp.width * y + x]

proc setpxb*(bmp: Bitmap; x, y: uint64; c: RGBAColorBE) {.inline.} =
  if c.a == 255:
    bmp.setpx(x, y, c)
  else:
    bmp.setpx(x, y, bmp.getpx(x, y).blend(c))

proc setpxb*(bmp: Bitmap; x, y: uint64; c: ARGBColor) {.inline.} =
  bmp.setpxb(x, y, rgba_be(c.r, c.g, c.b, c.a))
