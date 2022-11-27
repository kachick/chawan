import nativesockets
import net
import os
import streams

when defined(posix):
  import posix

import ips/serversocket

type SocketStream* = ref object of Stream
  source*: Socket
  recvw*: bool
  isend: bool

proc sockReadData(s: Stream, buffer: pointer, len: int): int =
  let s = SocketStream(s)
  result = s.source.recv(buffer, len)
  if result < 0:
    raise newException(IOError, "Failed to read data (code " & $osLastError() & ")")
  elif result < len:
    s.isend = true

proc sockWriteData(s: Stream, buffer: pointer, len: int) =
  discard SocketStream(s).source.send(buffer, len)

proc sockAtEnd(s: Stream): bool =
  SocketStream(s).isend

proc sockClose(s: Stream) = {.cast(tags: []).}: #...sigh
  let s = SocketStream(s)
  s.source.close()

# See https://stackoverflow.com/a/4491203
proc sendFileHandle*(s: SocketStream, fd: FileHandle) =
  var hdr: Tmsghdr
  var iov: IOVec
  var cmsgbuf = alloc(CMSG_SPACE(csize_t(sizeof(FileHandle))))
  var buf = char(0)
  iov.iov_base = addr buf
  iov.iov_len = csize_t(1)
  zeroMem(addr hdr, sizeof(hdr))
  hdr.msg_iov = addr iov
  hdr.msg_iovlen = 1
  hdr.msg_control = cmsgbuf
  hdr.msg_controllen = CMSG_LEN(csize_t(sizeof(FileHandle)))
  let cmsg = CMSG_FIRSTHDR(addr hdr)
  cmsg.cmsg_len = CMSG_LEN(csize_t(sizeof(FileHandle)))
  cmsg.cmsg_level = SOL_SOCKET
  cmsg.cmsg_type = SCM_RIGHTS
  cast[ptr FileHandle](CMSG_DATA(cmsg))[] = fd
  let n = sendmsg(s.source.getFd(), addr hdr, 0)
  dealloc(cmsgbuf)
  assert n == int(iov.iov_len) #TODO remove this

proc recvFileHandle*(s: SocketStream): FileHandle =
  var iov: IOVec
  var hdr: Tmsghdr
  let space = CMSG_SPACE(csize_t(sizeof(FileHandle)))
  var buf: char
  var cmsgbuf = alloc(space)
  iov.iov_base = addr buf
  iov.iov_len = 1
  zeroMem(addr hdr, sizeof(hdr))
  hdr.msg_iov = addr iov
  hdr.msg_iovlen = 1
  hdr.msg_control = cmsgbuf
  hdr.msg_controllen = space
  let n = recvmsg(s.source.getFd(), addr hdr, 0)
  assert n != 0, "Unexpected EOF" #TODO remove this
  assert n > 0, "Failed to receive message " & $osLastError() #TODO remove this
  var cmsg = CMSG_FIRSTHDR(addr hdr)
  result = cast[ptr FileHandle](CMSG_DATA(cmsg))[]
  dealloc(cmsgbuf)

func newSocketStream*(): SocketStream =
  new(result)
  result.readDataImpl = cast[proc (s: Stream, buffer: pointer, bufLen: int): int
      {.nimcall, raises: [Defect, IOError, OSError], tags: [ReadIOEffect], gcsafe.}
  ](sockReadData) # ... ???
  result.writeDataImpl = sockWriteData
  result.atEndImpl = sockAtEnd
  result.closeImpl = sockClose

proc connectSocketStream*(path: string, buffered = true, blocking = true): SocketStream =
  result = newSocketStream()
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP, buffered)
  #if not blocking:
  #  sock.getFd().setBlocking(false)
  connectUnix(sock, path)
  result.source = sock

proc connectSocketStream*(pid: Pid, buffered = true, blocking = true): SocketStream =
  try:
    connectSocketStream(getSocketPath(pid), buffered, blocking)
  except OSError:
    return nil

proc acceptSocketStream*(ssock: ServerSocket): SocketStream =
  result = newSocketStream()
  var sock: Socket
  ssock.sock.accept(sock, inheritable = true)
  result.source = sock
