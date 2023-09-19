import options
import strutils

import bindings/curl
import loader/connecterror
import loader/curlhandle
import loader/curlwrap
import loader/headers
import loader/loaderhandle
import loader/request
import types/opt
import types/url
import utils/twtstr

type GopherType = enum
  UNKNOWN = "unsupported"
  TEXT_FILE = "text file"
  ERROR = "error"
  DIRECTORY = "directory"
  DOS_BINARY = "DOS binary"
  SEARCH = "search"
  MESSAGE = "message"
  SOUND = "sound"
  GIF = "gif"
  HTML = "HTML"
  INFO = ""
  IMAGE = "image"
  BINARY = "binary"
  PNG = "png"

type GopherHandle = ref object of CurlHandle
  t: GopherType
  buffer: string
  ispre: bool
  surl: string

func gopherType(c: char): GopherType =
  return case c
  of '0': TEXT_FILE
  of '1': DIRECTORY
  of '3': ERROR
  of '5': DOS_BINARY
  of '7': SEARCH
  of 'm': MESSAGE
  of 's': SOUND
  of 'g': GIF
  of 'h': HTML
  of 'i': INFO
  of 'I': IMAGE
  of '9': BINARY
  of 'p': PNG
  else: UNKNOWN

func newGopherHandle(curl: CURL, request: Request, handle: LoaderHandle,
    t: GopherType): GopherHandle =
  return GopherHandle(
    curl: curl,
    handle: handle,
    request: request,
    t: t
  )

proc onStatusLine(op: GopherHandle): bool =
  if not op.handle.sendResult(int(CURLE_OK)):
    return false
  var status: clong
  op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
  if not op.handle.sendStatus(cast[int](status)):
    return false
  let headers = case op.t
  of DIRECTORY, SEARCH, HTML:
    newHeaders({"Content-Type": "text/html"})
  of GIF:
    newHeaders({"Content-Type": "image/gif"})
  of PNG:
    newHeaders({"Content-Type": "image/png"})
  of TEXT_FILE, ERROR:
    newHeaders({"Content-Type": "text/plain"})
  else:
    newHeaders()
  if not op.handle.sendHeaders(headers):
    return false
  if op.t in {DIRECTORY, SEARCH}:
    var heads = """
<!DOCTYPE HTML>
<HTML>
<HEAD>
<BASE HREF="""" & $op.request.url & """">
</HEAD>
<BODY>
  """
    if op.t == DIRECTORY:
      heads &= "<H1>Index of " & htmlEscape(op.surl) & "</H1>"
    else: # search
      heads &= "<H1>Search " & htmlEscape(op.surl) & "</H1>"
    if not op.handle.sendData(heads):
      return false
  return true

proc loadSearch(op: GopherHandle) =
  discard op.handle.sendResult(int(CURLE_OK))
  discard op.handle.sendStatus(200) # ok
  discard op.handle.sendHeaders(newHeaders({"Content-Type": "text/html"}))
  var heads = """
<!DOCTYPE HTML>
<HTML>
<HEAD>
<BASE HREF="""" & $op.request.url & """">
</HEAD>
<BODY>
<H1>Search """ & htmlEscape(op.surl) & """</H1>
<FORM>
<INPUT TYPE=SEARCH NAME="NAME">
</FORM>
</BODY>
</HTML>
"""
  discard op.handle.sendData(heads)

