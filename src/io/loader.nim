import httpclient
import options
import streams
import strutils

import bindings/curl
import types/mime
import types/url
import utils/twtstr

type
  FileLoader* = ref object
    http: HttpClient
    headers*: HttpHeaders

  LoadResult* = object
    s*: Stream
    contenttype*: string
    status*: int
    headers*: HttpHeaders
    redirect*: Option[Url]

  HeaderResult = ref object
    statusline: bool
    headers: HttpHeaders

const DefaultHeaders = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-control": "no-cache",
}

proc newFileLoader*(headers: HttpHeaders): FileLoader =
  new(result)
  result.http = newHttpClient()
  result.headers = headers

proc newFileLoader*(): FileLoader =
  var headers = newHttpHeaders(true)
  for header in DefaultHeaders:
    headers[header[0]] = header[1]
  newFileLoader(headers)

#TODO replace this with our own multipart object
type
  MultipartEntryClone* = object
    name, content: string
    case isFile: bool
    of true:
      filename, contentType: string
      fileSize: int64
      isStream: bool
    else: discard

  MultipartDataClone* = ref object
    content: seq[MultipartEntryClone]

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t, userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  for i in 0..<nitems:
    line[i] = p[i]

  let headers = cast[HeaderResult](userdata)
  if not headers.statusline:
    headers.statusline = true
    return nitems #TODO handle status line

  let k = line.until(':')

  if k.len == line.len:
    return nitems # probably empty line, or invalid

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

proc getPageLibcurl(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartDataClone = nil): LoadResult =
  let curl = curl_easy_init()

  if curl == nil: return # fail

  let surl = url.serialize()
  curl.setopt(CURLOPT_URL, surl)

  var cs = newStringStream()
  curl.setopt(CURLOPT_WRITEDATA, cs)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)

  let headers = newHttpHeaders(true)
  let headerres = HeaderResult(headers: headers)
  curl.setopt(CURLOPT_HEADERDATA, headerres)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
  #curl.setopt(CURLOPT_FOLLOWLOCATION, 1)

  var mime: curl_mime = nil

  case smethod
  of HttpGet: curl.setopt(CURLOPT_HTTPGET, 1)
  of HttpPost:
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
  else: discard

  var requestHeaders = newHttpHeaders(true)
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

proc getPage*(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  if url.scheme == "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_dos()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
    result.status = 200 # doesn't make much sense...
  elif url.scheme == "http" or url.scheme == "https":
    return getPageLibcurl(loader, url, smethod, mimetype, body, cast[MultipartDataClone](multipart))

proc getPage*(loader: FileLoader, url: string, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  let url = parseUrl(url)
  if url.isnone:
    raise newException(Exception, "Invalid URL")
  loader.getPage(url.get, smethod, mimetype, body, multipart)
