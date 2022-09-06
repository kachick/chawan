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
import os
when defined(posix):
  import posix

import bindings/curl
import io/http
import io/request
import io/serialize
import io/socketstream
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

const SocketDirectory = "/tmp/cha/"
const SocketPathPrefix = SocketDirectory & "cha_sock_"
func getSocketPath(pid: Pid): string =
  SocketPathPrefix & $pid

proc runFileLoader(loader: FileLoader) =
  if curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK:
    raise newException(Defect, "Failed to initialize libcurl.")
  let path = getSocketPath(getpid())
  discard unlink(cstring(path))
  createDir(SocketDirectory)
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  bindUnix(sock, path)
  listen(sock)
  stdout.write(char(0u8))
  stdout.flushFile()
  while true:
    var sock2: Socket
    sock.accept(sock2)
    let istream = newSocketStream(sock2, nil)
    let ostream = newSocketStream(nil, sock2)
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
    close(sock2)
  curl_global_cleanup()
  close(sock)
  discard unlink(cstring(path))
  quit(0)

proc doRequest*(loader: FileLoader, request: Request): Response =
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  let path = getSocketPath(loader.process)
  connectUnix(sock, path)
  let istream = newSocketStream(nil, sock)
  let ostream = newSocketStream(sock, nil)
  istream.swrite(request)
  istream.flush()
  ostream.sread(result.res)
  if result.res == 0:
    ostream.sread(result.status)
    ostream.sread(result.headers)
    if "Content-Type" in result.headers.table:
      result.contenttype = result.headers.table["Content-Type"][0].until(';')
    if "Location" in result.headers.table:
      let location = result.headers.table["Location"][0]
      result.redirect = parseUrl(location, some(request.url))
    # Only a stream of the response body may arrive after this point.
    result.body = ostream

proc newFileLoader*(defaultHeaders: HeaderList): FileLoader =
  new(result)
  result.defaultHeaders = defaultHeaders
  when defined(posix):
    var pipefd_b: array[0..1, cint]
    if pipe(pipefd_b) == -1:
      raise newException(Defect, "Failed to open pipe.")
    let pid = fork()
    if pid == -1:
      raise newException(Defect, "Failed to fork network process")
    elif pid == 0:
      # child process
      let writefd = pipefd_b[1] # get write b
      discard close(pipefd_b[0]) # close read b
      discard dup2(writefd, stdout.getFileHandle())
      result.runFileLoader()
    else:
      result.process = pid
      let readfd = pipefd_b[0] # get read b
      discard close(pipefd_b[1]) # close write b
      var readf: File
      if not open(readf, FileHandle(readfd), fmRead):
        raise newException(Defect, "Failed to open output handle.")
      var n: uint8
      assert newFileStream(readf).readUint8() == 0u8

proc newFileLoader*(): FileLoader =
  newFileLoader(DefaultHeaders)