proc flushLine(op: GopherHandle, s: string, fromi, toi: int): bool =
  if toi == fromi + 1 and s[fromi] == '.':
    return true #TODO this is the file end. maybe return false?
  if s.len == 0:
    return true # invalid
  var i = fromi
  let tc = s[i]
  let t = gopherType(tc)
  inc i
  let ni = i
  while i < toi and s[i] != '\t': inc i
  let name = s.substr(ni, i - 1)
  inc i
  let fi = i
  while i < toi and s[i] != '\t': inc i
  let file = s.substr(fi, i - 1)
  inc i
  let hi = i
  while i < toi and s[i] != '\t': inc i
  let host = s.substr(hi, i - 1)
  inc i
  let pi = i
  while i < toi and s[i] notin {'\t', '\r', '\n'}: inc i
  let port = s.substr(pi, i - 1)
  var line: string
  if t == INFO:
    if not op.ispre:
      op.ispre = true
      line = "<PRE>"
    line &= htmlEscape(name) & "\n"
  else:
    if op.ispre:
      line = "</PRE>"
      op.ispre = false
    let ts = $t
    var names = ""
    if ts != "":
      names &= '[' & ts & ']'
    names &= htmlEscape(name)
    var ourls: string
    if not file.startsWith("URL:"):
      let file = if file.len > 0 and file[0] == '/':
        file
      else:
        '/' & file
      let pefile = percentEncode(file, PathPercentEncodeSet)
      let iurls = "gopher://" & host & ":" & port & "/" & tc & pefile
      let url = newURL(iurls)
      ourls = if url.isSome: $url.get else: ""
    else:
      ourls = file.substr("URL:".len)
    line &= "<A HREF=\"" & htmlEscape(ourls) & "\">" & names & "</A><BR>\n"
  return op.handle.sendData(line)

proc onSendChunk(op: GopherHandle, previ: int): bool =
  var i = previ
  var lasti = 0
  while i < op.buffer.len:
    if op.buffer[i] in {'\r', '\n'}:
      if not op.flushLine(op.buffer, lasti, i):
        return false
      while i < op.buffer.high and op.buffer[i] in {'\r', '\n'}:
        inc i
      lasti = i
    inc i
  if lasti > 0:
    op.buffer.delete(0 .. lasti)
  return true

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  let op = cast[GopherHandle](userdata)
  if not op.statusline:
    op.statusline = true
    if not op.onStatusLine():
      return 0
  if nmemb > 0:
    if op.t in {DIRECTORY, SEARCH}:
      let i = op.buffer.len
      op.buffer.setLen(op.buffer.len + int(nmemb))
      prepareMutation(op.buffer)
      copyMem(addr op.buffer[i], p, nmemb)
      if not op.onSendChunk(i):
        return 0
    else:
      if not op.handle.sendData(p, int(nmemb)):
        return 0
  return nmemb

proc finish(op: CurlHandle) =
  let op = cast[GopherHandle](op)
  if op.ispre:
    discard op.handle.sendData("</PRE>\n")
  discard op.handle.sendData("</BODY>\n</HTML>\n")

proc loadGopher*(handle: LoaderHandle, curlm: CURLM,
    request: Request): CurlHandle =
  let curl = curl_easy_init()
  doAssert curl != nil
  if request.httpmethod != HTTP_GET:
    discard handle.sendResult(int(ERROR_INVALID_METHOD))
    return nil
  var url = request.url
  var path = url.pathname
  if path.len < 1:
    path &= '/'
  if path.len < 2:
    path &= '1'
    url = newURL(url)
    url.setPathname(path)
  let t = gopherType(path[1])
  let op = curl.newGopherHandle(request, handle, t)
  if t == SEARCH:
    if url.query.isNone:
      op.surl = url.serialize()
      op.loadSearch()
      return nil
    else:
      url.query = some(url.query.get.after('='))
  let surl = url.serialize()
  if t in {DIRECTORY, SEARCH}:
    op.surl = surl
    op.finish = finish
  curl.setopt(CURLOPT_URL, surl)
  curl.setopt(CURLOPT_WRITEDATA, op)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  if request.proxy != nil:
    let purl = request.proxy.serialize()
    curl.setopt(CURLOPT_PROXY, purl)
  let res = curl_multi_add_handle(curlm, curl)
  if res != CURLM_OK:
    discard handle.sendResult(int(res))
    return nil
  return op
