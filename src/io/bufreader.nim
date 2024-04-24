# Write data to streams.

import std/options
import std/sets
import std/tables

import io/dynstream
import types/blob
import types/color
import types/formdata
import types/opt
import types/url

type BufferedReader* = object
  buffer: seq[uint8]
  bufIdx: int

proc initReader*(stream: DynStream; len: int): BufferedReader =
  assert len != 0
  var reader = BufferedReader(
    buffer: newSeqUninitialized[uint8](len),
    bufIdx: 0
  )
  var n = 0
  while true:
    n += stream.recvData(addr reader.buffer[n], len - n)
    if n == len:
      break
  return reader

proc initPacketReader*(stream: DynStream): BufferedReader =
  var len: int
  stream.recvDataLoop(addr len, sizeof(len))
  return stream.initReader(len)

template withPacketReader*(stream: DynStream; r, body: untyped) =
  block:
    var r = stream.initPacketReader()
    body

proc sread*(reader: var BufferedReader; n: var SomeNumber)
proc sread*[T](reader: var BufferedReader; s: var set[T])
proc sread*[T: enum](reader: var BufferedReader; x: var T)
proc sread*(reader: var BufferedReader; s: var string)
proc sread*(reader: var BufferedReader; b: var bool)
proc sread*(reader: var BufferedReader; url: var URL)
proc sread*(reader: var BufferedReader; tup: var tuple)
proc sread*[I, T](reader: var BufferedReader; a: var array[I, T])
proc sread*(reader: var BufferedReader; s: var seq)
proc sread*[U, V](reader: var BufferedReader; t: var Table[U, V])
proc sread*(reader: var BufferedReader; obj: var object)
proc sread*(reader: var BufferedReader; obj: var ref object)
proc sread*(reader: var BufferedReader; part: var FormDataEntry)
proc sread*(reader: var BufferedReader; blob: var Blob)
proc sread*[T](reader: var BufferedReader; o: var Option[T])
proc sread*[T, E](reader: var BufferedReader; o: var Result[T, E])
proc sread*(reader: var BufferedReader; c: var RGBAColor) {.inline.}

proc readData(reader: var BufferedReader; buffer: pointer; len: int) =
  assert reader.bufIdx + len <= reader.buffer.len
  copyMem(buffer, addr reader.buffer[reader.bufIdx], len)
  reader.bufIdx += len

proc sread*(reader: var BufferedReader; n: var SomeNumber) =
  reader.readData(addr n, sizeof(n))

proc sread*[T: enum](reader: var BufferedReader; x: var T) =
  var i: int
  reader.sread(i)
  x = cast[T](i)

proc sread*[T](reader: var BufferedReader; s: var set[T]) =
  var len: int
  reader.sread(len)
  for i in 0 ..< len:
    var x: T
    reader.sread(x)
    s.incl(x)

proc sread*(reader: var BufferedReader; s: var string) =
  var len: int
  reader.sread(len)
  s = newString(len)
  if len > 0:
    reader.readData(addr s[0], len)

proc sread*(reader: var BufferedReader; b: var bool) =
  var n: uint8
  reader.sread(n)
  if n == 1u8:
    b = true
  else:
    assert n == 0u8
    b = false

proc sread*(reader: var BufferedReader; url: var URL) =
  var s: string
  reader.sread(s)
  if s == "":
    url = nil
  else:
    let x = newURL(s)
    if x.isSome:
      url = x.get
    else:
      url = nil

proc sread*(reader: var BufferedReader; tup: var tuple) =
  for f in tup.fields:
    reader.sread(f)

proc sread*[I; T](reader: var BufferedReader; a: var array[I, T]) =
  for x in a.mitems:
    reader.sread(x)

proc sread*(reader: var BufferedReader; s: var seq) =
  var len: int
  reader.sread(len)
  s.setLen(len)
  for x in s.mitems:
    reader.sread(x)

proc sread*[U; V](reader: var BufferedReader; t: var Table[U, V]) =
  var len: int
  reader.sread(len)
  for i in 0..<len:
    var k: U
    reader.sread(k)
    var v: V
    reader.sread(v)
    t[k] = v

proc sread*(reader: var BufferedReader; obj: var object) =
  for f in obj.fields:
    reader.sread(f)

proc sread*(reader: var BufferedReader; obj: var ref object) =
  var n: bool
  reader.sread(n)
  if n:
    new(obj)
    reader.sread(obj[])

proc sread*(reader: var BufferedReader; part: var FormDataEntry) =
  var isstr: bool
  reader.sread(isstr)
  if isstr:
    part = FormDataEntry(isstr: true)
  else:
    part = FormDataEntry(isstr: false)
  reader.sread(part.name)
  reader.sread(part.filename)
  if part.isstr:
    reader.sread(part.svalue)
  else:
    reader.sread(part.value)

proc sread*(reader: var BufferedReader; blob: var Blob) =
  var isfile: bool
  reader.sread(isfile)
  if isfile:
    var file = new WebFile
    file.isfile = true
    reader.sread(file.path)
    blob = file
  else:
    blob = Blob()
    reader.sread(blob.ctype)
    reader.sread(blob.size)
    let buffer = alloc(blob.size)
    blob.buffer = buffer
    blob.deallocFun = proc() = dealloc(buffer)
    if blob.size > 0:
      reader.readData(blob.buffer, int(blob.size))

proc sread*[T](reader: var BufferedReader; o: var Option[T]) =
  var x: bool
  reader.sread(x)
  if x:
    var m: T
    reader.sread(m)
    o = some(m)
  else:
    o = none(T)

proc sread*[T, E](reader: var BufferedReader; o: var Result[T, E]) =
  var x: bool
  reader.sread(x)
  if x:
    when T isnot void:
      var m: T
      reader.sread(m)
      o.ok(m)
    else:
      o.ok()
  else:
    when E isnot void:
      var e: E
      reader.sread(e)
      o.err(e)
    else:
      o.err()

proc sread*(reader: var BufferedReader; c: var RGBAColor) =
  reader.sread(uint32(c))
