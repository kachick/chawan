import std/nativesockets
import std/net
import std/os

when defined(posix):
  import std/posix

type ServerSocket* = object
  sock*: Socket
  path*: string

const SocketPathPrefix = "cha_sock_"
proc getSocketName*(pid: int): string =
  SocketPathPrefix & $pid

proc getSocketPath*(socketDir: string; pid: int): string =
  socketDir / getSocketName(pid)

# The way stdlib does bindUnix is utterly broken at least on FreeBSD.
# It seems that just writing it in C is the easiest solution.
{.compile: "bind_unix.c".}
proc bind_unix_from_c(fd: cint; path: cstring; pathlen: cint): cint
  {.importc.}

when defined(freebsd):
  # capsicum stuff
  proc unlinkat(dfd: cint; path: cstring; flag: cint): cint
    {.importc, header: "<unistd.h>".}
  proc bindat_unix_from_c(dfd, sock: cint; path: cstring; pathlen: cint): cint
    {.importc.}

proc initServerSocket*(sockDir: string; sockDirFd, pid: int; blocking = true):
    ServerSocket =
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
    Protocol.IPPROTO_IP, buffered = false)
  if not blocking:
    sock.getFd().setBlocking(false)
  let path = getSocketPath(sockDir, pid)
  if sockDirFd == -1:
    discard unlink(cstring(path))
    if bind_unix_from_c(cint(sock.getFd()), cstring(path), cint(path.len)) != 0:
      raiseOSError(osLastError())
  else:
    when defined(freebsd):
      let name = getSocketName(pid)
      discard unlinkat(cint(sockDirFd), cstring(name), 0)
      if bindat_unix_from_c(cint(sockDirFd), cint(sock.getFd()), cstring(name),
          cint(name.len)) != 0:
        raiseOSError(osLastError())
  listen(sock)
  return ServerSocket(sock: sock, path: path)

proc close*(ssock: ServerSocket) =
  close(ssock.sock)
  discard unlink(cstring(ssock.path))
