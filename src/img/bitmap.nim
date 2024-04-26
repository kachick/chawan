import types/color

type
  Bitmap* = ref object of RootObj
    px*: seq[ARGBColor]
    width*: uint64
    height*: uint64

  ImageBitmap* = ref object of Bitmap

proc newBitmap*(width, height: uint64): Bitmap =
  return ImageBitmap(
    px: newSeq[ARGBColor](width * height),
    width: width,
    height: height
  )

proc setpx*(bmp: Bitmap; x, y: uint64; color: ARGBColor) {.inline.} =
  bmp.px[bmp.width * y + x] = color

proc getpx*(bmp: Bitmap; x, y: uint64): ARGBColor {.inline.} =
  return bmp.px[bmp.width * y + x]

proc setpxb*(bmp: Bitmap; x, y: uint64; color: ARGBColor) {.inline.} =
  if color.a == 255:
    bmp.setpx(x, y, color)
  else:
    bmp.setpx(x, y, bmp.getpx(x, y).blend(color))
