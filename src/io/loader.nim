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
import io/http
import io/process
import io/request
import io/serialize
import io/socketstream
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
let DefaultHeaders = DefaultHeaders0.newHeaderList()

type FileLoader* = ref object
  defaultHeaders*: HeaderList
  process*: Pid

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

proc loadResource(loader: FileLoader, request: Request, ostream: Stream) =
  case request.url.scheme
  of "file":
    loadFile(request.url, ostream)
  of "http", "https":
    loadHttp(request, ostream)
  else:
    ostream.swrite(-1) # error
    ostream.flush()

proc runFileLoader(loader: FileLoader, loadcb: proc()) =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    raise newException(Defect, "Failed to initialize libcurl.")
  let ssock = initServerSocket(getpid())
  # The server has been initialized, so the main process can resume execution.
  loadcb()
  while true:
    let stream = ssock.acceptSocketStream()
    try:
      let request = stream.readRequest()
      for k, v in loader.defaultHeaders.table:
        if k notin request.headers.table:
          request.headers.table[k] = v
      loader.loadResource(request, stream)
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
  let stream = connectSocketStream(loader.process)
  stream.swrite(request)
  stream.flush()
  stream.sread(result.res)
  if result.res == 0:
    stream.sread(result.status)
    stream.sread(result.headers)
    if "Content-Type" in result.headers.table:
      result.contenttype = result.headers.table["Content-Type"][0].until(';')
    else:
      result.contenttype = guessContentType($request.url)
    if "Location" in result.headers.table:
      let location = result.headers.table["Location"][0]
      result.redirect = parseUrl(location, some(request.url))
    # Only a stream of the response body may arrive after this point.
    result.body = stream

proc newFileLoader*(defaultHeaders: HeaderList): FileLoader =
  new(result)
  result.defaultHeaders = defaultHeaders
  when defined(posix):
    var pipefd: array[0..1, cint]
    if pipe(pipefd) == -1:
      raise newException(Defect, "Failed to open pipe.")
    let pid = fork()
    if pid == -1:
      raise newException(Defect, "Failed to fork network process")
    elif pid == 0:
      # child process
      discard close(pipefd[0]) # close read
      var writef: File
      if not open(writef, FileHandle(pipefd[1]), fmWrite):
        raise newException(Defect, "Failed to open input handle.")
      result.runFileLoader((proc() =
        writef.write(char(0u8))
        writef.flushFile()
        close(writef)
        discard close(pipefd[1])
      ))
    else:
      result.process = pid
      let readfd = pipefd[0] # get read
      discard close(pipefd[1]) # close write
      var readf: File
      if not open(readf, FileHandle(readfd), fmRead):
        raise newException(Defect, "Failed to open output handle.")
      assert readf.readChar() == char(0u8)
      close(readf)
      discard close(pipefd[0])
      

proc newFileLoader*(): FileLoader =
  newFileLoader(DefaultHeaders)
