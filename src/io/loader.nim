import httpclient
import options
import os
import osproc
import streams
import strutils

import bindings/curl
import config/config
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

  CurlStream = ref object of StreamObj
    f: File
    curl: Process

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

# copy paste from stdlib for compatibility
# ew.
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

proc fsAtEnd(s: Stream): bool = return endOfFile(CurlStream(s).f)
proc fsSetPosition(s: Stream, pos: int) = setFilePos(CurlStream(s).f, pos)
proc fsGetPosition(s: Stream): int = return int(getFilePos(CurlStream(s).f))

proc fsReadData(s: Stream, buffer: pointer, bufLen: int): int =
  result = readBuffer(CurlStream(s).f, buffer, bufLen)

proc fsReadDataStr(s: Stream, buffer: var string, slice: Slice[int]): int =
  result = readBuffer(CurlStream(s).f, addr buffer[slice.a], slice.b + 1 - slice.a)

proc fsPeekData(s: Stream, buffer: pointer, bufLen: int): int =
  let pos = fsGetPosition(s)
  defer: fsSetPosition(s, pos)
  result = readBuffer(CurlStream(s).f, buffer, bufLen)

proc fsReadLine(s: Stream, line: var string): bool =
  result = readLine(CurlStream(s).f, line)

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

proc getPageLibcurl(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartDataClone = nil): LoadResult =
  let curl = curl_easy_init()

  if curl == nil: return # fail

  let surl = url.serialize()
  curl_easy_setopt(curl, CURLOPT_URL, cstring(surl))

  var cs = newStringStream()
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, cs)
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curlWriteBody)

  let headers = newHttpHeaders(true)
  let headerres = HeaderResult(headers: headers)
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, headerres)
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, curlWriteHeader)
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1)

  var mime: curl_mime = nil

  case smethod
  of HttpGet: curl_easy_setopt(curl, CURLOPT_HTTPGET, 1)
  of HttpPost:
    curl_easy_setopt(curl, CURLOPT_POST, 1)
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
      curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime)
    elif body != "":
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, cstring(body))
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, body.len)
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
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, slist)

  let res = curl_easy_perform(curl)
  if res == CURLE_OK: # TODO handle http errors
    cs.setPosition(0)
    result.s = cs

    let ct = headers.getOrDefault("Content-Type")
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(url.path.serialize())

  curl_easy_cleanup(curl)
  if mime != nil:
    curl_mime_free(mime)
  if slist != nil:
    curl_slist_free_all(slist)

proc getPageCurl(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartDataClone = nil): LoadResult =
  var curl_args: seq[string]

  # silent
  curl_args.add("-s")

  # follow
  curl_args.add("-L")

  # dump headers
  curl_args.add("-D")
  curl_args.add("/dev/stderr")

  # headers
  var requestHeaders = newHttpHeaders(true)
  requestHeaders.table = loader.headers.table
  if mimetype != "":
    requestHeaders["Content-Type"] = mimetype
  for k, v in requestHeaders:
    curl_args.add("-H")
    curl_args.add(k & ": " & v)

  # method
  curl_args.add("-X")
  curl_args.add($smethod)

  # body
  if body != "":
    curl_args.add("--data-binary")
    curl_args.add(body)

  # multipart
  if multipart != nil:
    for entry in multipart.content:
      if entry.isFile:
        #TODO TODO TODO
        continue
      curl_args.add("--form-string")
      curl_args.add(entry.name & '=' & entry.content)

  # url
  curl_args.add("--")
  curl_args.add(url.serialize(true))

  # launch
  let curl_proc = startProcess(gconfig.curl_binary, "", curl_args, options = {})

  # output stream
  var f: File
  if not open(f, curl_proc.outputHandle, fmRead): raiseOSError(osLastError())
  var cs = new(CurlStream)
  cs.curl = curl_proc
  cs.f = f
  cs.readDataImpl = fsReadData
  cs.closeImpl = (proc(s: Stream) = CurlStream(s).curl.close())
  cs.atEndImpl = fsAtEnd
  cs.readDataStrImpl = fsReadDataStr
  cs.readDataImpl = fsReadData
  cs.readLineImpl = fsReadLine
  cs.peekDataImpl = fsPeekData
  result.s = cs

  # response headers
  result.contenttype = guessContentType(url.path.serialize())
  let es = curl_proc.errorStream
  if not es.atEnd:
    discard es.readLine() # status code
  var headers = newHttpHeaders(true)
  while not es.atEnd:
    let line = es.readLine()
    let k = line.until(':')
    if k.len == line.len:
      break # no colon, invalid or empty - so assume headers are done
    let v = line.substr(k.len + 1).strip()
    headers.add(k, v)
  let ct = headers.getOrDefault("Content-Type")
  if ct != "":
    result.contenttype = ct.until(';')
  else:
    result.contenttype = guessContentType(url.path.serialize())

  if curl_proc.peekExitCode() > 0:
    result.contenttype = ""
    result.s = nil

proc getPage*(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  if url.scheme == "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_dos()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
  elif url.scheme == "http" or url.scheme == "https":
    if gconfig.use_curl:
      return getPageLibcurl(loader, url, smethod, mimetype, body, cast[MultipartDataClone](multipart))
    var requestHeaders = newHttpHeaders(true)
    requestHeaders.table = loader.headers.table
    if mimetype != "":
      requestHeaders["Content-Type"] = mimetype
    let resp = loader.http.request(url.serialize(true), smethod, body, requestHeaders, multipart)
    let ct = resp.contentType()
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(url.path.serialize())
    resp.bodystream.setPosition(0)
    result.s = resp.bodyStream

proc getPage*(loader: FileLoader, url: string, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  let url = parseUrl(url)
  if url.isnone:
    raise newException(Exception, "Invalid URL")
  loader.getPage(url.get, smethod, mimetype, body, multipart)
