import std/options
import std/os
import std/posix
import std/strutils

import io/dynstream
import utils/sandbox
import utils/twtstr

{.passc: "-fno-strict-aliasing".}
{.passl: "-fno-strict-aliasing".}

{.compile("stb_image.c", "-O3").}

{.push header: "stb_image.h".}

type stbi_io_callbacks {.importc.} = object
  read: proc(user: pointer; data: ptr char; size: cint): cint {.cdecl.}
  skip: proc(user: pointer; n: cint) {.cdecl.}
  eof: proc(user: pointer): cint {.cdecl.}

proc stbi_load_from_callbacks(clbk: ptr stbi_io_callbacks; user: pointer;
  x, y, channels_in_file: var cint; desired_channels: cint):
  ptr uint8 {.importc.}

proc stbi_info_from_callbacks(clbk: ptr stbi_io_callbacks; user: pointer;
  x, y, comp: var cint): cint {.importc.}

proc stbi_failure_reason(): cstring {.importc.}

proc stbi_image_free(retval_from_stbi_load: pointer) {.importc.}

{.pop.}

type StbiUser = object
  atEof: bool

const STDIN_FILENO = 0
const STDOUT_FILENO = 1

proc myRead(user: pointer; data: ptr char; size: cint): cint {.cdecl.} =
  var n = cint(0)
  while n < size:
    let i = read(STDIN_FILENO, addr cast[ptr UncheckedArray[char]](data)[n],
      int(size - n))
    if i == 0:
      cast[ptr StbiUser](user)[].atEof = true
      break
    n += cint(i)
  return n

proc mySkip(user: pointer; size: cint) {.cdecl.} =
  var data: array[4096, uint8]
  var n = cint(0)
  while n < size:
    let i = read(STDIN_FILENO, addr data[0], min(int(size - n), data.len))
    if i == 0:
      cast[ptr StbiUser](user)[].atEof = true
      break
    n += cint(i)

proc myEof(user: pointer): cint {.cdecl.} =
  return cint(cast[ptr StbiUser](user)[].atEof)

type stbi_write_func = proc(context, data: pointer; size: cint) {.cdecl.}

{.push header: "stb_image_write.h".}
proc stbi_write_png_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer; stride_in_bytes: cint) {.importc.}
proc stbi_write_bmp_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer) {.importc.}
proc stbi_write_jpg_to_func(fun: stbi_write_func; context: pointer;
  w, h, comp: cint; data: pointer; quality: cint) {.importc.}
{.pop.}

proc writeAll(data: pointer; size: int) =
  var n = 0
  while n < size:
    let i = write(STDOUT_FILENO, addr cast[ptr UncheckedArray[uint8]](data)[n],
      int(size) - n)
    assert i >= 0
    n += i

proc myWriteFunc(context, data: pointer; size: cint) {.cdecl.} =
  writeAll(data, int(size))

{.push header: "stb_image_resize.h".}
proc stbir_resize_uint8(input_pixels: ptr uint8;
  input_w, input_h, input_stride_in_bytes: cint; output_pixels: ptr uint8;
  output_w, output_h, output_stride_in_bytes, num_channels: cint): cint
  {.importc.}
{.pop.}

proc puts(s: string) =
  if s.len > 0:
    writeAll(unsafeAddr s[0], s.len)

proc die(s: string) {.noreturn.} =
  puts(s)
  quit(1)

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  case getEnv("MAPPED_URI_PATH")
  of "decode":
    if f notin ["jpeg", "gif", "bmp", "png", "x-unknown"]:
      die("Cha-Control: ConnectionError 1 unknown format " & f)
    var user = StbiUser()
    var x: cint
    var y: cint
    var channels_in_file: cint
    var clbk = stbi_io_callbacks(
      read: myRead,
      skip: mySkip,
      eof: myEof
    )
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
          die("Cha-Control: ConnectionError 1 wrong dimensions\n")
        let w = parseUInt32(s[0], allowSign = false)
        let h = parseUInt32(s[1], allowSign = false)
        if w.isNone or w.isNone:
          die("Cha-Control: ConnectionError 1 wrong dimensions\n")
        targetWidth = cint(w.get)
        targetHeight = cint(h.get)
    if infoOnly:
      if stbi_info_from_callbacks(addr clbk, addr user, x, y,
          channels_in_file) == 1:
        puts("Cha-Image-Dimensions: " & $x & "x" & $y & "\n\n")
        quit(0)
      else:
        die("Cha-Control: ConnectionError 1 stbi error " &
          $stbi_failure_reason())
    let p = stbi_load_from_callbacks(addr clbk, addr user, x, y,
      channels_in_file, 4)
    if p == nil:
      die("Cha-Control: ConnectionError 1 stbi error " &
        $stbi_failure_reason())
    elif targetWidth != -1 and targetHeight != -1:
      let hdr = "Cha-Image-Dimensions: " & $targetWidth & "x" &
        $targetHeight & "\n\n"
      let p2 = cast[ptr UncheckedArray[uint8]](alloc(hdr.len +
        targetWidth * targetHeight * 4))
      copyMem(addr p2[0], unsafeAddr hdr[0], hdr.len)
      doAssert stbir_resize_uint8(p, x, y, 0, addr p2[hdr.len], targetWidth,
        targetHeight, 0, 4) == 1
      writeAll(p2, hdr.len + targetWidth * targetHeight * 4)
      dealloc(p2)
      stbi_image_free(p)
    else:
      puts("Cha-Image-Dimensions: " & $x & "x" & $y & "\n\n")
      writeAll(p, x * y * 4)
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
        let w = parseUInt32(s[0], allowSign = false)
        let h = parseUInt32(s[1], allowSign = false)
        if w.isNone or w.isNone:
          die("Cha-Control: ConnectionError 1 wrong dimensions")
        width = cint(w.get)
        height = cint(h.get)
      of "Cha-Image-Quality":
        let s = hdr.after(':').strip()
        let q = parseUInt32(s, allowSign = false).get(101)
        if q < 1 or 100 < q:
          die("Cha-Control: ConnectionError 1 wrong quality")
        quality = cint(q)
    let ps = newPosixStream(STDIN_FILENO)
    var s = newSeqUninitialized[uint8](width * height * 4)
    ps.recvDataLoop(s)
    puts("Cha-Image-Dimensions: " & $width & 'x' & $height & "\n\n")
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
      die("Cha-Control: ConnectionError 1 unknown format " & f)

main()
