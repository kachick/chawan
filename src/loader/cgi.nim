import std/options
import std/os
import std/posix
import std/streams
import std/strutils

import io/posixstream
import io/stdio
import loader/connecterror
import loader/headers
import loader/loaderhandle
import loader/request
import types/formdata
import types/opt
import types/url
import utils/twtstr

proc putMappedURL(url: URL) =
  putEnv("MAPPED_URI_SCHEME", url.scheme)
  putEnv("MAPPED_URI_USERNAME", url.username)
  putEnv("MAPPED_URI_PASSWORD", url.password)
  putEnv("MAPPED_URI_HOST", url.hostname)
  putEnv("MAPPED_URI_PORT", url.port)
  putEnv("MAPPED_URI_PATH", url.path.serialize())
  putEnv("MAPPED_URI_QUERY", url.query.get(""))

proc setupEnv(cmd, scriptName, pathInfo, requestURI, myDir: string;
    request: Request; contentLen: int; prevURL: URL) =
  let url = request.url
  putEnv("SCRIPT_NAME", scriptName)
  putEnv("SCRIPT_FILENAME", cmd)
  putEnv("REQUEST_URI", requestURI)
  putEnv("REQUEST_METHOD", $request.httpMethod)
  var headers = ""
  for k, v in request.headers:
    headers &= k & ": " & v & "\r\n"
  putEnv("REQUEST_HEADERS", headers)
  if prevURL != nil:
    putMappedURL(prevURL)
  if pathInfo != "":
    putEnv("PATH_INFO", pathInfo)
  if url.query.isSome:
    putEnv("QUERY_STRING", url.query.get)
  if request.httpMethod == HTTP_POST:
    if request.multipart.isSome:
      putEnv("CONTENT_TYPE", request.multipart.get.getContentType())
    else:
      putEnv("CONTENT_TYPE", request.headers.getOrDefault("Content-Type", ""))
    putEnv("CONTENT_LENGTH", $contentLen)
  if "Cookie" in request.headers:
    putEnv("HTTP_COOKIE", request.headers["Cookie"])
  if request.referrer != nil:
    putEnv("HTTP_REFERER", $request.referrer)
  if request.proxy != nil:
    putEnv("ALL_PROXY", $request.proxy)
  setCurrentDir(myDir)

type ControlResult = enum
  crDone, crContinue, crError

proc handleFirstLine(handle: LoaderHandle; line: string; headers: Headers;
    status: var uint16): ControlResult =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    handle.sendResult(ERROR_CGI_MALFORMED_HEADER)
    return crError
  let v = line.substr(k.len + 1).strip()
  if k.equalsIgnoreCase("Status"):
    handle.sendResult(0) # success
    status = parseUInt16(v, allowSign = false).get(0)
    return crContinue
  if k.equalsIgnoreCase("Cha-Control"):
    if v.startsWithIgnoreCase("Connected"):
      handle.sendResult(0) # success
      return crContinue
    elif v.startsWithIgnoreCase("ConnectionError"):
      let errs = v.split(' ')
      if errs.len <= 1:
        handle.sendResult(ERROR_CGI_INVALID_CHA_CONTROL)
      else:
        let fb = int32(ERROR_CGI_INVALID_CHA_CONTROL)
        let code = int(parseInt32(errs[1]).get(fb))
        var message = ""
        if errs.len > 2:
          message &= errs[2]
          for i in 3 ..< errs.len:
            message &= ' '
            message &= errs[i]
        handle.sendResult(code, message)
      return crError
    elif v.startsWithIgnoreCase("ControlDone"):
      return crDone
    handle.sendResult(ERROR_CGI_INVALID_CHA_CONTROL)
    return crError
  handle.sendResult(0) # success
  headers.add(k, v)
  return crDone

proc handleControlLine(handle: LoaderHandle, line: string, headers: Headers,
    status: var uint16): ControlResult =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    return crError
  let v = line.substr(k.len + 1).strip()
  if k.equalsIgnoreCase("Status"):
    status = parseUInt16(v, allowSign = false).get(0)
    return crContinue
  if k.equalsIgnoreCase("Cha-Control"):
    if v.startsWithIgnoreCase("ControlDone"):
      return crDone
    return crError
  headers.add(k, v)
  return crDone

# returns false if transfer was interrupted
proc handleLine(handle: LoaderHandle, line: string, headers: Headers) =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    return
  let v = line.substr(k.len + 1).strip()
  headers.add(k, v)

