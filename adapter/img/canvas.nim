# Very simple canvas renderer. At the moment, it uses an undocumented binary
# protocol for reading commands, and renders it whenever stdin is closed.
# So for now, it can only really render a single frame.
#
# It uses unifont for rendering text - currently I just store it as PNG
# and read it with stbi. (TODO: try switching to a more efficient format
# like qemacs fbf.)

import std/os
import std/posix
import std/strutils

import img/bitmap
import img/painter
import img/path
import io/bufreader
import io/dynstream
import types/color
import types/line
import utils/sandbox

{.compile: "canvas.c".}

{.passc: "-I" & currentSourcePath().parentDir().}

{.push header: "stb_image.h".}
proc stbi_load_from_memory(buffer: ptr uint8; len: cint; x, y, comp: ptr cint;
  req_comp: cint): ptr uint8
proc stbi_image_free(retval_from_stbi_load: pointer)
{.pop.}

const unifont = readFile"res/unifont_jp-15.0.05.png"
proc loadUnifont(unifont: string): ImageBitmap =
  var width, height, comp: cint
  let p = stbi_load_from_memory(cast[ptr uint8](unsafeAddr unifont[0]),
    cint(unifont.len), addr width, addr height, addr comp, 4)
  let len = width * height
  let bitmap = ImageBitmap(
    px: cast[seq[RGBAColorBE]](newSeqUninitialized[uint32](len)),
    width: int(width),
    height: int(height)
  )
  copyMem(addr bitmap.px[0], p, len)
  stbi_image_free(p)
  return bitmap

proc main() =
  enterNetworkSandbox()
  let os = newPosixStream(STDOUT_FILENO)
  let ps = newPosixStream(STDIN_FILENO)
  if getEnv("MAPPED_URI_SCHEME") != "img-codec+x-cha-canvas":
    os.write("Cha-Control: ConnectionError 1 wrong scheme\n")
    quit(1)
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    let headers = getEnv("REQUEST_HEADERS")
    for hdr in headers.split('\n'):
      if hdr.strip() == "Cha-Image-Info-Only: 1":
        #TODO this is a hack...
        # basically, we eat & discard all data from the buffer so it gets saved
        # to a cache file. then, actually render when the pager asks us to
        # do so.
        # obviously this is highly sub-optimal; a better solution would be to
        # leave stdin open & pass down the stream id from the buffer. (but then
        # you have to save canvas output too, so it doesn't have to be
        # re-coded, and handle that case in encoders... or implement on-demand
        # multi-frame output.)
        os.write("\n")
        discard ps.recvAll()
        quit(0)
    var cmd: PaintCommand
    var width: int
    var height: int
    ps.withPacketReader r:
      r.sread(cmd)
      if cmd != pcSetDimensions:
        os.write("Cha-Control: ConnectionError 1 wrong dimensions\n")
        quit(1)
      r.sread(width)
      r.sread(height)
    os.write("Cha-Image-Dimensions: " & $width & "x" & $height & "\n\n")
    let bmp = newBitmap(width, height)
    var alive = true
    while alive:
      try:
        ps.withPacketReader r:
          r.sread(cmd)
          case cmd
          of pcSetDimensions:
            alive = false
          of pcFillRect, pcStrokeRect:
            var x1, y1, x2, y2: int
            var color: ARGBColor
            r.sread(x1)
            r.sread(y1)
            r.sread(x2)
            r.sread(y2)
            r.sread(color)
            if cmd == pcFillRect:
              bmp.fillRect(x1, y1, x2, y2, color)
            else:
              bmp.strokeRect(x1, y1, x2, y2, color)
          of pcFillPath:
            var lines: PathLines
            var color: ARGBColor
            var fillRule: CanvasFillRule
            r.sread(lines)
            r.sread(color)
            r.sread(fillRule)
            bmp.fillPath(lines, color, fillRule)
          of pcStrokePath:
            var lines: seq[Line]
            var color: ARGBColor
            r.sread(lines)
            r.sread(color)
            bmp.strokePath(lines, color)
          of pcFillText, pcStrokeText:
            if unifontBitmap == nil:
              unifontBitmap = loadUnifont(unifont)
            var text: string
            var x, y: float64
            var color: ARGBColor
            var align: CanvasTextAlign
            r.sread(text)
            r.sread(x)
            r.sread(y)
            r.sread(color)
            r.sread(align)
            if cmd == pcFillText:
              bmp.fillText(text, x, y, color, align)
            else:
              bmp.strokeText(text, x, y, color, align)
      except EOFError, ErrorConnectionReset, ErrorBrokenPipe:
        break
    os.sendDataLoop(addr bmp.px[0], bmp.px.len * sizeof(bmp.px[0]))
  of "encode":
    os.write("Cha-Control: ConnectionError 1 not supported\n")
    quit(1)

main()
