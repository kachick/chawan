# stdlib file handling is broken, so we use this instead of FileStream.
import posix
import streams

type
  PosixStream* = ref object of Stream
    fd*: FileHandle

  ErrorAgain* = object of IOError
  ErrorWouldBlock* = object of IOError
  ErrorBadFD* = object of IOError
  ErrorFault* = object of IOError
  ErrorInterrupted* = object of IOError
  ErrorInvalid* = object of IOError

proc psReadData(s: Stream, buffer: pointer, len: int): int =
  let s = cast[PosixStream](s)
  result = read(s.fd, buffer, len)
  if result == -1:
    if errno == EAGAIN:
      raise newException(ErrorAgain, "")
    case errno
    of EWOULDBLOCK: raise newException(ErrorWouldBlock, "")
    of EBADF: raise newException(ErrorBadFD, "")
    of EFAULT: raise newException(ErrorFault, "")
    of EINVAL: raise newException(ErrorInvalid, "")
    else: raise newException(IOError, $strerror(errno))

proc psWriteData(s: Stream, buffer: pointer, len: int) =
  let s = cast[PosixStream](s)
  let res = write(s.fd, buffer, len)
  if res == -1:
    raise newException(IOError, $strerror(errno))

proc newPosixStream*(fd: FileHandle): PosixStream =
  return PosixStream(
    fd: fd,
    readDataImpl: psReadData,
    writeDataImpl: psWriteData
  )
