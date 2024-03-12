# stdlib file handling is broken, so we use this instead of FileStream.
import std/posix

import io/dynstream

type
  PosixStream* = ref object of DynStream
    fd*: cint

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

method recvData*(s: PosixStream, buffer: pointer, len: int): int =
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

method sendData*(s: PosixStream, buffer: pointer, len: int): int =
  let n = write(s.fd, buffer, len)
  if n < 0:
    raisePosixIOError()
  return n

proc sendData*(s: PosixStream, buffer: openArray[char]): int {.inline.} =
  return s.sendData(unsafeAddr buffer[0], buffer.len)

proc sendData*(s: PosixStream, buffer: openArray[uint8]): int {.inline.} =
  return s.sendData(unsafeAddr buffer[0], buffer.len)

method setBlocking*(s: PosixStream, blocking: bool) {.base.} =
  s.blocking = blocking
  let ofl = fcntl(s.fd, F_GETFL, 0)
  if blocking:
    discard fcntl(s.fd, F_SETFL, ofl and not O_NONBLOCK)
  else:
    discard fcntl(s.fd, F_SETFL, ofl or O_NONBLOCK)

method seek*(s: PosixStream; off: int) =
  if lseek(s.fd, Off(off), SEEK_SET) == -1:
    raisePosixIOError()

method sclose*(s: PosixStream) =
  discard close(s.fd)

proc newPosixStream*(fd: FileHandle): PosixStream =
  let ps = PosixStream(fd: fd, blocking: true)
  ps.addStreamIface()
  return ps

proc newPosixStream*(path: string, flags, mode: cint): PosixStream =
  let fd = open(cstring(path), flags, mode)
  if fd == -1:
    return nil
  return newPosixStream(fd)
