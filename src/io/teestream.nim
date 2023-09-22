# TeeStream: write to another stream when reading from one stream.
# See MultiStream for a push version.

import streams

type TeeStream = ref object of Stream
  source: Stream
  dest: Stream
  closedest: bool

proc tsClose(s: Stream) =
  let s = cast[TeeStream](s)
  s.source.close()
  if s.closedest:
    s.dest.close()

proc tsReadData(s: Stream, buffer: pointer, bufLen: int): int =
  let s = cast[TeeStream](s)
  result = s.source.readData(buffer, bufLen)
  s.dest.writeData(buffer, result)

proc tsReadDataStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  let s = cast[TeeStream](s)
  result = s.source.readDataStr(buffer, slice)
  if result <= 0: return
  s.dest.writeData(addr buffer[0], result)

proc tsAtEnd(s: Stream): bool =
  let s = cast[TeeStream](s)
  return s.source.atEnd

proc newTeeStream*(source, dest: Stream, closedest = true): TeeStream =
  return TeeStream(
    source: source,
    dest: dest,
    closedest: closedest,
    closeImpl: tsClose,
    readDataImpl:
      cast[proc(s: Stream, buffer: pointer, len: int): int
      {.nimcall, raises: [Defect, IOError, OSError], tags: [ReadIOEffect], gcsafe.}
      ](tsReadData),
    readDataStrImpl:
      cast[proc(s: Stream, buffer: var string, slice: Slice[int]): int
      {.nimcall, raises: [Defect, IOError, OSError], tags: [ReadIOEffect], gcsafe.}
      ](tsReadDataStr),
    atEndImpl: tsAtEnd
  )
