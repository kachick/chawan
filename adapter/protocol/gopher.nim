import std/envvars
import std/options

import curlwrap
import curlerrors

import ../gophertypes

import bindings/curl
import loader/connecterror
import types/opt
import types/url
import utils/twtstr

type GopherHandle = ref object
  curl: CURL
  t: GopherType
  statusline: bool

proc onStatusLine(op: GopherHandle) =
  var status: clong
  op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
  stdout.write("Status: " & $status & "\n")
  let s = case op.t
  of DIRECTORY, SEARCH: "Content-Type: text/gopher\n"
  of HTML: "Content-Type: text/html\n"
  of GIF: "Content-Type: image/gif\n"
  of PNG: "Content-Type: image/png\n"
  of TEXT_FILE, ERROR: "Content-Type: text/plain\n"
  else: ""
  stdout.write(s & "\n")

proc loadSearch(op: GopherHandle, surl: string) =
  stdout.write("""
Content-Type: text/html

<!DOCTYPE HTML>
<HTML>
<HEAD>
<BASE HREF="""" & surl & """">
</HEAD>
<BODY>
<H1>Search """ & htmlEscape(surl) & """</H1>
<FORM>
<INPUT TYPE=SEARCH NAME="NAME">
</FORM>
</BODY>
</HTML>
""")

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size, nmemb: csize_t, userdata: pointer):
    csize_t {.cdecl.} =
  let op = cast[GopherHandle](userdata)
  if not op.statusline:
    op.statusline = true
    op.onStatusLine()
  return csize_t(stdout.writeBuffer(p, int(nmemb)))

proc main() =
  let curl = curl_easy_init()
  doAssert curl != nil
  if getEnv("REQUEST_METHOD") != "GET":
    stdout.write("Cha-Control: ConnectionError " & $int(ERROR_INVALID_METHOD))
    return
  var url = newURL(getEnv("QUERY_STRING")).get
  var path = url.pathname
  if path.len < 1:
    path &= '/'
  if path.len < 2:
    path &= '1'
    url = newURL(url)
    url.setPathname(path)
  let op = GopherHandle(
    curl: curl,
    t: gopherType(path[1])
  )
  if op.t == SEARCH:
    if url.query.isNone:
      op.loadSearch(url.serialize())
      return
    else:
      url.query = some(url.query.get.after('='))
  let surl = url.serialize()
  #TODO avoid re-parsing
  curl.setopt(CURLOPT_URL, surl)
  curl.setopt(CURLOPT_WRITEDATA, op)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  let proxy = getEnv("ALL_PROXY")
  if proxy != "":
    curl.setopt(CURLOPT_PROXY, proxy)
  let res = curl_easy_perform(curl)
  if res != CURLE_OK and not op.statusline:
    stdout.write(getCurlConnectionError(res))
  curl_easy_cleanup(curl)

main()
