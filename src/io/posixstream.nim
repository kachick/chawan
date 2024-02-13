# stdlib file handling is broken, so we use this instead of FileStream.
import std/posix
import std/streams

type
  PosixStream* = ref object of Stream
    fd*: cint
    isend*: bool

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

proc psClose(s: Stream) =
  let s = cast[PosixStream](s)
  discard close(s.fd)

proc psReadData(s: Stream, buffer: pointer, len: int): int =
  assert len != 0
  let s = cast[PosixStream](s)
  let wasend = s.isend
  let buffer = cast[ptr UncheckedArray[uint8]](buffer)
  while result < len:
    let n = read(s.fd, addr buffer[result], len - result)
    if n < 0:
      if result == 0:
        result = n
      break
    elif n == 0:
      s.isend = true
      break
    result += n
  if result == 0:
    if wasend:
      raise newException(EOFError, "eof")
    s.isend = true
  if result == -1:
    raisePosixIOError()

method recvData*(s: PosixStream, buffer: pointer, len: int): int {.base.} =
  let n = read(s.fd, buffer, len)
  if n < 0:
    raisePosixIOError()
  if n == 0:
    if unlikely(s.isend):
      raise newException(EOFError, "eof")
    s.isend = true
  return n

method sendData*(s: PosixStream, buffer: pointer, len: int): int {.base.} =
  #TODO use sendData instead
  let n = write(s.fd, buffer, len)
  if n < 0:
    raisePosixIOError()
  return n

method setBlocking*(s: PosixStream, blocking: bool) {.base.} =
  let ofl = fcntl(s.fd, F_GETFL, 0)
  if blocking:
    discard fcntl(s.fd, F_SETFL, ofl and not O_NONBLOCK)
  else:
    discard fcntl(s.fd, F_SETFL, ofl or O_NONBLOCK)

proc psWriteData(s: Stream, buffer: pointer, len: int) =
  #TODO use sendData instead
  let s = cast[PosixStream](s)
  let res = write(s.fd, buffer, len)
  if res == -1:
    raisePosixIOError()

proc psAtEnd(s: Stream): bool =
  return cast[PosixStream](s).isend

proc newPosixStream*(fd: FileHandle): PosixStream =
  return PosixStream(
    fd: fd,
    closeImpl: psClose,
    readDataImpl: psReadData,
    writeDataImpl: psWriteData,
    atEndImpl: psAtEnd
  )

proc newPosixStream*(path: string, flags, mode: cint): PosixStream =
  let fd = open(cstring(path), flags, mode)
  if fd == -1:
    return nil
  return newPosixStream(fd)
