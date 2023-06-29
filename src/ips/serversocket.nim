import nativesockets
import net
import os
when defined(posix):
  import posix

type ServerSocket* = object
  sock*: Socket
  path*: string

var SocketDirectory* = "/tmp/cha"
const SocketPathPrefix = "cha_sock_"
proc getSocketPath*(pid: Pid): string =
  SocketDirectory / SocketPathPrefix & $pid

proc initServerSocket*(buffered = true, blocking = true): ServerSocket =
  createDir(SocketDirectory)
  result.sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP, buffered)
  if not blocking:
    result.sock.getFd().setBlocking(false)
  result.path = getSocketPath(getpid())
  discard unlink(cstring(result.path))
  bindUnix(result.sock, result.path)
  listen(result.sock)

proc close*(ssock: ServerSocket) =
  close(ssock.sock)
  discard unlink(cstring(ssock.path))
