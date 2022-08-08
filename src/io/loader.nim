import options
import streams
import tables
when defined(posix):
  import posix

import io/http
import io/loadertypes
import types/mime
import types/url

export loadertypes

const DefaultHeaders = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
}.toTable().newHeaderList()

proc doFork(): Pid =
  result = fork()
  if result == -1:
    eprint "Failed to fork child process."
    quit(1)
  elif result != 0:
    return result
  discard setsid()
  let pid = fork()
  if pid != 0:
    quit(0)
  return 0

proc newFileLoader*(defaultHeaders: HeaderList): FileLoader =
  new(result)
  result.defaultHeaders = defaultHeaders

proc newFileLoader*(): FileLoader =
  newFileLoader(DefaultHeaders)

proc getPage*(loader: FileLoader, url: Url, smethod: HttpMethod = HTTP_GET, mimetype = "", body = none(string), multipart = none(MimeData)): LoadResult =
  case url.scheme
  of "file":
    when defined(windows) or defined(OS2) or defined(DOS):
      let path = url.path.serialize_unicode_dos()
    else:
      let path = url.path.serialize_unicode()
    result.contenttype = guessContentType(path)
    result.s = newFileStream(path, fmRead)
    if result.s != nil:
      result.status = 200 # ok
    else:
      result.status = 404 # file not found
  of "http", "https":
    let request = loader.newRequest(url, smethod, {"Content-Type": mimetype}, body, multipart)
    return getPageHttp(request)
