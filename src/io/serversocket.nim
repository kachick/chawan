import std/nativesockets
import std/net
import std/os
when defined(posix):
  import posix

type ServerSocket* = object
  sock*: Socket
  path*: string

var SocketDirectory* = "/tmp/cha"
const SocketPathPrefix = "cha_sock_"
proc getSocketPath*(pid: Pid): string =
  SocketDirectory / SocketPathPrefix & $pid

# The way stdlib does bindUnix is utterly broken at least on FreeBSD.
# It seems that just writing it in C is the easiest solution.
{.compile: "bind_unix.c".}
proc bind_unix_from_c(fd: cint, path: cstring, pathlen: cint): cint {.importc.}

proc initServerSocket*(buffered = true, blocking = true): ServerSocket =
  createDir(SocketDirectory)
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP, buffered)
  if not blocking:
    sock.getFd().setBlocking(false)
  let path = getSocketPath(getpid())
  discard unlink(cstring(path))
  if bind_unix_from_c(cint(sock.getFd()), cstring(path), cint(path.len)) != 0:
    raiseOSError(osLastError())
  listen(sock)
  return ServerSocket(sock: sock, path: path)

proc close*(ssock: ServerSocket) =
  close(ssock.sock)
  discard unlink(cstring(ssock.path))
