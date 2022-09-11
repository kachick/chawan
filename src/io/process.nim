import net
import os
when defined(posix):
  import posix

type ServerSocket* = object
  sock*: Socket
  path*: string

proc doFork*(): Pid =
  result = fork()
  if result == -1:
    eprint "Failed to fork child process."
    quit(1)
  elif result != 0:
    return result
  discard setsid()
  let pid = fork()
  if pid != 0:
    quit(0)
  return 0

const SocketDirectory = "/tmp/cha/"
const SocketPathPrefix = SocketDirectory & "cha_sock_"
func getSocketPath*(pid: Pid): string =
  SocketPathPrefix & $pid

proc initServerSocket*(pid: Pid): ServerSocket =
  createDir(SocketDirectory)
  result.sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  result.path = getSocketPath(getpid())
  discard unlink(cstring(result.path))
  bindUnix(result.sock, result.path)
  listen(result.sock)

proc close*(ssock: ServerSocket) =
  close(ssock.sock)
  discard unlink(cstring(ssock.path))
