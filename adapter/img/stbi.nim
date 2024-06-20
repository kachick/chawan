import std/os

import utils/sandbox
import utils/twtstr

{.compile: "stb_image.c".}

type stbi_io_callbacks = object
  read: proc(user: pointer; data: ptr uint8; size: cint): cint {.cdecl.}
  skip: proc(user: pointer; n: cint) {.cdecl.}
  eof: proc(user: pointer): cint {.cdecl.}

proc stbi_load_from_callbacks(clbk: ptr stbi_io_callbacks; user: pointer;
  x, y, channels_in_file: var cint; desired_channels: cint):
  ptr UncheckedArray[uint8] {.importc.}

proc stbi_failure_reason(): cstring {.importc.}

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

proc main() =
  enterNetworkSandbox()
  let scheme = getEnv("MAPPED_URI_SCHEME")
  let f = scheme.after('+')
  if f notin ["jpeg", "gif", "bmp", "png"]:
    stdout.write("Cha-Control: ConnectionError 1 wrong format " & f)
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

main()
