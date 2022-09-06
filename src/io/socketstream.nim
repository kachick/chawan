import net
import streams

type SocketStream* = ref object of Stream
  isource: Socket
  osource: Socket
  isend: bool

proc sockReadData(s: Stream, buffer: pointer, len: int): int =
  let s = SocketStream(s)
  result = s.isource.recv(buffer, len)
  if result < 0:
    raise newException(Defect, "Failed to read data")
  elif result < len:
    s.isend = true

proc sockWriteData(s: Stream, buffer: pointer, len: int) =
  discard SocketStream(s).osource.send(buffer, len)

proc sockAtEnd(s: Stream): bool =
  SocketStream(s).isend

proc sockClose(s: Stream) = {.cast(tags: []).}: #...sigh
  let s = SocketStream(s)
  if s.isource != nil:
    s.isource.close()
  if s.osource != nil and s.isource != s.osource:
    s.osource.close()

func newSocketStream*(isource, osource: Socket): SocketStream =
  new(result)
  result.isource = isource
  result.osource = osource
  result.readDataImpl = sockReadData
  result.writeDataImpl = sockWriteData
  result.atEndImpl = sockAtEnd
  result.closeImpl = sockClose
