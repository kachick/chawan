# MultiStream: write to several streams at once when writing to a single
# stream.
# See TeeStream for a pull version.

import std/streams

type MultiStream = ref object of Stream
  s1: Stream
  s2: Stream

proc tsClose(s: Stream) =
  let s = cast[MultiStream](s)
  s.s1.close()
  s.s2.close()

proc msWriteData(s: Stream, buffer: pointer, bufLen: int) =
  let s = cast[MultiStream](s)
  s.s1.writeData(buffer, bufLen)
  s.s2.writeData(buffer, bufLen)

proc newMultiStream*(s1, s2: Stream, closedest = true): MultiStream =
  return MultiStream(
    s1: s1,
    s2: s2,
    closeImpl: tsClose,
    writeDataImpl: msWriteData
  )
