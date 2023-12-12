import options
import os
import posix
import streams
import strutils

import extern/stdio
import io/posixstream
import loader/connecterror
import loader/headers
import loader/loaderhandle
import loader/request
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

proc setupEnv(cmd, scriptName, pathInfo, requestURI: string, request: Request,
    contentLen: int, prevURL: URL) =
  let url = request.url
  putEnv("SERVER_SOFTWARE", "Chawan")
  putEnv("SERVER_PROTOCOL", "HTTP/1.0")
  putEnv("SERVER_NAME", "localhost")
  putEnv("SERVER_PORT", "80")
  putEnv("REMOTE_HOST", "localhost")
  putEnv("REMOTE_ADDR", "127.0.0.1")
  putEnv("GATEWAY_INTERFACE", "CGI/1.1")
  putEnv("SCRIPT_NAME", scriptName)
  putEnv("SCRIPT_FILENAME", cmd)
  putEnv("REQUEST_URI", requestURI)
  putEnv("REQUEST_METHOD", $request.httpmethod)
  if prevURL != nil:
    putMappedURL(prevURL)
  if pathInfo != "":
    putEnv("PATH_INFO", pathInfo)
  if url.query.isSome:
    putEnv("QUERY_STRING", url.query.get)
  if request.httpmethod == HTTP_POST:
    putEnv("CONTENT_TYPE", request.headers.getOrDefault("Content-Type", ""))
    putEnv("CONTENT_LENGTH", $contentLen)
  if "Cookie" in request.headers:
    putEnv("HTTP_COOKIE", request.headers["Cookie"])
  if request.referer != nil:
    putEnv("HTTP_REFERER", $request.referer)
  if request.proxy != nil:
    let s = $request.proxy
    if request.proxy.scheme == "https" or request.proxy.scheme == "http":
      putEnv("http_proxy", s)
      putEnv("HTTP_PROXY", s)
      putEnv("HTTPS_proxy", s)
    putEnv("ALL_PROXY", s)

type ControlResult = enum
  RESULT_CONTROL_DONE, RESULT_CONTROL_CONTINUE, RESULT_ERROR

proc handleFirstLine(handle: LoaderHandle, line: string, headers: Headers,
    status: var int): ControlResult =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    discard handle.sendResult(ERROR_CGI_MALFORMED_HEADER)
    return RESULT_ERROR
  let v = line.substr(k.len + 1).strip()
  if k.equalsIgnoreCase("Status"):
    status = parseInt32(v).get(0)
    return RESULT_CONTROL_CONTINUE
  if k.equalsIgnoreCase("Cha-Control"):
    if v.startsWithIgnoreCase("Connected"):
      discard handle.sendResult(0) # success
      return RESULT_CONTROL_CONTINUE
    elif v.startsWithIgnoreCase("ConnectionError"):
      let errs = v.substr("ConnectionError".len + 1).split(' ')
      if errs.len == 0:
        discard handle.sendResult(ERROR_CGI_INVALID_CHA_CONTROL)
      else:
        let fb = int32(ERROR_CGI_INVALID_CHA_CONTROL)
        let code = int(parseInt32(errs[0]).get(fb))
        discard handle.sendResult(code)
      return RESULT_ERROR
    elif v.startsWithIgnoreCase("ControlDone"):
      return RESULT_CONTROL_DONE
    discard handle.sendResult(ERROR_CGI_INVALID_CHA_CONTROL)
    return RESULT_ERROR
  headers.add(k, v)
  return RESULT_CONTROL_DONE

proc handleControlLine(handle: LoaderHandle, line: string, headers: Headers,
    status: var int): ControlResult =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    return RESULT_ERROR
  let v = line.substr(k.len + 1).strip()
  if k.equalsIgnoreCase("Status"):
    status = parseInt32(v).get(0)
    return RESULT_CONTROL_CONTINUE
  if k.equalsIgnoreCase("Cha-Control"):
    if v.startsWithIgnoreCase("ControlDone"):
      return RESULT_CONTROL_DONE
    return RESULT_ERROR
  headers.add(k, v)
  return RESULT_CONTROL_DONE

# returns false if transfer was interrupted
proc handleLine(handle: LoaderHandle, line: string, headers: Headers) =
  let k = line.until(':')
  if k.len == line.len:
    # invalid
    return
  let v = line.substr(k.len + 1).strip()
  headers.add(k, v)

