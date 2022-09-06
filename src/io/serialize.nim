# Write data to streams.

import options
import streams
import tables

import io/request
import types/url

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

proc swrite*(stream: Stream, headers: HeaderList) =
  stream.swrite(headers.table.len)
  for k, v in headers.table:
    stream.swrite(k)
    stream.swrite(v.len)
    for s in v:
      stream.swrite(s)

proc swrite*(stream: Stream, part: MimePart) =
  stream.swrite(part.isFile)
  stream.swrite(part.name)
  stream.swrite(part.content)
  if part.isFile:
    stream.swrite(part.filename)
    stream.swrite(part.contentType)
    stream.swrite(part.fileSize)
    stream.swrite(part.isStream)

proc swrite*[T](stream: Stream, s: seq[T]) =
  stream.swrite(s.len)
  for m in s:
    stream.swrite(m)

proc swrite*[T](stream: Stream, o: Option[T]) =
  if o.issome:
    stream.swrite(1u8)
    stream.swrite(o.get)
  else:
    stream.swrite(0u8)

proc swrite*(stream: Stream, request: Request) =
  stream.swrite(request.httpmethod)
  stream.swrite(request.url)
  stream.swrite(request.headers)
  stream.swrite(request.body)
  stream.swrite(request.multipart)

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

proc sread*(stream: Stream, url: var Url) =
  var s: string
  stream.sread(s)
  url = parseUrl(s).get

proc sread*(stream: Stream, headers: var HeaderList) =
  new(headers)
  var len: int
  stream.sread(len)
  for i in 0..<len:
    var k: string
    stream.sread(k)
    var n: int
    stream.sread(n)
    for j in 0..<n:
      var v: string
      stream.sread(v)
      headers.add(k, v)

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

proc sread*[T](stream: Stream, s: var seq[T]) =
  var len: int
  stream.sread(len)
  s.setLen(len)
  for i in 0..<len:
    stream.sread(s[i])

proc sread*[T](stream: Stream, o: var Option[T]) =
  let c = uint8(stream.readChar())
  if c == 1u8:
    var m: T
    stream.sread(m)
    o = some(m)
  else:
    assert c == 0u8
    o = none(T)

proc sread*(stream: Stream, req: var RequestObj) =
  stream.sread(req.httpmethod)
  stream.sread(req.url)
  stream.sread(req.headers)
  stream.sread(req.body)
  stream.sread(req.multipart)

proc readRequest*(stream: Stream): Request =
  new(result)
  stream.sread(result[])
