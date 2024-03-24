import std/nativesockets
import std/net
import std/os

import io/dynstream
import io/posixstream
import io/serversocket

type SocketStream* = ref object of PosixStream
  source*: Socket

method recvData*(s: SocketStream, buffer: pointer, len: int): int =
  let n = s.source.recv(buffer, len)
  if n < 0:
    raisePosixIOError()
  if n == 0:
    if unlikely(s.isend):
      raise newException(EOFError, "eof")
    s.isend = true
  return n

method sendData*(s: SocketStream, buffer: pointer, len: int): int =
  let n = s.source.send(buffer, len)
  if n < 0:
    raisePosixIOError()
  return n

{.compile: "sendfd.c".}
proc sendfd(sock, fd: cint): int {.importc.}

proc sendFileHandle*(s: SocketStream, fd: FileHandle) =
  assert not s.source.hasDataBuffered
  let n = sendfd(s.fd, cint(fd))
  if n < 0:
    raisePosixIOError()
  assert n == 1 # we send a single nul byte as buf

{.compile: "recvfd.c".}
proc recvfd(sock: cint, fdout: ptr cint): int {.importc.}

proc recvFileHandle*(s: SocketStream): FileHandle =
  assert not s.source.hasDataBuffered
  var fd: cint
  let n = recvfd(s.fd, addr fd)
  if n < 0:
    raisePosixIOError()
  return FileHandle(fd)

method setBlocking*(s: SocketStream, blocking: bool) =
  s.blocking = blocking
  s.source.getFd().setBlocking(blocking)

method seek*(s: PosixStream; off: int) =
  doAssert false

method sclose*(s: SocketStream) =
  s.source.close()

# see serversocket.nim for an explanation
{.compile: "connect_unix.c".}
proc connect_unix_from_c(fd: cint, path: cstring, pathlen: cint): cint
  {.importc.}

proc connectSocketStream*(path: string; blocking = true): SocketStream =
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
    Protocol.IPPROTO_IP, buffered = false)
  if not blocking:
    sock.getFd().setBlocking(false)
  if connect_unix_from_c(cint(sock.getFd()), cstring(path),
      cint(path.len)) != 0:
    raiseOSError(osLastError())
  return SocketStream(
    source: sock,
    fd: cint(sock.getFd()),
    blocking: blocking
  )

proc connectSocketStream*(pid: int; blocking = true):
    SocketStream =
  try:
    return connectSocketStream(getSocketPath(pid), blocking)
  except OSError:
    return nil

proc acceptSocketStream*(ssock: ServerSocket, blocking = true): SocketStream =
  var sock: Socket
  ssock.sock.accept(sock, inheritable = true)
  if not blocking:
    sock.getFd().setBlocking(false)
  return SocketStream(
    blocking: blocking,
    source: sock,
    fd: cint(sock.getFd())
  )
