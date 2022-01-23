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

proc getPage*(loader: FileLoader, url: Url): LoadResult =
  if url.scheme == "file":
    let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
  elif url.scheme == "http" or url.scheme == "https":
    let resp = loader.http.get(url.serialize(true))
    let ct = resp.contentType()
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(url.path.serialize())
    result.s = resp.bodyStream
