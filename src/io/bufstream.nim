import io/dynstream
import io/posixstream

type
  BufStream* = ref object of DynStream
    source*: PosixStream
    registerFun: proc(fd: int)
    registered: bool
    writeBuffer: string

method recvData*(s: BufStream, buffer: pointer, len: int): int =
  s.source.recvData(buffer, len)

method sendData*(s: BufStream, buffer: pointer, len: int): int =
  s.source.setBlocking(false)
  block nobuf:
    var n: int
    if not s.registered:
      try:
        n = s.source.sendData(buffer, len)
        if n == len:
          break nobuf
      except ErrorAgain:
        discard
      s.registerFun(s.source.fd)
      s.registered = true
    let olen = s.writeBuffer.len
    s.writeBuffer.setLen(s.writeBuffer.len + len - n)
    let buffer = cast[ptr UncheckedArray[uint8]](buffer)
    copyMem(addr s.writeBuffer[olen], addr buffer[n], len - n)
  s.source.setBlocking(true)
  return len

method sclose*(s: BufStream) =
  s.source.sclose()

proc flushWrite*(s: BufStream): bool =
  s.source.setBlocking(false)
  let n = s.source.sendData(s.writeBuffer)
  s.source.setBlocking(true)
  if n == s.writeBuffer.len:
    s.writeBuffer = ""
    s.registered = false
    return true
  s.writeBuffer = s.writeBuffer.substr(n)
  return false

proc newBufStream*(ps: PosixStream, registerFun: proc(fd: int)): BufStream =
  result = BufStream(
    source: ps,
    blocking: ps.blocking,
    registerFun: registerFun
  )
  result.addStreamIface()
