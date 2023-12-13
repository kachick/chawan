import std/envvars
import std/options
import std/strutils

import curlerrors
import curlwrap
import dirlist

import bindings/curl
import loader/connecterror
import types/opt
import types/url
import utils/twtstr

type FtpHandle = ref object
  curl: CURL
  buffer: string
  dirmode: bool
  base: string
  path: string
  statusline: bool

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  if nitems > 0:
    prepareMutation(line)
    copyMem(addr line[0], p, nitems)
  let op = cast[FtpHandle](userdata)
  if not op.statusline:
    if line.startsWith("150") or line.startsWith("125"):
      op.statusline = true
      var status: clong
      op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
      stdout.write("Status: " & $status & "\n")
      if op.dirmode:
        stdout.write("Content-Type: text/html\n")
      stdout.write("\n")
      if op.dirmode:
        stdout.write("""
<HTML>
<HEAD>
<BASE HREF=""" & op.base & """>
<TITLE>""" & op.path & """</TITLE>
</HEAD>
<BODY>
<H1>Index of """ & htmlEscape(op.path) & """</H1>
<PRE>
""")
      return nitems
    elif line.startsWith("530"): # login incorrect
      op.statusline = true
      var status: clong
      op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
      # unauthorized (shim http)
      stdout.write("""
Status: 401
Content-Type: text/html

<HTML>
<HEAD>
<TITLE>Unauthorized</TITLE>
</HEAD>
<BODY>
<PRE>
""" & htmlEscape(line) & """
</PRE>
</BODY>
</HTML>
""")
  return nitems

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size, nmemb: csize_t, userdata: pointer):
    csize_t {.cdecl.} =
  let op = cast[FtpHandle](userdata)
  if nmemb > 0:
    if op.dirmode:
      let i = op.buffer.len
      op.buffer.setLen(op.buffer.len + int(nmemb))
      prepareMutation(op.buffer)
      copyMem(addr op.buffer[i], p, nmemb)
    else:
      return csize_t(stdout.writeBuffer(p, int(nmemb)))
  return nmemb

proc finish(op: FtpHandle) =
  let op = op
  var items: seq[DirlistItem]
  for line in op.buffer.split('\n'):
    if line.len == 0: continue
    var i = 10 # permission
    template skip_till_space =
      while i < line.len and line[i] != ' ':
        inc i
    # link count
    i = line.skipBlanks(i)
    while i < line.len and line[i] in AsciiDigit:
      inc i
    # owner
    i = line.skipBlanks(i)
    skip_till_space
    # group
    i = line.skipBlanks(i)
    while i < line.len and line[i] != ' ':
      inc i
    # size
    i = line.skipBlanks(i)
    var sizes = ""
    while i < line.len and line[i] in AsciiDigit:
      sizes &= line[i]
      inc i
    let nsize = parseInt64(sizes).get(-1)
    # date
    i = line.skipBlanks(i)
    let datestarti = i
    skip_till_space # m
    i = line.skipBlanks(i)
    skip_till_space # d
    i = line.skipBlanks(i)
    skip_till_space # y
    let dates = line.substr(datestarti, i)
    inc i
    let name = line.substr(i)
    if name == "." or name == "..": continue
    case line[0]
    of 'l': # link
      let linki = name.find(" -> ")
      let linkfrom = name.substr(0, linki - 1)
      let linkto = name.substr(linki + 4) # you?
      items.add(DirlistItem(
        t: ITEM_LINK,
        name: linkfrom,
        modified: dates,
        linkto: linkto
      ))
    of 'd': # directory
      items.add(DirlistItem(
        t: ITEM_DIR,
        name: name,
        modified: dates
      ))
    else: # file
      items.add(DirlistItem(
        t: ITEM_FILE,
        name: name,
        modified: dates,
        nsize: int(nsize)
      ))
  stdout.write(makeDirlist(items))
  stdout.write("\n</PRE>\n</BODY>\n</HTML>\n")

proc main() =
  let curl = curl_easy_init()
  doAssert curl != nil
  let surl = getEnv("QUERY_STRING")
  let opath = getEnv("MAPPED_URI_PATH")
  let path = percentDecode(opath)
  # By default, cURL CWD's into relative paths, and an extra slash is
  # necessary to specify absolute paths.
  # This is incredibly confusing, and probably not what the user wanted.
  # So we work around it by adding the extra slash ourselves.
  let hackurl = newURL(surl).get
  hackurl.setPathname('/' & opath)
  let csurl = hackurl.serialize()
  curl.setopt(CURLOPT_URL, csurl)
  let dirmode = path.len > 0 and path[^1] == '/'
  let op = FtpHandle(
    curl: curl,
    dirmode: dirmode
  )
  curl.setopt(CURLOPT_HEADERDATA, op)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
  curl.setopt(CURLOPT_WRITEDATA, op)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  curl.setopt(CURLOPT_FTP_FILEMETHOD, CURLFTPMETHOD_SINGLECWD)
  if dirmode:
    op.base = surl
    op.path = path
  let purl = getEnv("ALL_PROXY")
  if purl != "":
    curl.setopt(CURLOPT_PROXY, purl)
  if getEnv("REQUEST_METHOD") != "GET":
    let code = $int(ERROR_INVALID_METHOD)
    stdout.write("Cha-Control: ConnectionError " & $code & "\n")
    return
  let res = curl_easy_perform(curl)
  if res != CURLE_OK:
    if not op.statusline:
      stdout.write(getCurlConnectionError(res))
  elif op.dirmode:
    op.finish()
  curl_easy_cleanup(curl)

main()