proc loadCGI*(handle: LoaderHandle; request: Request; cgiDir: seq[string];
    prevURL: URL) =
  if cgiDir.len == 0:
    handle.sendResult(ERROR_NO_CGI_DIR)
    return
  var path = percentDecode(request.url.pathname)
  if path.startsWith("/cgi-bin/"):
    path.delete(0 .. "/cgi-bin/".high)
  elif path.startsWith("/$LIB/"):
    path.delete(0 .. "/$LIB/".high)
  if path == "" or request.url.hostname != "":
    handle.sendResult(ERROR_INVALID_CGI_PATH)
    return
  var basename: string
  var pathInfo: string
  var cmd: string
  var scriptName: string
  var requestURI: string
  var myDir: string
  if path[0] == '/':
    for dir in cgiDir:
      if path.startsWith(dir):
        basename = path.substr(dir.len).until('/')
        pathInfo = path.substr(dir.len + basename.len)
        cmd = dir / basename
        if not fileExists(cmd):
          continue
        myDir = dir
        scriptName = path.substr(0, dir.len + basename.len)
        requestURI = cmd / pathInfo & request.url.search
        break
    if cmd == "":
      handle.sendResult(ERROR_INVALID_CGI_PATH)
      return
  else:
    basename = path.until('/')
    pathInfo = path.substr(basename.len)
    scriptName = "/cgi-bin/" & basename
    requestURI = "/cgi-bin/" & path & request.url.search
    for dir in cgiDir:
      cmd = dir / basename
      if fileExists(cmd):
        myDir = dir
        break
  if not fileExists(cmd):
    handle.sendResult(ERROR_CGI_FILE_NOT_FOUND)
    return
  if basename in ["", ".", ".."] or basename.startsWith("~"):
    handle.sendResult(ERROR_INVALID_CGI_PATH)
    return
  var pipefd: array[0..1, cint] # child -> parent
  if pipe(pipefd) == -1:
    handle.sendResult(ERROR_FAIL_SETUP_CGI)
    return
  # Pipe the request body as stdin for POST.
  var pipefd_read: array[0..1, cint] # parent -> child
  let needsPipe = request.body.isSome or request.multipart.isSome
  if needsPipe:
    if pipe(pipefd_read) == -1:
      handle.sendResult(ERROR_FAIL_SETUP_CGI)
      return
  var contentLen = 0
  if request.body.isSome:
    contentLen = request.body.get.len
  elif request.multipart.isSome:
    contentLen = request.multipart.get.calcLength()
  let pid = fork()
  if pid == -1:
    handle.sendResult(ERROR_FAIL_SETUP_CGI)
  elif pid == 0:
    discard close(pipefd[0]) # close read
    discard dup2(pipefd[1], 1) # dup stdout
    if needsPipe:
      discard close(pipefd_read[1]) # close write
      if pipefd_read[0] != 0:
        discard dup2(pipefd_read[0], 0) # dup stdin
        discard close(pipefd_read[0])
    else:
      closeStdin()
    # we leave stderr open, so it can be seen in the browser console
    setupEnv(cmd, scriptName, pathInfo, requestURI, myDir, request, contentLen,
      prevURL)
    discard execl(cstring(cmd), cstring(basename), nil)
    let code = int(ERROR_FAILED_TO_EXECUTE_CGI_SCRIPT)
    stdout.write("Cha-Control: ConnectionError " & $code & " " &
      ($strerror(errno)).deleteChars({'\n', '\r'}))
    quit(1)
  else:
    discard close(pipefd[1]) # close write
    if needsPipe:
      discard close(pipefd_read[0]) # close read
      let ps = newPosixStream(pipefd_read[1])
      if request.body.isSome:
        ps.write(request.body.get)
      elif request.multipart.isSome:
        let multipart = request.multipart.get
        for entry in multipart.entries:
          ps.writeEntry(entry, multipart.boundary)
      ps.close()
    handle.parser = HeaderParser(headers: newHeaders())
    handle.istream = newPosixStream(pipefd[0])

proc killHandle(handle: LoaderHandle) =
  if handle.parser.state != hpsBeforeLines:
    # not an ideal solution, but better than silently eating malformed
    # headers
    handle.output.ostream.setBlocking(true)
    handle.sendStatus(500)
    handle.sendHeaders(newHeaders())
    const msg = "Error: malformed header in CGI script"
    discard handle.output.ostream.sendData(msg)
  handle.parser = nil

proc parseHeaders0(handle: LoaderHandle; buffer: LoaderBuffer): int =
  let parser = handle.parser
  var s = parser.lineBuffer
  let L = if buffer == nil: 1 else: buffer.len
  for i in 0 ..< L:
    template die =
      handle.killHandle()
      return -1
    let c = if buffer != nil:
      char(buffer.page[i])
    else:
      '\n'
    if parser.crSeen and c != '\n':
      die
    parser.crSeen = false
    if c == '\r':
      parser.crSeen = true
    elif c == '\n':
      if s == "":
        if parser.state == hpsBeforeLines:
          # body comes immediately, so we haven't had a chance to send result
          # yet.
          handle.sendResult(0)
        handle.sendStatus(parser.status)
        handle.sendHeaders(parser.headers)
        handle.parser = nil
        return i + 1 # +1 to skip \n
      case parser.state
      of hpsBeforeLines:
        case handle.handleFirstLine(s, parser.headers, parser.status)
        of crDone: parser.state = hpsControlDone
        of crContinue: parser.state = hpsAfterFirstLine
        of crError: die
      of hpsAfterFirstLine:
        case handle.handleControlLine(s, parser.headers, parser.status)
        of crDone: parser.state = hpsControlDone
        of crContinue: discard
        of crError: die
      of hpsControlDone:
        handle.handleLine(s, parser.headers)
      s = ""
    else:
      s &= c
  if s != "":
    parser.lineBuffer = s
  return L

proc parseHeaders*(handle: LoaderHandle; buffer: LoaderBuffer): int =
  try:
    return handle.parseHeaders0(buffer)
  except ErrorBrokenPipe:
    handle.parser = nil
    return -1

proc finishParse*(handle: LoaderHandle) =
  discard handle.parseHeaders(nil)
