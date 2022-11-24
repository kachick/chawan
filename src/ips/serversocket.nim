import net
import os
when defined(posix):
  import posix

type ServerSocket* = object
  sock*: Socket
  path*: string

const SocketDirectory = "/tmp/cha/"
const SocketPathPrefix = SocketDirectory & "cha_sock_"
func getSocketPath*(pid: Pid): string =
  SocketPathPrefix & $pid

proc initServerSocket*(buffered = true): ServerSocket =
  createDir(SocketDirectory)
  result.sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP, buffered)
  result.path = getSocketPath(getpid())
  discard unlink(cstring(result.path))
  bindUnix(result.sock, result.path)
  listen(result.sock)

proc close*(ssock: ServerSocket) =
  close(ssock.sock)
  discard unlink(cstring(ssock.path))
