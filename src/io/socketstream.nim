import nativesockets
import net
import os
import streams

when defined(posix):
  import posix

import io/posixstream
import io/serversocket

type SocketStream* = ref object of Stream
  source*: Socket
  blk*: bool
  isend: bool

proc sockReadData(s: Stream, buffer: pointer, len: int): int =
  assert len != 0
  let s = SocketStream(s)
  let wasend = s.isend
  let buffer = cast[ptr UncheckedArray[uint8]](buffer)
  if s.blk:
    while result < len:
      let n = s.source.recv(addr buffer[result], len - result)
      if n < 0:
        if result == 0:
          result = n
        break
      elif n == 0:
        s.isend = true
        break
      result += n
  else:
    result = s.source.recv(buffer, len)
  if result == 0:
    if wasend:
      raise newException(EOFError, "eof")
    s.isend = true
  if result < 0:
    raisePosixIOError()
  elif result == 0:
    s.isend = true

proc sockWriteData(s: Stream, buffer: pointer, len: int) =
  var i = 0
  let buffer = cast[ptr UncheckedArray[uint8]](buffer)
  while i < len:
    let n = SocketStream(s).source.send(addr buffer[i], len - i)
    if n < 0:
      raise newException(IOError, $strerror(errno))
    i += n

proc sockAtEnd(s: Stream): bool =
  SocketStream(s).isend

proc sockClose(s: Stream) = {.cast(tags: []).}: #...sigh
  let s = SocketStream(s)
  s.source.close()

{.compile: "sendfd.c".}
proc sendfd(sock: SocketHandle, fd: cint): int {.importc.}

# See https://stackoverflow.com/a/4491203
proc sendFileHandle*(s: SocketStream, fd: FileHandle) =
  assert not s.source.hasDataBuffered
  let n = sendfd(s.source.getFd(), cint(fd))
  if n < -1:
    raisePosixIOError()
  assert n == 1 # we send a single nul byte as buf

{.compile: "recvfd.c".}
proc recvfd(sock: SocketHandle, fdout: ptr cint): int {.importc.}

proc recvFileHandle*(s: SocketStream): FileHandle =
  assert not s.source.hasDataBuffered
  var fd: cint
  let n = recvfd(s.source.getFd(), addr fd)
  if n < 0:
    raisePosixIOError()
  return FileHandle(fd)

func newSocketStream*(): SocketStream =
  return SocketStream(
    readDataImpl: cast[proc (s: Stream, buffer: pointer, bufLen: int): int
        {.nimcall, raises: [Defect, IOError, OSError], tags: [ReadIOEffect], gcsafe.}
    ](sockReadData), # ... ???
    writeDataImpl: sockWriteData,
    atEndImpl: sockAtEnd,
    closeImpl: sockClose
  )

proc setBlocking*(ss: SocketStream, blocking: bool) =
  ss.source.getFd().setBlocking(blocking)

# see serversocket.nim for an explanation
{.compile: "connect_unix.c".}
proc connect_unix_from_c(fd: cint, path: cstring, pathlen: cint): cint {.importc.}

proc connectSocketStream*(path: string, buffered = true, blocking = true): SocketStream =
  result = newSocketStream()
  result.blk = blocking
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP, buffered)
  if not blocking:
    sock.getFd().setBlocking(false)
  if connect_unix_from_c(cint(sock.getFd()), cstring(path), cint(path.len)) != 0:
    raiseOSError(osLastError())
  result.source = sock

proc connectSocketStream*(pid: Pid, buffered = true, blocking = true): SocketStream =
  try:
    connectSocketStream(getSocketPath(pid), buffered, blocking)
  except OSError:
    return nil

proc acceptSocketStream*(ssock: ServerSocket, blocking = true): SocketStream =
  result = newSocketStream()
  result.blk = blocking
  var sock: Socket
  ssock.sock.accept(sock, inheritable = true)
  result.source = sock
