import std/options
import std/os
import std/strutils

import utils/sandbox
import utils/twtstr

{.passc: "-fno-strict-aliasing".}
{.passl: "-fno-strict-aliasing".}

{.compile: "jebp.c".}

when sizeof(cint) < 4:
  type jebp_int = clong
else:
  type jebp_int = cint

{.passc: "-I" & currentSourcePath().parentDir().}

{.push header: "jebp.h".}
type
  jebp_io_callbacks {.importc.} = object
    read: proc(data: pointer; size: csize_t; user: pointer): csize_t {.cdecl.}
    check_error: proc(user: pointer): cint {.cdecl.}

  jebp_error_t = cint

  jebp_color_t = object
    r: uint8
    g: uint8
    b: uint8
    a: uint8

  jebp_image_t {.importc.} = object
    width: jebp_int
    height: jebp_int
    pixels: ptr jebp_color_t

proc jebp_read_from_callbacks(image: ptr jebp_image_t;
  cb: ptr jebp_io_callbacks; user: pointer): jebp_error_t {.importc.}

proc jebp_read_size_from_callbacks(image: ptr jebp_image_t;
  cb: ptr jebp_io_callbacks; user: pointer): jebp_error_t {.importc.}

proc jebp_error_string(err: jebp_error_t): cstring {.importc.}

proc jebp_free_image(image: ptr jebp_image_t) {.importc.}
{.pop.}

proc myRead(data: pointer; size: csize_t; user: pointer): csize_t {.cdecl.} =
  return csize_t(stdin.readBuffer(data, size))

proc stbir_resize_uint8(input_pixels: ptr uint8;
  input_w, input_h, input_stride_in_bytes: cint; output_pixels: ptr uint8;
  output_w, output_h, output_stride_in_bytes, num_channels: cint): cint
  {.importc.}

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    if f != "webp":
      stdout.write("Cha-Control: ConnectionError 1 unknown format " & f)
      return
    let headers = getEnv("REQUEST_HEADERS")
    var targetWidth = cint(-1)
    var targetHeight = cint(-1)
    var infoOnly = false
    for hdr in headers.split('\n'):
      let v = hdr.after(':').strip()
      case hdr.until(':')
      of "Cha-Image-Info-Only":
        infoOnly = v == "1"
      of "Cha-Image-Target-Dimensions":
        let s = v.split('x')
        if s.len != 2:
          stdout.write("Cha-Control: ConnectionError 1 wrong dimensions")
          return
        let w = parseUInt32(s[0], allowSign = false)
        let h = parseUInt32(s[1], allowSign = false)
        if w.isNone or w.isNone:
          stdout.write("Cha-Control: ConnectionError 1 wrong dimensions")
          return
        targetWidth = cint(w.get)
        targetHeight = cint(h.get)
    var image = jebp_image_t()
    var cb = jebp_io_callbacks(read: myRead)
    if infoOnly:
      let res = jebp_read_size_from_callbacks(addr image, addr cb, nil)
      if res == 0:
        stdout.write("Cha-Image-Dimensions: " & $image.width & "x" &
          $image.height & "\n\n")
      else:
        stdout.write("Cha-Control: ConnectionError 1 jepb error " &
          $jebp_error_string(res))
      return
    let res = jebp_read_from_callbacks(addr image, addr cb, nil)
    if res != 0:
      stdout.write("Cha-Control: ConnectionError 1 jebp error " &
        $jebp_error_string(res))
    elif targetWidth != -1 and targetHeight != -1:
      let p2 = cast[ptr uint8](alloc(targetWidth * targetHeight * 4))
      doAssert stbir_resize_uint8(cast[ptr uint8](image.pixels), image.width,
        image.height, 0, p2, targetWidth, targetHeight, 0, 4) == 1
      stdout.write("Cha-Image-Dimensions: " & $targetWidth & "x" &
        $targetHeight & "\n\n")
      discard stdout.writeBuffer(p2, targetWidth * targetHeight * 4)
      dealloc(p2)
      jebp_free_image(addr image)
    else:
      stdout.write("Cha-Image-Dimensions: " & $image.width & "x" &
        $image.height & "\n\n")
      discard stdout.writeBuffer(cast[ptr uint8](image.pixels), image.width *
        image.height * 4)
      jebp_free_image(addr image)
  of "encode":
    stdout.write("Cha-Control: ConnectionError 1 not supported")

main()
