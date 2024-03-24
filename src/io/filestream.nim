import io/dynstream

type
  DynFileStream* = ref object of DynStream
    file*: File

method recvData*(s: DynFileStream; buffer: pointer; len: int): int =
  let n = s.file.readBuffer(buffer, len)
  if n == 0:
    if unlikely(s.isend):
      raise newException(EOFError, "eof")
    s.isend = true
  return n

method sendData*(s: DynFileStream; buffer: pointer; len: int): int =
  return s.file.writeBuffer(buffer, len)

method seek*(s: DynFileStream; off: int) =
  s.file.setFilePos(int64(off))

method sclose*(s: DynFileStream) =
  s.file.close()

method sflush*(s: DynFileStream) =
  s.file.flushFile()

proc newDynFileStream*(file: File): DynFileStream =
  return DynFileStream(file: file, blocking: true)

proc newDynFileStream*(path: string): DynFileStream =
  var file: File
  if file.open(path):
    return newDynFileStream(path)
  return nil
