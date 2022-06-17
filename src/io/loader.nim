import httpclient
import options
import os
import osproc
import streams
import streamwrapper
import strutils

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
      return getPageCurl(loader, url, smethod, mimetype, body, cast[MultipartDataClone](multipart))
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
