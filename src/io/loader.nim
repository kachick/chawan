import httpclient
import options
import streams

import types/mime
import types/url
import utils/twtstr

type
  FileLoader* = ref object
    http: HttpClient

  LoadResult* = object
    s*: Stream
    contenttype*: string

proc newFileLoader*(): FileLoader =
  new(result)
  result.http = newHttpClient()

proc getPage*(loader: FileLoader, url: Url, smethod: string = "GET", mimetype = "", body: string = "", multipart: MultipartData = nil): LoadResult =
  if url.scheme == "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_windows()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
  elif url.scheme == "http" or url.scheme == "https":
    let requestheaders = newHttpHeaders({ "User-Agent": "chawan", "Content-Type": mimetype}, true)
    let requestmethod = if smethod == "":
      "GET"
    else:
      smethod
    let resp = loader.http.request(url.serialize(true), requestmethod, body, requestheaders, multipart)
    let ct = resp.contentType()
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(url.path.serialize())
    resp.bodystream.setPosition(0)
    result.s = resp.bodyStream
