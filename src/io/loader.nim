import httpclient
import options
import streams

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

proc getPage*(loader: FileLoader, url: Url, smethod: HttpMethod = HttpGet, mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  if url.scheme == "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_dos()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
  elif url.scheme == "http" or url.scheme == "https":
    var requestheaders = newHttpHeaders(true)
    requestheaders.table = loader.headers.table
    if mimetype != "":
      requestheaders["Content-Type"] = mimetype 
    let resp = loader.http.request(url.serialize(true), smethod, body, requestheaders, multipart)
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
