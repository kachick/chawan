when NimMajor >= 2:
  import std/envvars
else:
  import std/os

import curl
import curlerrors
import curlwrap

import ../gophertypes

import loader/connecterror
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
  var path = getEnv("MAPPED_URI_PATH")
  if path.len < 1:
    path &= '/'
  if path.len < 2:
    path &= '1'
  let url = curl_url()
  const flags = cuint(CURLU_PATH_AS_IS)
  url.set(CURLUPART_SCHEME, getEnv("MAPPED_URI_SCHEME"), flags)
  url.set(CURLUPART_HOST, getEnv("MAPPED_URI_HOST"), flags)
  let port = getEnv("MAPPED_URI_PORT")
  if port != "":
    url.set(CURLUPART_PORT, port, flags)
  url.set(CURLUPART_PATH, path, flags)
  let query = getEnv("MAPPED_URI_QUERY")
  if query != "":
    url.set(CURLUPART_QUERY, query.after('='), flags)
  let op = GopherHandle(
    curl: curl,
    t: gopherType(path[1])
  )
  if op.t == SEARCH and query == "":
    const flags = cuint(CURLU_PUNY2IDN)
    let surl = url.get(CURLUPART_URL, flags)
    if surl == nil:
      stdout.write("Cha-Control: ConnectionError " & $int(ERROR_INVALID_URL))
    else:
      op.loadSearch($surl)
  else:
    curl.setopt(CURLOPT_CURLU, url)
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
