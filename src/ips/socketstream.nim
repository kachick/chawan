import nativesockets
import net
import os
import streams

when defined(posix):
  import posix

import io/posixstream
import ips/serversocket

type SocketStream* = ref object of Stream
  source*: Socket
  blk*: bool
  isend: bool

proc sockReadData(s: Stream, buffer: pointer, len: int): int =
  assert len != 0
  let s = SocketStream(s)
  if s.blk:
    while result < len:
      let n = s.source.recv(cast[pointer](cast[int](buffer) + result), len - result)
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
    s.isend = true
    raise newException(EOFError, "eof")
  if result < 0:
    if errno == EAGAIN:
      raise newException(ErrorAgain, "eagain")
    case errno
    of EWOULDBLOCK: raise newException(ErrorWouldBlock, "would block")
    of EBADF: raise newException(ErrorBadFD, "bad fd")
    of EFAULT: raise newException(ErrorFault, "fault")
    of EINVAL: raise newException(ErrorInvalid, "invalid")
    else: raise newException(IOError, $strerror(errno))
  elif result == 0:
    s.isend = true

proc sockWriteData(s: Stream, buffer: pointer, len: int) =
  #TODO maybe don't block if blk is false?
  var i = 0
  while i < len:
    let n = SocketStream(s).source.send(cast[pointer](cast[int](buffer) + i), len - i)
    if n < 0:
      raise newException(IOError, $strerror(errno))
    i += n

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
  # ...sigh
  {.emit: [
  cmsg.cmsg_len, """ = CMSG_LEN(sizeof(int));"""
  ].}
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
  result.blk = blocking
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

proc acceptSocketStream*(ssock: ServerSocket, blocking = true): SocketStream =
  result = newSocketStream()
  result.blk = blocking
  var sock: Socket
  ssock.sock.accept(sock, inheritable = true)
  result.source = sock
