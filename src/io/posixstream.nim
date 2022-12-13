# stdlib file handling is broken, so we use this instead of FileStream.
import posix
import streams

type
  PosixStream* = ref object of Stream
    fd*: FileHandle
    isend*: bool

  ErrorAgain* = object of IOError
  ErrorWouldBlock* = object of IOError
  ErrorBadFD* = object of IOError
  ErrorFault* = object of IOError
  ErrorInterrupted* = object of IOError
  ErrorInvalid* = object of IOError

proc psReadData(s: Stream, buffer: pointer, len: int): int =
  assert len != 0
  let s = cast[PosixStream](s)
  while result < len:
    let n = read(s.fd, buffer, len)
    if n < 0:
      if result == 0:
        result = n
      break
    elif n == 0:
      s.isend = true
      break
    result += n
  if result == 0:
    raise newException(EOFError, "eof")
  if result == -1:
    if errno == EAGAIN:
      raise newException(ErrorAgain, "eagain")
    case errno
    of EWOULDBLOCK: raise newException(ErrorWouldBlock, "would block")
    of EBADF: raise newException(ErrorBadFD, "bad fd")
    of EFAULT: raise newException(ErrorFault, "fault")
    of EINVAL: raise newException(ErrorInvalid, "invalid")
    else: raise newException(IOError, $strerror(errno) & " (" & $errno & ")")

proc psWriteData(s: Stream, buffer: pointer, len: int) =
  let s = cast[PosixStream](s)
  let res = write(s.fd, buffer, len)
  if res == -1:
    raise newException(IOError, $strerror(errno))

proc psAtEnd(s: Stream): bool =
  return cast[PosixStream](s).isend

proc newPosixStream*(fd: FileHandle): PosixStream =
  return PosixStream(
    fd: fd,
    readDataImpl: psReadData,
    writeDataImpl: psWriteData,
    atEndImpl: psAtEnd
  )
