# Write data to streams in packets.
# Each packet is prefixed with its length as a pointer-sized integer.

import std/options
import std/sets
import std/tables

import io/dynstream
import types/blob
import types/color
import types/formdata
import types/opt
import types/url

type BufferedWriter* = object
  stream: DynStream
  buffer: ptr UncheckedArray[uint8]
  bufSize: int
  bufLen: int
  writeLen: bool

{.warning[Deprecated]: off.}:
  proc `=destroy`(writer: var BufferedWriter) =
    if writer.buffer != nil:
      dealloc(writer.buffer)
      writer.buffer = nil

proc initWriter*(stream: DynStream; sizeInit = 64; writeLen = false):
    BufferedWriter =
  var w = BufferedWriter(
    stream: stream,
    buffer: cast[ptr UncheckedArray[uint8]](alloc(sizeInit)),
    bufSize: sizeInit,
    bufLen: 0,
    writeLen: writeLen
  )
  if writeLen: # add space for `len'
    w.bufLen += sizeof(w.bufLen)
    assert w.bufLen < sizeInit
  return w

proc flush*(writer: var BufferedWriter) =
  if writer.writeLen:
    # subtract the length field's size
    var realLen = writer.bufLen - sizeof(writer.bufLen)
    copyMem(writer.buffer, addr realLen, sizeof(writer.bufLen))
  writer.stream.sendDataLoop(writer.buffer, writer.bufLen)
  writer.bufLen = 0
  writer.stream.sflush()

proc deinit*(writer: var BufferedWriter) =
  dealloc(writer.buffer)
  writer.buffer = nil
  writer.bufSize = 0
  writer.bufLen = 0

template withPacketWriter*(stream: DynStream; w, body: untyped) =
  block:
    var w = stream.initWriter(writeLen = true)
    body
    w.flush()
    w.deinit()

proc swrite*(writer: var BufferedWriter; n: SomeNumber)
proc swrite*[T](writer: var BufferedWriter; s: set[T])
proc swrite*[T: enum](writer: var BufferedWriter; x: T)
proc swrite*(writer: var BufferedWriter; s: string)
proc swrite*(writer: var BufferedWriter; b: bool)
proc swrite*(writer: var BufferedWriter; url: URL)
proc swrite*(writer: var BufferedWriter; tup: tuple)
proc swrite*[I, T](writer: var BufferedWriter; a: array[I, T])
proc swrite*(writer: var BufferedWriter; s: seq)
proc swrite*[U, V](writer: var BufferedWriter; t: Table[U, V])
proc swrite*(writer: var BufferedWriter; obj: object)
proc swrite*(writer: var BufferedWriter; obj: ref object)
proc swrite*(writer: var BufferedWriter; part: FormDataEntry)
proc swrite*(writer: var BufferedWriter; blob: Blob)
proc swrite*[T](writer: var BufferedWriter; o: Option[T])
proc swrite*[T, E](writer: var BufferedWriter; o: Result[T, E])
proc swrite*(writer: var BufferedWriter; c: ARGBColor) {.inline.}

proc writeData(writer: var BufferedWriter; buffer: pointer; len: int) =
  let targetLen = writer.bufLen + len
  let missing = targetLen - writer.bufSize
  if missing > 0:
    let target = writer.bufSize + missing
    writer.bufSize *= 2
    if writer.bufSize < target:
      writer.bufSize = target
    let p = realloc(writer.buffer, writer.bufSize)
    writer.buffer = cast[ptr UncheckedArray[uint8]](p)
  copyMem(addr writer.buffer[writer.bufLen], buffer, len)
  writer.bufLen = targetLen

proc swrite*(writer: var BufferedWriter; n: SomeNumber) =
  writer.writeData(unsafeAddr n, sizeof(n))

proc swrite*[T: enum](writer: var BufferedWriter; x: T) =
  static:
    doAssert sizeof(int) >= sizeof(T)
  writer.swrite(int(x))

proc swrite*[T](writer: var BufferedWriter; s: set[T]) =
  writer.swrite(s.card)
  for e in s:
    writer.swrite(e)

proc swrite*(writer: var BufferedWriter; s: string) =
  writer.swrite(s.len)
  if s.len > 0:
    writer.writeData(unsafeAddr s[0], s.len)

proc swrite*(writer: var BufferedWriter; b: bool) =
  if b:
    writer.swrite(1u8)
  else:
    writer.swrite(0u8)

proc swrite*(writer: var BufferedWriter; url: URL) =
  if url != nil:
    writer.swrite(url.serialize())
  else:
    writer.swrite("")

proc swrite*(writer: var BufferedWriter; tup: tuple) =
  for f in tup.fields:
    writer.swrite(f)

proc swrite*[I, T](writer: var BufferedWriter; a: array[I, T]) =
  for x in a:
    writer.swrite(x)

proc swrite*(writer: var BufferedWriter; s: seq) =
  writer.swrite(s.len)
  for x in s:
    writer.swrite(x)

proc swrite*[U, V](writer: var BufferedWriter; t: Table[U, V]) =
  writer.swrite(t.len)
  for k, v in t:
    writer.swrite(k)
    writer.swrite(v)

proc swrite*(writer: var BufferedWriter; obj: object) =
  for f in obj.fields:
    writer.swrite(f)

proc swrite*(writer: var BufferedWriter; obj: ref object) =
  writer.swrite(obj != nil)
  if obj != nil:
    writer.swrite(obj[])

proc swrite*(writer: var BufferedWriter; part: FormDataEntry) =
  writer.swrite(part.isstr)
  writer.swrite(part.name)
  writer.swrite(part.filename)
  if part.isstr:
    writer.swrite(part.svalue)
  else:
    writer.swrite(part.value)

#TODO clean up this mess
proc swrite*(writer: var BufferedWriter; blob: Blob) =
  writer.swrite(blob.isfile)
  if blob.isfile:
    writer.swrite(WebFile(blob).path)
  else:
    writer.swrite(blob.ctype)
    writer.swrite(blob.size)
    writer.writeData(blob.buffer, int(blob.size))

proc swrite*[T](writer: var BufferedWriter; o: Option[T]) =
  writer.swrite(o.isSome)
  if o.isSome:
    writer.swrite(o.get)

proc swrite*[T, E](writer: var BufferedWriter; o: Result[T, E]) =
  writer.swrite(o.isOk)
  if o.isOk:
    when not (T is void):
      writer.swrite(o.get)
  else:
    when not (E is void):
      writer.swrite(o.error)

proc swrite*(writer: var BufferedWriter; c: ARGBColor) =
  writer.swrite(uint32(c))
