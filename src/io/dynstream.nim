import std/streams

type
  DynStream* = ref object of Stream #TODO should be of RootObj
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

proc dsClose(s: Stream) =
  DynStream(s).sclose()

proc dsReadData(s: Stream, buffer: pointer, len: int): int =
  let s = DynStream(s)
  assert len != 0 and s.blocking
  result = 0
  while result < len:
    let p = addr cast[ptr UncheckedArray[uint8]](buffer)[result]
    let n = s.recvData(p, len - result)
    if n == 0:
      break
    result += n

proc dsWriteData(s: Stream, buffer: pointer, len: int) =
  let s = DynStream(s)
  assert len != 0 and s.blocking
  discard s.sendData(buffer, len)

proc dsReadLine(s: Stream, line: var string): bool =
  let s = DynStream(s)
  assert s.blocking
  line = ""
  var c: char
  while true:
    if s.recvData(addr c, 1) == 0:
      return false
    if c == '\r':
      if s.recvData(addr c, 1) == 0:
        return false
    if c == '\n':
      break
    line &= c
  true

proc dsAtEnd(s: Stream): bool =
  return DynStream(s).isend

proc addStreamIface*(s: DynStream) =
  s.closeImpl = cast[typeof(s.closeImpl)](dsClose)
  s.readDataImpl = cast[typeof(s.readDataImpl)](dsReadData)
  s.writeDataImpl = cast[typeof(s.writeDataImpl)](dsWriteData)
  s.readLineImpl = cast[typeof(s.readLineImpl)](dsReadLine)
  s.atEndImpl = dsAtEnd
