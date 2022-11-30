# Write data to streams.

import options
import streams
import tables

import buffer/cell
import io/request
import js/regex
import types/buffersource
import types/color
import types/url

proc slen*[T](o: T): int =
  when T is string:
    return slen(o.len) + o.len
  elif T is bool:
    return sizeof(char)
  elif T is URL:
    return ($o).slen
  elif T is seq:
    result = slen(o.len)
    for x in o:
      result += slen(x)
  elif T is Option:
    result = slen(o.isSome)
    if o.isSome:
      result += slen(o.get)
  elif T is MimePart:
    result += slen(o.isFile)
    result += slen(o.name)
    result += slen(o.content)
    if o.isFile:
      result += slen(o.filename)
      result += slen(o.contentType)
      result += slen(o.fileSize)
      result += slen(o.isStream)
  elif T is Request:
    result += slen(o.httpmethod)
    result += slen(o.url)
    result += slen(o.headers)
    result += slen(o.body)
    result += slen(o.multipart)
  elif T is CellColor:
    result += slen(o.rgb)
    if o.rgb:
      result += slen(o.rgbcolor)
    else:
      result += slen(o.color)
  elif T is Regex:
    result += slen(o.plen)
    result += o.plen
    result += slen(o.buf)
  elif T is BufferSource:
    result += slen(o.t)
    case o.t
    of CLONE: result += slen(o.clonepid)
    of LOAD_REQUEST: result += slen(o.request)
    of LOAD_PIPE: result += slen(o.fd)
    result += slen(o.location)
    result += slen(o.contenttype)
  elif T is tuple:
    for f in o.fields:
      result += slen(f)
  elif T is object:
    for f in o.fields:
      result += slen(f)
  elif T is ref object:
    result += slen(o[])
  else:
    result += sizeof(o)

template swrite*[T](stream: Stream, o: T) =
  stream.write(o)

proc swrite*(stream: Stream, s: string) =
  stream.swrite(s.len)
  stream.write(s)

proc swrite*(stream: Stream, b: bool) =
  if b:
    stream.swrite(1u8)
  else:
    stream.swrite(0u8)

proc swrite*(stream: Stream, url: Url) =
  stream.swrite(url.serialize())

proc swrite*(stream: Stream, tup: tuple) =
  for f in tup.fields:
    stream.swrite(f)

proc swrite*[T](stream: Stream, s: seq[T]) =
  stream.swrite(s.len)
  for m in s:
    stream.swrite(m)

proc swrite*[U, V](stream: Stream, t: Table[U, V]) =
  stream.swrite(t.len)
  for k, v in t:
    stream.swrite(k)
    stream.swrite(v)

proc swrite*(stream: Stream, obj: object) =
  for f in obj.fields:
    stream.swrite(f)

proc swrite*(stream: Stream, obj: ref object) =
  stream.swrite(obj[])

proc swrite*(stream: Stream, part: MimePart) =
  stream.swrite(part.isFile)
  stream.swrite(part.name)
  stream.swrite(part.content)
  if part.isFile:
    stream.swrite(part.filename)
    stream.swrite(part.contentType)
    stream.swrite(part.fileSize)
    stream.swrite(part.isStream)

proc swrite*[T](stream: Stream, o: Option[T]) =
  stream.swrite(o.issome)
  if o.issome:
    stream.swrite(o.get)

proc swrite*(stream: Stream, request: Request) =
  stream.swrite(request[])

proc swrite*(stream: Stream, color: CellColor) =
  stream.swrite(color.rgb)
  if color.rgb:
    stream.swrite(color.rgbcolor)
  else:
    stream.swrite(color.color)

proc swrite*(stream: Stream, regex: Regex) =
  stream.swrite(regex.plen)
  stream.writeData(regex.bytecode, regex.plen)
  stream.swrite(regex.buf)

proc swrite*(stream: Stream, source: BufferSource) =
  stream.swrite(source.t)
  case source.t
  of CLONE: stream.swrite(source.clonepid)
  of LOAD_REQUEST: stream.swrite(source.request)
  of LOAD_PIPE: stream.swrite(source.fd)
  stream.swrite(source.location)
  stream.swrite(source.contenttype)

template sread*[T](stream: Stream, o: T) =
  stream.read(o)

proc sread*(stream: Stream, s: var string) =
  var len: int
  stream.sread(len)
  stream.readStr(len, s)

proc sread*(stream: Stream, b: var bool) =
  var n: uint8
  stream.sread(n)
  if n == 1u8:
    b = true
  else:
    assert n == 0u8
    b = false

proc sread*[T](stream: Stream, s: var seq[T]) =
  var len: int
  stream.sread(len)
  s.setLen(len)
  for i in 0..<len:
    stream.sread(s[i])

proc sread*[T](stream: Stream, o: var Option[T]) =
  var x: bool
  stream.sread(x)
  if x:
    var m: T
    stream.sread(m)
    o = some(m)
  else:
    o = none(T)

proc sread*[U, V](stream: Stream, t: var Table[U, V]) =
  var len: int
  stream.sread(len)
  for i in 0..<len:
    var k: U
    stream.sread(k)
    var v: V
    stream.sread(v)
    t[k] = v

proc sread*(stream: Stream, obj: var object) =
  for f in obj.fields:
    stream.sread(f)

proc sread*(stream: Stream, tup: var tuple) =
  for f in tup.fields:
    stream.sread(f)

proc read*(stream: Stream, obj: var ref object) =
  new(obj)
  stream.sread(obj[])

proc sread*(stream: Stream, url: var Url) =
  var s: string
  stream.sread(s)
  url = newURL(s)

proc sread*(stream: Stream, part: var MimePart) =
  var isFile: bool
  stream.sread(isFile)
  if isFile:
    part = MimePart(isFile: true)
  else:
    part = MimePart(isFile: false)
  stream.sread(part.name)
  stream.sread(part.content)
  if part.isFile:
    stream.sread(part.filename)
    stream.sread(part.contentType)
    stream.sread(part.fileSize)
    stream.sread(part.isStream)

proc sread*(stream: Stream, color: var CellColor) =
  var rgb: bool
  stream.sread(rgb)
  if rgb:
    color = CellColor(rgb: true)
    stream.sread(color.rgbcolor)
  else:
    color = CellColor(rgb: false)
    stream.sread(color.color)

proc sread*(stream: Stream, regex: var Regex) =
  assert regex.bytecode == nil
  stream.sread(regex.plen)
  regex.bytecode = cast[ptr uint8](alloc(regex.plen))
  regex.clone = true
  let l = stream.readData(regex.bytecode, regex.plen)
  stream.sread(regex.buf)
  if l != regex.plen:
    `=destroy`(regex)

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
