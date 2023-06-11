# Write data to streams.

import options
import sets
import streams
import tables

import io/request
import js/regex
import types/blob
import types/buffersource
import types/formdata
import types/url

proc swrite*(stream: Stream, n: SomeNumber)
proc sread*(stream: Stream, n: var SomeNumber)
func slen*(n: SomeNumber): int

proc swrite*[T](stream: Stream, s: set[T])
proc sread*[T](stream: Stream, s: var set[T])
func slen*[T](s: set[T]): int

proc swrite*[T: enum](stream: Stream, x: T)
proc sread*[T: enum](stream: Stream, x: var T)
func slen*[T: enum](x: T): int

proc swrite*(stream: Stream, s: string)
proc sread*(stream: Stream, s: var string)
func slen*(s: string): int

proc swrite*(stream: Stream, b: bool)
proc sread*(stream: Stream, b: var bool)
func slen*(b: bool): int

proc swrite*(stream: Stream, url: Url)
proc sread*(stream: Stream, url: var Url)
func slen*(url: Url): int

proc swrite*(stream: Stream, tup: tuple)
proc sread*(stream: Stream, tup: var tuple)
func slen*(tup: tuple): int

proc swrite*[T](stream: Stream, s: seq[T])
proc sread*[T](stream: Stream, s: var seq[T])
func slen*(s: seq): int

proc swrite*[U, V](stream: Stream, t: Table[U, V])
proc sread*[U, V](stream: Stream, t: var Table[U, V])
func slen*[U, V](t: Table[U, V]): int

proc swrite*(stream: Stream, obj: object)
proc sread*(stream: Stream, obj: var object)
func slen*(obj: object): int

proc swrite*(stream: Stream, obj: ref object)
proc sread*(stream: Stream, obj: var ref object)
func slen*(obj: ref object): int

proc swrite*(stream: Stream, part: FormDataEntry)
proc sread*(stream: Stream, part: var FormDataEntry)
func slen*(part: FormDataEntry): int

proc swrite*(stream: Stream, blob: Blob)
proc sread*(stream: Stream, blob: var Blob)
func slen*(blob: Blob): int

proc swrite*[T](stream: Stream, o: Option[T])
proc sread*[T](stream: Stream, o: var Option[T])
func slen*[T](o: Option[T]): int

proc swrite*(stream: Stream, regex: Regex)
proc sread*(stream: Stream, regex: var Regex)
func slen*(regex: Regex): int

proc swrite*(stream: Stream, source: BufferSource)
proc sread*(stream: Stream, source: var BufferSource)
func slen*(source: BufferSource): int

proc swrite*(stream: Stream, n: SomeNumber) =
  stream.write(n)

proc sread*(stream: Stream, n: var SomeNumber) =
  if stream.readData(addr n, sizeof(n)) < sizeof(n):
    raise newException(EOFError, "eof")

func slen*(n: SomeNumber): int =
  return sizeof(n)

proc swrite*[T: enum](stream: Stream, x: T) =
  stream.swrite(cast[int](x))

proc sread*[T: enum](stream: Stream, x: var T) =
  var i: int
  stream.sread(i)
  x = cast[T](i)

func slen*[T: enum](x: T): int =
  return sizeof(int)

proc swrite*[T](stream: Stream, s: set[T]) =
  stream.swrite(s.card)
  for e in s:
    stream.swrite(e)

proc sread*[T](stream: Stream, s: var set[T]) =
  var len: int
  stream.sread(len)
  for i in 0 ..< len:
    var x: T
    stream.sread(x)
    s.incl(x)

func slen*[T](s: set[T]): int =
  result = slen(s.card)
  for x in s:
    result += slen(x)

proc swrite*(stream: Stream, s: string) =
  stream.swrite(s.len)
  stream.write(s)

proc sread*(stream: Stream, s: var string) =
  var len: int
  stream.sread(len)
  if len > 0:
    s = newString(len)
    if stream.readData(addr s[0], len) < len:
      raise newException(EOFError, "eof")
  else:
    s = ""

func slen*(s: string): int =
  slen(s.len) + s.len

proc swrite*(stream: Stream, b: bool) =
  if b:
    stream.swrite(1u8)
  else:
    stream.swrite(0u8)

proc sread*(stream: Stream, b: var bool) =
  var n: uint8
  stream.sread(n)
  if n == 1u8:
    b = true
  else:
    assert n == 0u8
    b = false

func slen*(b: bool): int =
  return sizeof(uint8)

proc swrite*(stream: Stream, url: URL) =
  if url != nil:
    stream.swrite(url.serialize())
  else:
    stream.swrite("")

proc sread*(stream: Stream, url: var URL) =
  var s: string
  stream.sread(s)
  if s == "":
    url = nil
  else:
    url = newURL(s)

func slen*(url: URL): int =
  if url == nil:
    return slen("")
  return slen(url.serialize())

proc swrite*(stream: Stream, tup: tuple) =
  for f in tup.fields:
    stream.swrite(f)

proc sread*(stream: Stream, tup: var tuple) =
  for f in tup.fields:
    stream.sread(f)

func slen*(tup: tuple): int =
  for f in tup.fields:
    result += slen(f)

proc swrite*[T](stream: Stream, s: seq[T]) =
  stream.swrite(s.len)
  var i = 0
  for m in s:
    stream.swrite(m)
    inc i

proc sread*[T](stream: Stream, s: var seq[T]) =
  var len: int
  stream.sread(len)
  s.setLen(len)
  for i in 0..<len:
    stream.sread(s[i])

func slen*(s: seq): int =
  result = slen(s.len)
  for x in s:
    result += slen(x)

