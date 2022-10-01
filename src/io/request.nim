import options
import streams
import tables

import types/url
import js/javascript
import utils/twtstr

type HttpMethod* = enum
  HTTP_CONNECT = "CONNECT"
  HTTP_DELETE = "DELETE"
  HTTP_GET = "GET"
  HTTP_HEAD = "HEAD"
  HTTP_OPTIONS = "OPTIONS"
  HTTP_PATCH = "PATCH"
  HTTP_POST = "POST"
  HTTP_PUT = "PUT"
  HTTP_TRACE = "TRACE"

type
  Request* = ref RequestObj
  RequestObj* = object
    httpmethod*: HttpMethod
    url*: Url
    headers*: HeaderList
    body*: Option[string]
    multipart*: Option[MimeData]

  Response* = ref object
    body*: Stream
    res* {.jsget.}: int
    contenttype* {.jsget.}: string
    status* {.jsget.}: int
    headers* {.jsget.}: HeaderList
    redirect* {.jsget.}: Option[Url]

  ReadableStream* = ref object of Stream
    isource*: Stream
    buf: string
    isend: bool

  HeaderList* = ref object
    table* {.jsget.}: Table[string, seq[string]]

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

proc rsReadData(s: Stream, buffer: pointer, bufLen: int): int =
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

proc rsAtEnd(s: Stream): bool =
  ReadableStream(s).isend

proc rsClose(s: Stream) = {.cast(tags: [WriteIOEffect]).}: #TODO TODO TODO ew.
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

proc newReadableStream*(isource: Stream): ReadableStream =
  new(result)
  result.isource = isource
  result.readDataImpl = rsReadData
  result.atEndImpl = rsAtEnd
  result.closeImpl = rsClose
  var len: int
  result.isource.read(len)
  if len == 0:
    result.isend = true
  else:
    result.isource.readStr(len, result.buf)

func newHeaderList*(): HeaderList =
  new(result)

func newHeaderList*(table: Table[string, string]): HeaderList =
  new(result)
  for k, v in table:
    let k = k.toHeaderCase()
    if k in result.table:
      result.table[k].add(v)
    else:
      result.table[k] = @[v]

func newRequest*(url: Url,
                 httpmethod = HTTP_GET,
                 headers: seq[(string, string)] = @[],
                 body = none(string),
                 multipart = none(MimeData)): Request {.jsctor.} =
  new(result)
  result.httpmethod = httpmethod
  result.url = url
  result.headers = newHeaderList()
  for it in headers:
    if it[1] != "": #TODO not sure if this is a good idea, options would probably work better
      result.headers.table[it[0]] = @[it[1]]
  result.body = body
  result.multipart = multipart

func newRequest*(url: Url,
                 httpmethod: HttpMethod,
                 headers: openarray[(string, string)],
                 body = none(string),
                 multipart = none(MimeData)): Request =
  var s: seq[(string, string)]
  for it in headers:
    s.add(it)
  return newRequest(url, httpmethod, s, body, multipart)

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

proc readAll*(response: Response): string {.jsfunc.} =
  result = response.body.readAll()
  response.body.close()

proc close*(response: Response) {.jsfunc.} =
  response.body.close()

proc addRequestModule*(ctx: JSContext) =
  ctx.registerType(Request)
  ctx.registerType(Response)
  ctx.registerType(HeaderList)
