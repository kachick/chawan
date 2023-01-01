# A file loader server (?)
# The idea here is that we receive requests with a socket, then respond to each
# with a response (ideally a document.)
# For now, the protocol looks like:
# C: Request
# S: res (0 => success, _ => error)
# if success:
#  S: status code
#  S: headers
#  S: response body
#
# The body is passed to the stream as-is, so effectively nothing can follow it.

import nativesockets
import options
import streams
import tables
import net
when defined(posix):
  import posix

import bindings/curl
import io/about
import io/file
import io/http
import io/request
import io/urlfilter
import ips/serialize
import ips/serversocket
import ips/socketstream
import types/cookie
import types/mime
import types/referer
import types/url
import utils/twtstr

type
  FileLoader* = object
    process*: Pid

  LoaderCommand = enum
    LOAD, QUIT

  LoaderConfig* = object
    defaultheaders*: HeaderList
    filter*: URLFilter
    cookiejar*: CookieJar
    referrerpolicy*: ReferrerPolicy

proc loadResource(request: Request, ostream: Stream) =
  case request.url.scheme
  of "file":
    loadFile(request.url, ostream)
  of "http", "https":
    loadHttp(request, ostream)
  of "about":
    loadAbout(request, ostream)
  else:
    ostream.swrite(-1) # error
    ostream.flush()

var ssock: ServerSocket
proc runFileLoader*(fd: cint, config: LoaderConfig) =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    raise newException(Defect, "Failed to initialize libcurl.")
  ssock = initServerSocket()
  # The server has been initialized, so the main process can resume execution.
  var writef: File
  if not open(writef, FileHandle(fd), fmWrite):
    raise newException(Defect, "Failed to open input handle.")
  writef.write(char(0u8))
  writef.flushFile()
  close(writef)
  discard close(fd)
  onSignal SIGTERM, SIGINT:
    curl_global_cleanup()
    ssock.close()
    quit(1)
  while true:
    let stream = ssock.acceptSocketStream()
    try:
      var cmd: LoaderCommand
      stream.sread(cmd)
      case cmd
      of LOAD:
        var request: Request
        stream.sread(request)
        if not config.filter.match(request.url):
          stream.swrite(-1) # error
          stream.flush()
        else:
          for k, v in config.defaultHeaders.table:
            if k notin request.headers.table:
              request.headers.table[k] = v
          if config.cookiejar != nil and config.cookiejar.cookies.len > 0:
            if "Cookie" notin request.headers.table:
              let cookie = config.cookiejar.serialize(request.url)
              if cookie != "":
                request.headers["Cookie"] = cookie
          if request.referer != nil and "Referer" notin request.headers.table:
            let r = getReferer(request.referer, request.url, config.referrerpolicy)
            if r != "":
              request.headers["Referer"] = r
          loadResource(request, stream)
        stream.close()
      of QUIT:
        stream.close()
        break
    except EOFError:
      # End-of-file, quit.
      break
    stream.close()
  curl_global_cleanup()
  ssock.close()
  quit(0)

#TODO async requests...
proc doRequest*(loader: FileLoader, request: Request, blocking = true): Response =
  new(result)
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(LOAD)
  stream.swrite(request)
  stream.flush()
  stream.sread(result.res)
  if result.res == 0:
    stream.sread(result.status)
    stream.sread(result.headers)
    if "Content-Type" in result.headers.table:
      result.contenttype = result.headers.table["Content-Type"][0].until(';')
    else:
      result.contenttype = guessContentType($request.url.path)
    if "Location" in result.headers.table:
      if result.status in 301..303 or result.status in 307..308:
        let location = result.headers.table["Location"][0]
        let url = parseUrl(location, some(request.url))
        if url.isSome:
          if (result.status == 303 and
              request.httpmethod notin {HTTP_GET, HTTP_HEAD}) or
              (result.status == 301 or result.status == 302 and
              request.httpmethod == HTTP_POST):
            result.redirect = newRequest(url.get, HTTP_GET,
              mode = request.mode, credentialsMode = request.credentialsMode,
              destination = request.destination)
          else:
            result.redirect = newRequest(url.get, request.httpmethod,
              body = request.body, multipart = request.multipart,
              mode = request.mode, credentialsMode = request.credentialsMode,
              destination = request.destination)
    # Only a stream of the response body may arrive after this point.
    result.body = stream
    if not blocking:
      stream.source.getFd().setBlocking(blocking)

proc quit*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(QUIT)
