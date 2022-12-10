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

import options
import streams
import tables
import net
when defined(posix):
  import posix

import bindings/curl
import io/about
import io/http
import io/request
import ips/serialize
import ips/serversocket
import ips/socketstream
import types/mime
import types/url
import utils/twtstr

const DefaultHeaders0 = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
}.toTable()
let DefaultHeaders* = DefaultHeaders0.newHeaderList()

type
  FileLoader* = object
    process*: Pid

  LoaderCommand = enum
    LOAD, QUIT

proc loadFile(url: Url, ostream: Stream) =
  when defined(windows) or defined(OS2) or defined(DOS):
    let path = url.path.serialize_unicode_dos()
  else:
    let path = url.path.serialize_unicode()
  let istream = newFileStream(path, fmRead)
  if istream == nil:
    ostream.swrite(-1) # error
    ostream.flush()
  else:
    ostream.swrite(0)
    ostream.swrite(200) # ok
    ostream.swrite(newHeaderList())
    while not istream.atEnd:
      const bufferSize = 4096
      var buffer {.noinit.}: array[bufferSize, char]
      while true:
        let n = readData(istream, addr buffer[0], bufferSize)
        if n == 0:
          break
        ostream.writeData(addr buffer[0], n)
        ostream.flush()
        if n < bufferSize:
          break

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
proc runFileLoader*(fd: cint, defaultHeaders: HeaderList) =
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
        for k, v in defaultHeaders.table:
          if k notin request.headers.table:
            request.headers.table[k] = v
        loadResource(request, stream)
        stream.close()
      of QUIT:
        stream.close()
        break
    except IOError:
      # End-of-file, quit.
      # TODO this should be EOFError
      break
    stream.close()
  curl_global_cleanup()
  ssock.close()
  quit(0)

proc doRequest*(loader: FileLoader, request: Request): Response =
  new(result)
  let stream = connectSocketStream(loader.process, false, false)
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
      let location = result.headers.table["Location"][0]
      result.redirect = parseUrl(location, some(request.url))
    # Only a stream of the response body may arrive after this point.
    result.body = stream

proc quit*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(QUIT)
