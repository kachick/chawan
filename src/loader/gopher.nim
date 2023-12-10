import options

import bindings/curl
import loader/connecterror
import loader/curlhandle
import loader/curlwrap
import loader/headers
import loader/loaderhandle
import loader/request
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
  of DIRECTORY, SEARCH:
    newHeaders({"Content-Type": "text/gopher"})
  of HTML:
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
  return true

proc loadSearch(op: GopherHandle, surl: string) =
  discard op.handle.sendResult(int(CURLE_OK))
  discard op.handle.sendStatus(200) # ok
  discard op.handle.sendHeaders(newHeaders({"Content-Type": "text/html"}))
  let heads = """
<!DOCTYPE HTML>
<HTML>
<HEAD>
<BASE HREF="""" & $op.request.url & """">
</HEAD>
<BODY>
<H1>Search """ & htmlEscape(surl) & """</H1>
<FORM>
<INPUT TYPE=SEARCH NAME="NAME">
</FORM>
</BODY>
</HTML>
"""
  discard op.handle.sendData(heads)

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  let op = cast[GopherHandle](userdata)
  if not op.statusline:
    op.statusline = true
    if not op.onStatusLine():
      return 0
  if not op.handle.sendData(p, int(nmemb)):
    return 0
  return nmemb

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
      op.loadSearch(url.serialize())
      handle.close()
      return nil
    else:
      url.query = some(url.query.get.after('='))
  let surl = url.serialize()
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
