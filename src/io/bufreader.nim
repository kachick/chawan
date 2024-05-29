import std/options
import std/sets
import std/tables

import img/bitmap
import io/dynstream
import io/socketstream
import loader/request
import types/blob
import types/color
import types/formdata
import types/opt
import types/url

type BufferedReader* = object
  buffer: seq[uint8]
  bufIdx: int
  recvAux: seq[FileHandle] #TODO assert on unused ones

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
proc sread*(reader: var BufferedReader; c: var ARGBColor) {.inline.}
proc sread*(reader: var BufferedReader; o: var RequestBody)
proc sread*(reader: var BufferedReader; bmp: var Bitmap)

proc initReader*(stream: DynStream; len, auxLen: int): BufferedReader =
  assert len != 0
  var reader = BufferedReader(
    buffer: newSeqUninitialized[uint8](len),
    bufIdx: 0
  )
  stream.recvDataLoop(reader.buffer)
  for i in 0 ..< auxLen:
    reader.recvAux.add(SocketStream(stream).recvFileHandle())
  return reader

proc initPacketReader*(stream: DynStream): BufferedReader =
  var len: array[2, int]
  stream.recvDataLoop(addr len[0], sizeof(len))
  return stream.initReader(len[0], len[1])

template withPacketReader*(stream: DynStream; r, body: untyped) =
  block:
    var r = stream.initPacketReader()
    body

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
  var isWebFile: bool
  reader.sread(isWebFile)
  blob = if isWebFile: WebFile() else: Blob()
  if isWebFile:
    reader.sread(WebFile(blob).name)
  var hasFd: bool
  reader.sread(hasFd)
  if hasFd:
    blob.fd = some(reader.recvAux.pop())
  reader.sread(blob.ctype)
  reader.sread(blob.size)
  if blob.size > 0:
    let buffer = alloc(blob.size)
    reader.readData(blob.buffer, int(blob.size))
    blob.buffer = buffer
    blob.deallocFun = deallocBlob

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

proc sread*(reader: var BufferedReader; c: var ARGBColor) =
  reader.sread(uint32(c))

proc sread*(reader: var BufferedReader; o: var RequestBody) =
  var t: RequestBodyType
  reader.sread(t)
  o = RequestBody(t: t)
  case t
  of rbtNone: discard
  of rbtString: reader.sread(o.s)
  of rbtMultipart: reader.sread(o.multipart)
  of rbtOutput: reader.sread(o.outputId)

proc sread*(reader: var BufferedReader; bmp: var Bitmap) =
  var isImageBitmap: bool
  var width: uint64
  var height: uint64
  reader.sread(isImageBitmap)
  reader.sread(width)
  reader.sread(height)
  if isImageBitmap:
    bmp = ImageBitmap(
      width: width,
      height: height
    )
    reader.sread(bmp.px)
  else:
    var outputId: int
    var imageId: int
    reader.sread(outputId)
    reader.sread(imageId)
    bmp = NetworkBitmap(
      width: width,
      height: height,
      outputId: outputId,
      imageId: imageId
    )
