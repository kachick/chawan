import std/options
import std/os
import std/strutils

import utils/sandbox
import utils/twtstr

{.passc: "-fno-strict-aliasing".}
{.passl: "-fno-strict-aliasing".}

{.compile: "stb_image.c".}

type stbi_io_callbacks = object
  read: proc(user: pointer; data: ptr uint8; size: cint): cint {.cdecl.}
  skip: proc(user: pointer; n: cint) {.cdecl.}
  eof: proc(user: pointer): cint {.cdecl.}

proc stbi_load_from_callbacks(clbk: ptr stbi_io_callbacks; user: pointer;
  x, y, channels_in_file: var cint; desired_channels: cint):
  ptr UncheckedArray[uint8] {.importc.}

proc stbi_failure_reason(): cstring {.importc.}

proc stbi_image_free(retval_from_stbi_load: pointer) {.importc.}

proc myRead(user: pointer; data: ptr uint8; size: cint): cint {.cdecl.} =
  return cint(stdin.readBuffer(data, size))

proc mySkip(user: pointer; n: cint) {.cdecl.} =
  var data: array[4096, uint8]
  let n = int(n)
  var i = 0
  while i < n:
    let j = stdin.readBuffer(addr data[0], n - i)
    if j < data.len:
      break
    i += j

proc myEof(user: pointer): cint {.cdecl.} =
  return cint(stdin.endOfFile())

type stbi_write_func = proc(context, data: pointer; size: cint) {.cdecl.}

proc stbi_write_png_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer; stride_in_bytes: cint) {.importc.}
proc stbi_write_bmp_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer) {.importc.}
proc stbi_write_jpg_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer; quality: cint) {.importc.}

proc myWriteFunc(context, data: pointer; size: cint) {.cdecl.} =
  discard stdout.writeBuffer(data, size)

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    if f notin ["jpeg", "gif", "bmp", "png"]:
      stdout.write("Cha-Control: ConnectionError 1 unknown format " & f)
    var x: cint
    var y: cint
    var channels_in_file: cint
    var clbk = stbi_io_callbacks(
      read: myRead,
      skip: mySkip,
      eof: myEof
    )
    let p = stbi_load_from_callbacks(addr clbk, nil, x, y, channels_in_file, 4)
    if p == nil:
      stdout.write("Cha-Control: ConnectionError 1 stbi error " &
        $stbi_failure_reason())
      return
    stdout.write("Cha-Image-Dimensions: " & $x & "x" & $y & "\n\n")
    discard stdout.writeBuffer(p, x * y * 4)
    stbi_image_free(p)
  of "encode":
    let headers = getEnv("REQUEST_HEADERS")
    var quality = cint(50)
    var width = cint(0)
    var height = cint(0)
    for hdr in headers.split('\n'):
      case hdr.until(':')
      of "Cha-Image-Dimensions":
        let s = hdr.after(':').strip().split('x')
        #TODO error handling
        let w = parseUInt32(s[0], allowSign = false)
        let h = parseUInt32(s[1], allowSign = false)
        if w.isNone or w.isNone:
          stdout.write("Cha-Control: ConnectionError 1 wrong dimensions")
          return
        width = cint(w.get)
        height = cint(h.get)
      of "Cha-Image-Quality":
        let s = hdr.after(':').strip()
        let q = parseUInt32(s, allowSign = false).get(101)
        if q < 1 or 100 < q:
          stdout.write("Cha-Control: ConnectionError 1 wrong quality")
          return
        quality = cint(q)
    let s = stdin.readAll()
    if s.len != width * height * 4:
      stdout.write("Cha-Control: ConnectionError 1 wrong size")
      return
    stdout.write("Cha-Image-Dimensions: " & $width & 'x' & $height & "\n\n")
    let p = unsafeAddr s[0]
    case f
    of "png":
      stbi_write_png_to_func(myWriteFunc, nil, cint(width), cint(height), 4, p,
        0)
    of "bmp":
      stbi_write_bmp_to_func(myWriteFunc, nil, cint(width), cint(height), 4, p)
    of "jpeg":
      stbi_write_jpg_to_func(myWriteFunc, nil, cint(width), cint(height), 4, p,
        quality)
    else:
      stdout.write("Cha-Control: ConnectionError 1 unknown format " & f)

main()