proc loadCGI*(handle: LoaderHandle, request: Request, cgiDir: seq[string],
    prevURL: URL) =
  template t(body: untyped) =
    if not body:
      return
  if cgiDir.len == 0:
    discard handle.sendResult(ERROR_NO_CGI_DIR)
    return
  var path = percentDecode(request.url.pathname)
  if path.startsWith("/cgi-bin/"):
    path.delete(0 .. "/cgi-bin/".high)
  elif path.startsWith("/$LIB/"):
    path.delete(0 .. "/$LIB/".high)
  if path == "" or request.url.hostname != "":
    discard handle.sendResult(ERROR_INVALID_CGI_PATH)
    return
  var basename: string
  var pathInfo: string
  var cmd: string
  var scriptName: string
  var requestURI: string
  if path[0] == '/':
    for dir in cgiDir:
      if path.startsWith(dir):
        basename = path.substr(dir.len).until('/')
        pathInfo = path.substr(dir.len + basename.len)
        cmd = dir / basename
        if not fileExists(cmd):
          continue
        scriptName = path.substr(0, dir.len + basename.len)
        requestURI = cmd / pathInfo & request.url.search
        break
    if cmd == "":
      discard handle.sendResult(ERROR_INVALID_CGI_PATH)
      return
  else:
    basename = path.until('/')
    pathInfo = path.substr(basename.len)
    scriptName = "/cgi-bin/" & basename
    requestURI = "/cgi-bin/" & path & request.url.search
    for dir in cgiDir:
      cmd = dir / basename
      if fileExists(cmd):
        break
  if not fileExists(cmd):
    discard handle.sendResult(ERROR_CGI_FILE_NOT_FOUND)
  if basename in ["", ".", ".."] or basename.startsWith("~"):
    discard handle.sendResult(ERROR_INVALID_CGI_PATH)
    return
  var pipefd: array[0..1, cint] # child -> parent
  if pipe(pipefd) == -1:
    discard handle.sendResult(ERROR_FAIL_SETUP_CGI)
    return
  # Pipe the request body as stdin for POST.
  var pipefd_read: array[0..1, cint] # parent -> child
  let needsPipe = request.body.isSome or request.multipart.isSome
  if needsPipe:
    if pipe(pipefd_read) == -1:
      discard handle.sendResult(ERROR_FAIL_SETUP_CGI)
      return
  var contentLen = 0
  if request.body.isSome:
    contentLen = request.body.get.len
  elif request.multipart.isSome:
    #TODO multipart
    # maybe use curl formdata? (the mime api has no serialization functions)
    discard
  let pid = fork()
  if pid == -1:
    t handle.sendResult(ERROR_FAIL_SETUP_CGI)
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
    setupEnv(cmd, scriptName, pathInfo, requestURI, request, contentLen,
      prevURL)
    discard execl(cstring(cmd), cstring(basename), nil)
    stdout.write("Content-Type: text/plain\r\n\r\nFailed to execute script.")
    quit(1)
  else:
    discard close(pipefd[1]) # close write
    if needsPipe:
      discard close(pipefd_read[0]) # close read
      let ps = newPosixStream(pipefd_read[1])
      if request.body.isSome:
        ps.write(request.body.get)
      elif request.multipart.isSome:
        #TODO
        discard
      ps.close()
    discard handle.sendResult(0) # success
    let ps = newPosixStream(pipefd[0])
    let headers = newHeaders()
    var status = 200
    if ps.atEnd:
      # no data?
      discard handle.sendResult(ERROR_CGI_NO_DATA)
      return
    let line = ps.readLine()
    if line == "": #\r\n
      # no headers, body comes immediately
      t handle.sendResult(0) # success
    else:
      var res = handle.handleFirstLine(line, headers, status)
      if res == RESULT_ERROR:
        return
      while not ps.atEnd and res == RESULT_CONTROL_CONTINUE:
        let line = ps.readLine()
        res = handle.handleControlLine(line, headers, status)
        if res == RESULT_ERROR:
          return
      while not ps.atEnd:
        let line = ps.readLine()
        if line == "": #\r\n
          break
        handle.handleLine(line, headers)
    t handle.sendStatus(status)
    t handle.sendHeaders(headers)
    var buffer: array[4096, uint8]
    while not ps.atEnd:
      let n = ps.readData(addr buffer[0], buffer.len)
      t handle.sendData(addr buffer[0], n)
    ps.close()
