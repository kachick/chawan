import nativesockets
import net
import streams

when defined(posix):
  import posix

import ips/serversocket

type SocketStream* = ref object of Stream
  source*: Socket
  isend: bool

proc sockReadData(s: Stream, buffer: pointer, len: int): int =
  let s = SocketStream(s)
  result = s.source.recv(buffer, len)
  if result < 0:
    raise newException(Defect, "Failed to read data")
  elif result < len:
    s.isend = true

proc sockWriteData(s: Stream, buffer: pointer, len: int) =
  discard SocketStream(s).source.send(buffer, len)

proc sockAtEnd(s: Stream): bool =
  SocketStream(s).isend

proc sockClose(s: Stream) = {.cast(tags: []).}: #...sigh
  let s = SocketStream(s)
  s.source.close()

func newSocketStream*(): SocketStream =
  new(result)
  result.readDataImpl = cast[proc (s: Stream, buffer: pointer, bufLen: int): int
      {.nimcall, raises: [Defect, IOError, OSError], tags: [ReadIOEffect], gcsafe.}
  ](sockReadData) # ... ???
  result.writeDataImpl = sockWriteData
  result.atEndImpl = sockAtEnd
  result.closeImpl = sockClose

proc connectSocketStream*(path: string): SocketStream =
  result = newSocketStream()
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  connectUnix(sock, path)
  result.source = sock

proc connectSocketStream*(pid: Pid): SocketStream =
  connectSocketStream(getSocketPath(pid))

proc acceptSocketStream*(ssock: ServerSocket): SocketStream =
  result = newSocketStream()
  var sock: Socket
  ssock.sock.accept(sock)
  result.source = sock
