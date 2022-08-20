import options
import streams
import tables
when defined(posix):
  import posix

import bindings/curl
import io/http
import io/process
import io/request
import io/serialize
import types/mime
import types/url

const DefaultHeaders = {
  "User-Agent": "chawan",
  "Accept": "text/html,text/*;q=0.5",
  "Accept-Language": "en;q=1.0",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
}.toTable().newHeaderList()

type FileLoader* = ref object
  defaultHeaders*: HeaderList
  process*: int
  istream*: Stream
  ostream*: Stream

proc loadFile(url: Url, ostream: Stream) =
  when defined(windows) or defined(OS2) or defined(DOS):
    let path = url.path.serialize_unicode_dos()
  else:
    let path = url.path.serialize_unicode()
  let istream = newFileStream(path, fmRead)
  if istream == nil:
    ostream.swrite(1)
    ostream.flush()
  else:
    ostream.swrite(0)
    ostream.swrite(200) # ok
    ostream.swrite(guessContentType(path))
    ostream.swrite(none(Url))
    while not istream.atEnd:
      const bufferSize = 4096
      var buffer {.noinit.}: array[bufferSize, char]
      while true:
        let n = readData(istream, addr buffer[0], bufferSize)
        if n == 0:
          break
        ostream.swrite(n)
        ostream.writeData(addr buffer[0], n)
        ostream.flush()
        if n < bufferSize:
          break
      ostream.swrite("")
      ostream.flush()

proc loadResource(loader: FileLoader, request: Request, ostream: Stream) =
  case request.url.scheme
  of "file":
    loadFile(request.url, ostream)
  of "http", "https":
    loadHttp(request, ostream)

proc runFileLoader(loader: FileLoader) =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    eprint "Failed to initialize libcurl."
    quit(1)
  let istream = newFileStream(stdin)
  let ostream = newFileStream(stdout)
  while true:
    try:
      let request = istream.readRequest()
      for k, v in loader.defaultHeaders.table:
        if k notin request.headers.table:
          request.headers.table[k] = v
      loader.loadResource(request, ostream)
    except IOError:
      # End-of-file, quit.
      # TODO this should be EOFError
      break
  istream.close()
  ostream.close()
  curl_global_cleanup()
  quit(0)

proc doRequest*(loader: FileLoader, request: Request): LoadResult =
  if loader.istream != nil:
    loader.istream.swrite(request)
    loader.istream.flush()
    loader.ostream.sread(result.res)
    if result.res == 0:
      loader.ostream.sread(result.status)
      loader.ostream.sread(result.contenttype)
      loader.ostream.sread(result.redirect)
      result.s = loader.ostream
  else:
    eprint "Error: no loader process"
    quit(1)

proc newFileLoader*(defaultHeaders: HeaderList): FileLoader =
  new(result)
  result.defaultHeaders = defaultHeaders
  when defined(posix):
    var pipefd_a: array[0..1, cint]
    var pipefd_b: array[0..1, cint]
    if pipe(pipefd_a) == -1:
      eprint "Failed to open pipe."
      quit(1)
    if pipe(pipefd_b) == -1:
      eprint "Failed to open pipe."
      quit(1)
    let pid = doFork()
    if pid == 0:
      # child process
      let readfd = pipefd_a[0] # get read a
      discard close(pipefd_a[1]) # close write a
      let writefd = pipefd_b[1] # get write b
      discard close(pipefd_b[0]) # close read b
      discard dup2(readfd, stdin.getFileHandle())
      discard dup2(writefd, stdout.getFileHandle())
      result.runFileLoader()
    else:
      result.process = pid
      let writefd = pipefd_a[1] # get write a
      discard close(pipefd_a[0]) # close read a
      let readfd = pipefd_b[0] # get read b
      discard close(pipefd_b[1]) # close write b
      var readf: File
      var writef: File
      if not open(readf, FileHandle(readfd), fmRead):
        eprint "Failed to open output handle."
        quit(1)
      if not open(writef, FileHandle(writefd), fmWrite):
        eprint "Failed to open input handle."
        quit(1)
      result.ostream = newFileStream(readf)
      result.istream = newFileStream(writef)

proc newFileLoader*(): FileLoader =
  newFileLoader(DefaultHeaders)
