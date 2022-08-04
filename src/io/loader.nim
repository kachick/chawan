import options
import streams
import strutils
import tables

import bindings/curl
import types/mime
import types/url
import utils/twtstr

type
  HttpMethod* = enum
    HTTP_CONNECT, HTTP_DELETE, HTTP_GET, HTTP_HEAD, HTTP_OPTIONS, HTTP_PATCH,
    HTTP_POST, HTTP_PUT, HTTP_TRACE

type
  FileLoader* = ref object
    headers*: HttpHeaderList

  HttpHeaderList = ref object
    table: Table[string, seq[string]]

  LoadResult* = object
    s*: Stream
    contenttype*: string
    status*: int
    headers*: HttpHeaderList
    redirect*: Option[Url]

  HeaderResult = ref object
    statusline: bool
    headers: HttpHeaderList

const DefaultHeaders = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
}

proc newFileLoader*(headers: HttpHeaderList): FileLoader =
  new(result)
  result.headers = headers

proc newHttpHeaderList*(): HttpHeaderList =
  new(result)

proc add(headers: HttpHeaderList, k, v: string) =
  let k = k.toHeaderCase()
  if k notin headers.table:
    headers.table[k] = @[v]
  else:
    headers.table[k].add(v)

proc `[]=`(headers: HttpHeaderList, k, v: string) =
  headers.table[k.toHeaderCase()] = @[v]

iterator pairs(headers: HttpHeaderList): (string, string) =
  for k, vs in headers.table:
    for v in vs:
      yield (k, v)

proc newFileLoader*(): FileLoader =
  var headers = new(HttpHeaderList)
  for header in DefaultHeaders:
    headers[header[0]] = header[1]
  newFileLoader(headers)

proc getOrDefault*(headers: HttpHeaderList, k: string): string =
  let k = k.toHeaderCase()
  if k in headers.table:
    headers.table[k][0]
  else:
    k

# Originally from the stdlib
type
  MimePart* = object
    name, content: string
    case isFile: bool
    of true:
      filename, contentType: string
      fileSize: int64
      isStream: bool
    else: discard

  MimeData* = ref object
    content: seq[MimePart]

proc `[]=`*(multipart: MimeData, k, v: string) =
  multipart.content.add(MimePart(name: k, content: v))

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t, userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  for i in 0..<nitems:
    line[i] = p[i]

  let headers = cast[HeaderResult](userdata)
  if not headers.statusline:
    headers.statusline = true
    return nitems #TODO handle status line?

  let k = line.until(':')

  if k.len == line.len:
    return nitems # empty line (last, before body) or invalid (=> error)

  let v = line.substr(k.len + 1).strip()
  headers.headers.add(k, v)
  return nitems

proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t, userdata: pointer): csize_t {.cdecl.} =
  var s = newString(nmemb)
  for i in 0..<nmemb:
    s[i] = p[i]
  let stream = cast[Stream](userdata)
  stream.write(s)
  stream.flush()
  return nmemb

template setopt(curl: CURL, opt: CURLoption, arg: typed) =
  discard curl_easy_setopt(curl, opt, arg)

template setopt(curl: CURL, opt: CURLoption, arg: string) =
  discard curl_easy_setopt(curl, opt, cstring(arg))

template getinfo(curl: CURL, info: CURLINFO, arg: typed) =
  discard curl_easy_getinfo(curl, info, arg)

proc getPageLibcurl(loader: FileLoader, url: Url, smethod: HttpMethod = HTTP_GET, mimetype = "", body: string = "", multipart: MimeData = nil): LoadResult =
  let curl = curl_easy_init()

  if curl == nil: return # fail

  let surl = url.serialize()
  curl.setopt(CURLOPT_URL, surl)

  var cs = newStringStream()
  curl.setopt(CURLOPT_WRITEDATA, cs)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)

  let headers = newHttpHeaderList()
  let headerres = HeaderResult(headers: headers)
  curl.setopt(CURLOPT_HEADERDATA, headerres)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)

  var mime: curl_mime = nil

  case smethod
  of HTTP_GET: curl.setopt(CURLOPT_HTTPGET, 1)
  of HTTP_POST:
    curl.setopt(CURLOPT_POST, 1)
    if multipart != nil:
      mime = curl_mime_init(curl)
      if mime == nil: return # fail
      for entry in multipart.content:
        let part = curl_mime_addpart(mime)
        if part == nil: return # fail
        curl_mime_name(part, cstring(entry.name))
        if entry.isFile:
          if entry.isStream:
            curl_mime_filedata(part, cstring(entry.filename))
          else:
            let fd = readFile(entry.filename)
            curl_mime_data(part, cstring(fd), csize_t(fd.len))
          # may be overridden by curl_mime_filedata, so set it here
          curl_mime_filename(part, cstring(entry.filename))
        else:
          curl_mime_data(part, cstring(entry.content), csize_t(entry.content.len))
      curl.setopt(CURLOPT_MIMEPOST, mime)
    elif body != "":
      curl.setopt(CURLOPT_POSTFIELDS, cstring(body))
      curl.setopt(CURLOPT_POSTFIELDSIZE, body.len)
  else: discard #TODO

  var requestHeaders = newHttpHeaderList()
  requestHeaders.table = loader.headers.table
  if mimetype != "":
    requestHeaders["Content-Type"] = mimetype
  var slist: curl_slist = nil
  for k, v in requestHeaders:
    let header = k & ": " & v
    slist = curl_slist_append(slist, cstring(header))
  if slist != nil:
    curl.setopt(CURLOPT_HTTPHEADER, slist)

  let res = curl_easy_perform(curl)
  if res == CURLE_OK: # TODO handle errors
    cs.setPosition(0)
    result.s = cs

    let ct = headers.getOrDefault("Content-Type")
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(url.path.serialize())
    discard curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, addr result.status)
    if result.status in {301, 302, 303}: #TODO 300, 304, 307
      var urlp: cstring
      curl.getinfo(CURLINFO_REDIRECT_URL, addr urlp)
      if urlp != nil:
        let urls = $urlp
        result.redirect = parseUrl(urls, some(url))

  curl_easy_cleanup(curl)
  if mime != nil:
    curl_mime_free(mime)
  if slist != nil:
    curl_slist_free_all(slist)

proc getPage*(loader: FileLoader, url: Url, smethod: HttpMethod = HTTP_GET, mimetype = "", body: string = "", multipart: MimeData = nil): LoadResult =
  if url.scheme == "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_dos()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
    result.status = 200 # doesn't make much sense...
  elif url.scheme == "http" or url.scheme == "https":
    return getPageLibcurl(loader, url, smethod, mimetype, body, multipart)

proc getPage*(loader: FileLoader, url: string, smethod: HttpMethod = HTTP_GET, mimetype = "", body: string = "", multipart: MimeData = nil): LoadResult =
  let url = parseUrl(url)
  if url.isnone:
    raise newException(Exception, "Invalid URL")
  loader.getPage(url.get, smethod, mimetype, body, multipart)
