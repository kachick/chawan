import types/color

type
  Bitmap* = ref object of RootObj
    px*: seq[RGBAColorBE]
    width*: int
    height*: int

  ImageBitmap* = ref object of Bitmap

  NetworkBitmap* = ref object of Bitmap
    cacheId*: int
    imageId*: int
    contentType*: string

proc newBitmap*(width, height: int): ImageBitmap =
  return ImageBitmap(
    px: newSeq[RGBAColorBE](width * height),
    width: width,
    height: height
  )

proc setpx*(bmp: Bitmap; x, y: int; color: RGBAColorBE) {.inline.} =
  bmp.px[bmp.width * y + x] = color

proc setpx*(bmp: Bitmap; x, y: int; color: ARGBColor) {.inline.} =
  bmp.px[bmp.width * y + x] = rgba_be(color.r, color.g, color.b, color.a)

proc getpx*(bmp: Bitmap; x, y: int): RGBAColorBE {.inline.} =
  return bmp.px[bmp.width * y + x]

proc setpxb*(bmp: Bitmap; x, y: int; c: RGBAColorBE) {.inline.} =
  if c.a == 255:
    bmp.setpx(x, y, c)
  else:
    bmp.setpx(x, y, bmp.getpx(x, y).blend(c))

proc setpxb*(bmp: Bitmap; x, y: int; c: ARGBColor) {.inline.} =
  bmp.setpxb(x, y, rgba_be(c.r, c.g, c.b, c.a))