proc swrite*[U, V](stream: Stream, t: Table[U, V]) =
  stream.swrite(t.len)
  for k, v in t:
    stream.swrite(k)
    stream.swrite(v)

proc sread*[U, V](stream: Stream, t: var Table[U, V]) =
  var len: int
  stream.sread(len)
  for i in 0..<len:
    var k: U
    stream.sread(k)
    var v: V
    stream.sread(v)
    t[k] = v

func slen*[U, V](t: Table[U, V]): int =
  result = slen(t.len)
  for k, v in t:
    result += slen(k)
    result += slen(v)

proc swrite*(stream: Stream, obj: object) =
  for f in obj.fields:
    stream.swrite(f)

proc sread*(stream: Stream, obj: var object) =
  for f in obj.fields:
    stream.sread(f)

func slen*(obj: object): int =
  for f in obj.fields:
    result += slen(f)

proc swrite*(stream: Stream, obj: ref object) =
  stream.swrite(obj != nil)
  if obj != nil:
    stream.swrite(obj[])

proc sread*(stream: Stream, obj: var ref object) =
  var n: bool
  stream.sread(n)
  if n:
    new(obj)
    stream.sread(obj[])

func slen*(obj: ref object): int =
  result = slen(obj != nil)
  if obj != nil:
    result += slen(obj[])

proc swrite*(stream: Stream, part: FormDataEntry) =
  stream.swrite(part.isstr)
  stream.swrite(part.name)
  stream.swrite(part.filename)
  if part.isstr:
    stream.swrite(part.svalue)
  else:
    stream.swrite(part.value)

proc sread*(stream: Stream, part: var FormDataEntry) =
  var isstr: bool
  stream.sread(isstr)
  if isstr:
    part = FormDataEntry(isstr: true)
  else:
    part = FormDataEntry(isstr: false)
  stream.sread(part.name)
  stream.sread(part.filename)
  if part.isstr:
    stream.sread(part.svalue)
  else:
    stream.sread(part.value)

func slen*(part: FormDataEntry): int =
  result += slen(part.isstr)
  result += slen(part.name)
  result += slen(part.filename)
  if part.isstr:
    result += slen(part.svalue)
  else:
    result += slen(part.value)

#TODO clean up this mess
proc swrite*(stream: Stream, blob: Blob) =
  stream.swrite(blob.isfile)
  if blob.isfile:
    stream.swrite(WebFile(blob).path)
  else:
    stream.swrite(blob.ctype)
    stream.swrite(blob.size)
    stream.writeData(blob.buffer, int(blob.size))

proc sread*(stream: Stream, blob: var Blob) =
  var isfile: bool
  stream.sread(isfile)
  if isfile:
    var file = new WebFile
    file.isfile = true
    stream.sread(file.path)
    blob = file
  else:
    new(blob)
    stream.sread(blob.ctype)
    stream.sread(blob.size)
    blob.buffer = alloc(blob.size)
    blob.deallocFun = dealloc
    if blob.size > 0:
      assert stream.readData(blob.buffer, int(blob.size)) == int(blob.size)

func slen*(blob: Blob): int =
  result += slen(blob.isfile)
  if blob.isfile:
    result = slen(WebFile(blob).path)
  else:
    result += slen(blob.ctype)
    result += slen(blob.size)
    result += int(blob.size) #TODO ??

proc swrite*[T](stream: Stream, o: Option[T]) =
  stream.swrite(o.issome)
  if o.isSome:
    stream.swrite(o.get)

proc sread*[T](stream: Stream, o: var Option[T]) =
  var x: bool
  stream.sread(x)
  if x:
    var m: T
    stream.sread(m)
    o = some(m)
  else:
    o = none(T)

func slen*[T](o: Option[T]): int =
  result = slen(o.isSome)
  if o.isSome:
    result += slen(o.get)

proc swrite*(stream: Stream, regex: Regex) =
  stream.swrite(regex.plen)
  stream.writeData(regex.bytecode, regex.plen)
  stream.swrite(regex.buf)

proc sread*(stream: Stream, regex: var Regex) =
  assert regex.bytecode == nil
  stream.sread(regex.plen)
  regex.bytecode = cast[ptr uint8](alloc(regex.plen))
  regex.clone = true
  let l = stream.readData(regex.bytecode, regex.plen)
  stream.sread(regex.buf)
  if l != regex.plen:
    `=destroy`(regex)

func slen*(regex: Regex): int =
  result += slen(regex.plen)
  result += regex.plen
  result += slen(regex.buf)

proc swrite*(stream: Stream, source: BufferSource) =
  stream.swrite(source.t)
  case source.t
  of CLONE: stream.swrite(source.clonepid)
  of LOAD_REQUEST: stream.swrite(source.request)
  of LOAD_PIPE: stream.swrite(source.fd)
  stream.swrite(source.location)
  stream.swrite(source.contenttype)
  stream.swrite(source.charset)

proc sread*(stream: Stream, source: var BufferSource) =
  var t: BufferSourceType
  stream.sread(t)
  case t
  of CLONE:
    source = BufferSource(t: CLONE)
    stream.sread(source.clonepid)
  of LOAD_REQUEST:
    source = BufferSource(t: LOAD_REQUEST)
    stream.sread(source.request)
  of LOAD_PIPE:
    source = BufferSource(t: LOAD_PIPE)
    stream.sread(source.fd)
  stream.sread(source.location)
  stream.sread(source.contenttype)
  stream.sread(source.charset)

func slen*(source: BufferSource): int =
  result += slen(source.t)
  case source.t
  of CLONE: result += slen(source.clonepid)
  of LOAD_REQUEST: result += slen(source.request)
  of LOAD_PIPE: result += slen(source.fd)
  result += slen(source.location)
  result += slen(source.contenttype)
