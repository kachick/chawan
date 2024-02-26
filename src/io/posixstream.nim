# stdlib file handling is broken, so we use this instead of FileStream.
import std/posix
import std/streams

type
  PosixStream* = ref object of Stream
    fd*: cint
    isend*: bool
    blocking*: bool

  ErrorAgain* = object of IOError
  ErrorBadFD* = object of IOError
  ErrorFault* = object of IOError
  ErrorInterrupted* = object of IOError
  ErrorInvalid* = object of IOError
  ErrorConnectionReset* = object of IOError
  ErrorBrokenPipe* = object of IOError

proc raisePosixIOError*() =
  # In the nim stdlib, these are only constants on linux amd64, so we
  # can't use a switch.
  if errno == EAGAIN or errno == EWOULDBLOCK:
    raise newException(ErrorAgain, "eagain")
  elif errno == EBADF:
    raise newException(ErrorBadFD, "bad fd")
  elif errno == EFAULT:
    raise newException(ErrorFault, "fault")
  elif errno == EINVAL:
    raise newException(ErrorInvalid, "invalid")
  elif errno == ECONNRESET:
    raise newException(ErrorConnectionReset, "connection reset by peer")
  elif errno == EPIPE:
    raise newException(ErrorBrokenPipe, "broken pipe")
  else:
    raise newException(IOError, $strerror(errno))

method recvData*(s: PosixStream, buffer: pointer, len: int): int {.base.} =
  let n = read(s.fd, buffer, len)
  if n < 0:
    raisePosixIOError()
  if n == 0:
    if unlikely(s.isend):
      raise newException(EOFError, "eof")
    s.isend = true
  return n

proc recvData*(s: PosixStream, buffer: var openArray[uint8]): int {.inline.} =
  return s.recvData(addr buffer[0], buffer.len)

proc recvData*(s: PosixStream, buffer: var openArray[char]): int {.inline.} =
  return s.recvData(addr buffer[0], buffer.len)

method sendData*(s: PosixStream, buffer: pointer, len: int): int {.base.} =
  let n = write(s.fd, buffer, len)
  if n < 0:
    raisePosixIOError()
  return n

method setBlocking*(s: PosixStream, blocking: bool) {.base.} =
  s.blocking = blocking
  let ofl = fcntl(s.fd, F_GETFL, 0)
  if blocking:
    discard fcntl(s.fd, F_SETFL, ofl and not O_NONBLOCK)
  else:
    discard fcntl(s.fd, F_SETFL, ofl or O_NONBLOCK)

method sclose*(s: PosixStream) {.base.} =
  discard close(s.fd)

proc psClose(s: Stream) =
  PosixStream(s).sclose()

proc psReadData(s: Stream, buffer: pointer, len: int): int =
  let s = PosixStream(s)
  assert len != 0 and s.blocking
  result = 0
  while result < len:
    let p = addr cast[ptr UncheckedArray[uint8]](buffer)[result]
    let n = s.recvData(p, len - result)
    if n == 0:
      break
    result += n

proc psWriteData(s: Stream, buffer: pointer, len: int) =
  let s = PosixStream(s)
  assert len != 0 and s.blocking
  discard s.sendData(buffer, len)

proc psAtEnd(s: Stream): bool =
  return PosixStream(s).isend

proc addStreamIface*(ps: PosixStream) =
  ps.closeImpl = cast[typeof(ps.closeImpl)](psClose)
  ps.readDataImpl = cast[typeof(ps.readDataImpl)](psReadData)
  ps.writeDataImpl = cast[typeof(ps.writeDataImpl)](psWriteData)
  ps.atEndImpl = psAtEnd

proc newPosixStream*(fd: FileHandle): PosixStream =
  let ps = PosixStream(fd: fd, blocking: true)
  ps.addStreamIface()
  return ps

proc newPosixStream*(path: string, flags, mode: cint): PosixStream =
  let fd = open(cstring(path), flags, mode)
  if fd == -1:
    return nil
  return newPosixStream(fd)
