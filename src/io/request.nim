import options
import streams
import tables

import utils/twtstr
import types/url

type HttpMethod* = enum
  HTTP_CONNECT, HTTP_DELETE, HTTP_GET, HTTP_HEAD, HTTP_OPTIONS, HTTP_PATCH,
  HTTP_POST, HTTP_PUT, HTTP_TRACE

type
  Request* = ref RequestObj
  RequestObj* = object
    httpmethod*: HttpMethod
    url*: Url
    headers*: HeaderList
    body*: Option[string]
    multipart*: Option[MimeData]

  LoadResult* = object
    body*: ReadableStream
    res*: int
    contenttype*: string
    status*: int
    headers*: HeaderList
    redirect*: Option[Url]

  ReadableStream* = ref object of Stream
    isource*: Stream
    buf: string
    isend: bool

  HeaderList* = object
    table*: Table[string, seq[string]]

# Originally from the stdlib
  MimePart* = object
    name*, content*: string
    case isFile*: bool
    of true:
      filename*, contentType*: string
      fileSize*: int64
      isStream*: bool
    else: discard

  MimeData* = object
    content*: seq[MimePart]

iterator pairs*(headers: HeaderList): (string, string) =
  for k, vs in headers.table:
    for v in vs:
      yield (k, v)

proc newReadableStream*(isource: Stream): ReadableStream =
  new(result)
  result.isource = isource
  result.readDataImpl = (proc(s: Stream, buffer: pointer, bufLen: int): int =
    var s = ReadableStream(s)
    if s.atEnd:
      return 0
    while s.buf.len < bufLen:
      var len: int
      s.isource.read(len)
      if len == 0:
        result = s.buf.len
        copyMem(buffer, addr(s.buf[0]), result)
        s.buf = s.buf.substr(result)
        s.isend = true
        return
      var nbuf: string
      s.isource.readStr(len, nbuf)
      s.buf &= nbuf
    assert s.buf.len >= bufLen
    result = bufLen
    copyMem(buffer, addr(s.buf[0]), result)
    s.buf = s.buf.substr(result)
    if s.buf.len == 0:
      var len: int
      s.isource.read(len)
      if len == 0:
        s.isend = true
      else:
        s.isource.readStr(len, s.buf)
  )
  result.atEndImpl = (proc(s: Stream): bool =
    return ReadableStream(s).isend
  )
  result.closeImpl = (proc(s: Stream) = {.cast(tags: [WriteIOEffect]).}: #TODO TODO TODO ew.
    var s = ReadableStream(s)
    if s.isend: return
    s.buf = ""
    while true:
      var len: int
      s.isource.read(len)
      if len == 0:
        s.isend = true
        break
      s.isource.setPosition(s.isource.getPosition() + len)
  )
  var len: int
  result.isource.read(len)
  if len == 0:
    result.isend = true
  else:
    result.isource.readStr(len, result.buf)

func newHeaderList*(): HeaderList =
  discard

func newHeaderList*(table: Table[string, string]): HeaderList =
  for k, v in table:
    let k = k.toHeaderCase()
    if k in result.table:
      result.table[k].add(v)
    else:
      result.table[k] = @[v]

func newRequest*(url: Url,
                 httpmethod = HTTP_GET,
                 headers: openarray[(string, string)] = [],
                 body = none(string),
                 multipart = none(MimeData)): Request =
  new(result)
  result.httpmethod = httpmethod
  result.url = url
  for it in headers:
    if it[1] != "": #TODO not sure if this is a good idea, options would probably work better
      result.headers.table[it[0]] = @[it[1]]
  result.body = body
  result.multipart = multipart

proc `[]=`*(multipart: var MimeData, k, v: string) =
  multipart.content.add(MimePart(name: k, content: v))

proc add*(headers: var HeaderList, k, v: string) =
  let k = k.toHeaderCase()
  if k notin headers.table:
    headers.table[k] = @[v]
  else:
    headers.table[k].add(v)

proc `[]=`*(headers: var HeaderList, k, v: string) =
  headers.table[k.toHeaderCase()] = @[v]

func getOrDefault*(headers: HeaderList, k: string, default = ""): string =
  let k = k.toHeaderCase()
  if k in headers.table:
    headers.table[k][0]
  else:
    default
