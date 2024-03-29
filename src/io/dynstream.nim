type
  DynStream* = ref object of RootObj
    isend*: bool
    blocking*: bool #TODO move to posixstream

# Semantics of this function are those of POSIX read(2): that is, it may return
# a result that is lower than `len`, and that does not mean the stream is
# finished.
# isend must be set by implementations when the end of the stream is reached.
# An exception should be raised if recvData is called with the 'isend' flag set
# to true.
method recvData*(s: DynStream; buffer: pointer; len: int): int {.base.} =
  assert false

# See above, but with write(2)
method sendData*(s: DynStream; buffer: pointer; len: int): int {.base.} =
  assert false

method seek*(s: DynStream; off: int) {.base.} =
  assert false

method sclose*(s: DynStream) {.base.} =
  assert false

method sflush*(s: DynStream) {.base.} =
  discard

proc recvData*(s: DynStream; buffer: var openArray[uint8]): int {.inline.} =
  return s.recvData(addr buffer[0], buffer.len)

proc recvData*(s: DynStream; buffer: var openArray[char]): int {.inline.} =
  return s.recvData(addr buffer[0], buffer.len)

proc sendData*(s: DynStream; buffer: openArray[char]): int {.inline.} =
  return s.sendData(unsafeAddr buffer[0], buffer.len)

proc sendData*(s: DynStream; buffer: openArray[uint8]): int {.inline.} =
  return s.sendData(unsafeAddr buffer[0], buffer.len)

proc sendDataLoop*(s: DynStream; buffer: pointer; len: int) =
  var n = 0
  while true:
    n += s.sendData(addr cast[ptr UncheckedArray[uint8]](buffer)[n], len - n)
    if n == len:
      break

proc sendDataLoop*(s: DynStream; buffer: openArray[uint8]) {.inline.} =
  s.sendDataLoop(unsafeAddr buffer[0], buffer.len)

proc sendDataLoop*(s: DynStream; buffer: openArray[char]) {.inline.} =
  s.sendDataLoop(unsafeAddr buffer[0], buffer.len)

proc write*(s: DynStream; buffer: openArray[char]) {.inline.} =
  s.sendDataLoop(buffer)

proc write*(s: DynStream; c: char) {.inline.} =
  s.sendDataLoop(unsafeAddr c, 1)

proc sreadChar*(s: DynStream): char =
  let n = s.recvData(addr result, 1)
  assert n == 1

proc recvDataLoop*(s: DynStream; buffer: pointer; len: int) =
  var n = 0
  while true:
    n += s.recvData(addr cast[ptr UncheckedArray[uint8]](buffer)[n], len - n)
    if n == len:
      break

proc recvDataLoop*(s: DynStream; buffer: var openArray[uint8]) {.inline.} =
  s.recvDataLoop(addr buffer[0], buffer.len)

proc recvAll*(s: DynStream): string =
  var buffer = newString(4096)
  var idx = 0
  while true:
    let n = s.recvData(addr buffer[idx], buffer.len - idx)
    if n == 0:
      break
    idx += n
    if idx == buffer.len:
      buffer.setLen(buffer.len + 4096)
  buffer.setLen(idx)
  return buffer
