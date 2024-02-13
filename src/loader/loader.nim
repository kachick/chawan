# A file loader server (?)
# The idea here is that we receive requests with a socket, then respond to each
# with a response (ideally a document.)
# For now, the protocol looks like:
# C: Request
# S: res (0 => success, _ => error)
# if success:
#  S: status code
#  S: headers
#  if canredir:
#    C: redir?
#    if redir:
#      C: redirection file handle (through sendFileHandle)
#  S: response body (potentially into redirection file handle)
# else:
#  S: error message
#
# The body is passed to the stream as-is, so effectively nothing can follow it.
# canredir is a mechanism for piping files into pager-opened processes
# (i.e. mailcap).

import std/nativesockets
import std/net
import std/options
import std/posix
import std/selectors
import std/streams
import std/strutils
import std/tables

import extern/tempfile
import io/posixstream
import io/promise
import io/serialize
import io/serversocket
import io/socketstream
import io/urlfilter
import js/error
import js/javascript
import loader/cgi
import loader/connecterror
import loader/headers
import loader/loaderhandle
import loader/request
import loader/response
import loader/streamid
import types/cookie
import types/referer
import types/urimethodmap
import types/url
import utils/mimeguess
import utils/twtstr

import chakasu/charset

export request
export response

type
  FileLoader* = ref object
    process*: Pid
    clientPid*: int
    connecting*: Table[int, ConnectData]
    ongoing*: Table[int, OngoingData]
    unregistered*: seq[int]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)

  ConnectData = object
    promise: Promise[JSResult[Response]]
    stream: SocketStream
    request: Request

  OngoingData = object
    buf: string
    response: Response
    bodyRead: Promise[string]

  LoaderCommand = enum
    LOAD
    TEE
    SUSPEND
    RESUME
    ADDREF
    UNREF
    SET_REFERRER_POLICY
    PASS_FD

  LoaderContext = ref object
    refcount: int
    ssock: ServerSocket
    alive: bool
    config: LoaderConfig
    handleMap: Table[int, LoaderHandle]
    outputMap: Table[int, OutputHandle]
    referrerpolicy: ReferrerPolicy
    selector: Selector[int]
    fd: int
    # List of cached files. Note that fds from passFd are never cached.
    cacheMap: Table[string, string] # URL -> path
    # List of file descriptors passed by the pager.
    passedFdMap: Table[string, FileHandle]

  LoaderConfig* = object
    defaultheaders*: Headers
    filter*: URLFilter
    cookiejar*: CookieJar
    proxy*: URL
    # When set to false, requests with a proxy URL are overridden by the
    # loader proxy.
    acceptProxy*: bool
    cgiDir*: seq[string]
    uriMethodMap*: URIMethodMap
    w3mCGICompat*: bool
    libexecPath*: string
    tmpdir*: string

  FetchPromise* = Promise[JSResult[Response]]

#TODO this may be too low if we want to use urimethodmap for everything
const MaxRewrites = 4

func canRewriteForCGICompat(ctx: LoaderContext, path: string): bool =
  if path.startsWith("/cgi-bin/") or path.startsWith("/$LIB/"):
    return true
  for dir in ctx.config.cgiDir:
    if path.startsWith(dir):
      return true
  return false

proc rejectHandle(handle: LoaderHandle, code: ConnectErrorCode, msg = "") =
  handle.sendResult(code, msg)
  handle.close()

func findOutput(ctx: LoaderContext, id: StreamId): OutputHandle =
  assert id.pid != -1 and id.fd != -1
  for it in ctx.outputMap.values:
    if it.clientId == id:
      return it
  return nil

#TODO linear search over strings :(
func findCachedHandle(ctx: LoaderContext, cacheUrl: string): LoaderHandle =
  assert cacheUrl != ""
  for it in ctx.handleMap.values:
    if it.cached and it.cacheUrl == cacheUrl:
      return it
  return nil

proc delOutput(ctx: LoaderContext, id: StreamId) =
  let output = ctx.findOutput(id)
  if output != nil:
    ctx.outputMap.del(output.ostream.fd)

type PushBufferResult = enum
  pbrDone, pbrUnregister

# Either write data to the target output, or append it to the list of buffers to
# write and register the output in our selector.
proc pushBuffer(ctx: LoaderContext, output: OutputHandle, buffer: LoaderBuffer):
    PushBufferResult =
  if output.currentBuffer == nil:
    var n = 0
    try:
      n = output.ostream.sendData(buffer)
    except ErrorAgain, ErrorWouldBlock:
      discard
    except ErrorBrokenPipe:
      return pbrUnregister
    if n < buffer.len:
      output.currentBuffer = buffer
      output.currentBufferIdx = n
      ctx.selector.registerHandle(output.ostream.fd, {Write}, 0)
      output.registered = true
  else:
    output.addBuffer(buffer)
  return pbrDone

proc addFd(ctx: LoaderContext, handle: LoaderHandle, originalUrl: URL) =
  let output = handle.output
  output.ostream.setBlocking(false)
  ctx.selector.registerHandle(handle.istream.fd, {Read}, 0)
  let ofl = fcntl(handle.istream.fd, F_GETFL, 0)
  discard fcntl(handle.istream.fd, F_SETFL, ofl or O_NONBLOCK)
  ctx.handleMap[handle.istream.fd] = handle
  if output.sostream != nil:
    # replace the fd with the new one in outputMap if stream was
    # redirected
    # (kind of a hack, but should always work)
    ctx.outputMap[output.ostream.fd] = output
    ctx.outputMap.del(output.sostream.fd)
    if output.clientId != NullStreamId:
      ctx.delOutput(output.clientId)
      output.clientId = NullStreamId
  if originalUrl != nil:
    let tmpf = getTempFile(ctx.config.tmpdir)
    let ps = newPosixStream(tmpf, O_CREAT or O_WRONLY, 0o600)
    if ps != nil:
      output.tee(ps, NullStreamId)
      let surl = $originalUrl
      ctx.cacheMap[surl] = tmpf
      handle.cacheUrl = surl

proc loadStream(ctx: LoaderContext, handle: LoaderHandle, request: Request) =
  ctx.passedFdMap.withValue(request.url.host, fdp):
    handle.sendResult(0)
    handle.sendStatus(200)
    handle.sendHeaders(newHeaders())
    handle.istream = newPosixStream(fdp[])
    ctx.passedFdMap.del(request.url.host)
  do:
    handle.sendResult(ERROR_FILE_NOT_FOUND, "stream not found")

proc loadResource(ctx: LoaderContext, request: Request, handle: LoaderHandle) =
  var redo = true
  var tries = 0
  var prevurl: URL = nil
  let originalUrl = request.url
  while redo and tries < MaxRewrites:
    redo = false
    if ctx.config.w3mCGICompat and request.url.scheme == "file":
      let path = request.url.path.serialize_unicode()
      if ctx.canRewriteForCGICompat(path):
        let newURL = newURL("cgi-bin:" & path & request.url.search)
        if newURL.isSome:
          request.url = newURL.get
          inc tries
          redo = true
          continue
    if request.url.scheme == "cgi-bin":
      handle.loadCGI(request, ctx.config.cgiDir, ctx.config.libexecPath,
        prevurl)
      if handle.istream != nil:
        let originalUrl = if handle.cached: originalUrl else: nil
        ctx.addFd(handle, originalUrl)
      else:
        handle.close()
    elif request.url.scheme == "stream":
      ctx.loadStream(handle, request)
      if handle.istream != nil:
        let originalUrl = if handle.cached: originalUrl else: nil
        ctx.addFd(handle, originalUrl)
      else:
        handle.close()
    else:
      prevurl = request.url
      case ctx.config.uriMethodMap.findAndRewrite(request.url)
      of URI_RESULT_SUCCESS:
        inc tries
        redo = true
      of URI_RESULT_WRONG_URL:
        handle.rejectHandle(ERROR_INVALID_URI_METHOD_ENTRY)
      of URI_RESULT_NOT_FOUND:
        handle.rejectHandle(ERROR_UNKNOWN_SCHEME)
  if tries >= MaxRewrites:
    handle.rejectHandle(ERROR_TOO_MANY_REWRITES)

proc loadFromCache(ctx: LoaderContext, stream: SocketStream, request: Request) =
  let handle = newLoaderHandle(stream, request.canredir, request.clientId)
  let surl = $request.url
  let cachedHandle = ctx.findCachedHandle(surl)
  let output = handle.output
  ctx.cacheMap.withValue(surl, p):
    let ps = newPosixStream(p[], O_RDONLY, 0)
    if ps == nil:
      handle.rejectHandle(ERROR_FILE_NOT_IN_CACHE)
      ctx.cacheMap.del(surl)
      handle.close()
      return
    handle.sendResult(0)
    handle.sendStatus(200)
    handle.sendHeaders(newHeaders())
    if handle.cached:
      handle.cacheUrl = surl
    output.ostream.setBlocking(false)
    while true:
      let buffer = newLoaderBuffer()
      let n = ps.recvData(buffer)
      if n == 0:
        break
      if ctx.pushBuffer(output, buffer) == pbrUnregister:
        if output.registered:
          ctx.selector.unregister(output.ostream.fd)
        ps.close()
        return
      if n < buffer.cap:
        break
    ps.close()
  do:
    if cachedHandle == nil:
      handle.rejectHandle(ERROR_URL_NOT_IN_CACHE)
      return
  if cachedHandle != nil:
    # download is still ongoing; move output to the original handle
    handle.outputs.setLen(0)
    output.parent = cachedHandle
    cachedHandle.outputs.add(output)
  elif output.registered:
    output.istreamAtEnd = true
    ctx.outputMap[output.ostream.fd] = output
  else:
    output.ostream.close()

proc onLoad(ctx: LoaderContext, stream: SocketStream) =
  var request: Request
  stream.sread(request)
  let handle = newLoaderHandle(
    stream,
    request.canredir,
    request.clientId
  )
  assert request.clientId.pid != 0
  when defined(debug):
    handle.url = request.url
  if not ctx.config.filter.match(request.url):
    handle.rejectHandle(ERROR_DISALLOWED_URL)
  elif request.fromcache:
    ctx.loadFromCache(stream, request)
  else:
    for k, v in ctx.config.defaultheaders.table:
      if k notin request.headers.table:
        request.headers.table[k] = v
    if ctx.config.cookiejar != nil and ctx.config.cookiejar.cookies.len > 0:
      if "Cookie" notin request.headers.table:
        let cookie = ctx.config.cookiejar.serialize(request.url)
        if cookie != "":
          request.headers["Cookie"] = cookie
    if request.referer != nil and "Referer" notin request.headers:
      let r = getReferer(request.referer, request.url, ctx.referrerpolicy)
      if r != "":
        request.headers["Referer"] = r
    if request.proxy == nil or not ctx.config.acceptProxy:
      request.proxy = ctx.config.proxy
    let fd = int(stream.source.getFd())
    ctx.outputMap[fd] = handle.output
    ctx.loadResource(request, handle)

proc acceptConnection(ctx: LoaderContext) =
  let stream = ctx.ssock.acceptSocketStream()
  try:
    var cmd: LoaderCommand
    stream.sread(cmd)
    case cmd
    of LOAD:
      ctx.onLoad(stream)
    of TEE:
      var targetId: StreamId
      var clientId: StreamId
      stream.sread(targetId)
      stream.sread(clientId)
      let output = ctx.findOutput(targetId)
      if output != nil:
        output.tee(stream, clientId)
      stream.swrite(output != nil)
      stream.setBlocking(false)
    of SUSPEND:
      var pid: int
      var fds: seq[int]
      stream.sread(pid)
      stream.sread(fds)
      for fd in fds:
        let output = ctx.findOutput((pid, fd))
        if output != nil:
          # remove from the selector, so any new reads will be just placed
          # in the handle's buffer
          ctx.selector.unregister(output.ostream.fd)
    of RESUME:
      var pid: int
      var fds: seq[int]
      stream.sread(pid)
      stream.sread(fds)
      for fd in fds:
        let output = ctx.findOutput((pid, fd))
        if output != nil:
          # place the stream back into the selector, so we can write to it
          # again
          ctx.selector.registerHandle(output.ostream.fd, {Write}, 0)
    of ADDREF:
      inc ctx.refcount
    of UNREF:
      dec ctx.refcount
      if ctx.refcount == 0:
        ctx.alive = false
        stream.close()
      else:
        assert ctx.refcount > 0
    of SET_REFERRER_POLICY:
      stream.sread(ctx.referrerpolicy)
      stream.close()
    of PASS_FD:
      var id: string
      stream.sread(id)
      let fd = stream.recvFileHandle()
      ctx.passedFdMap[id] = fd
      stream.close()
  except ErrorBrokenPipe:
    # receiving end died while reading the file; give up.
    stream.close()

proc exitLoader(ctx: LoaderContext) =
  ctx.ssock.close()
  for path in ctx.cacheMap.values:
    discard unlink(cstring(path))
  quit(0)

var gctx: LoaderContext
proc initLoaderContext(fd: cint, config: LoaderConfig): LoaderContext =
  var ctx = LoaderContext(
    alive: true,
    config: config,
    refcount: 1,
    selector: newSelector[int]()
  )
  gctx = ctx
  #TODO ideally, buffered would be true. Unfortunately this conflicts with
  # sendFileHandle/recvFileHandle.
  ctx.ssock = initServerSocket(buffered = false, blocking = false)
  ctx.fd = int(ctx.ssock.sock.getFd())
  ctx.selector.registerHandle(ctx.fd, {Read}, 0)
  # The server has been initialized, so the main process can resume execution.
  var writef: File
  if not open(writef, FileHandle(fd), fmWrite):
    raise newException(Defect, "Failed to open input handle.")
  writef.write(char(0u8))
  writef.flushFile()
  close(writef)
  discard close(fd)
  onSignal SIGTERM, SIGINT:
    discard sig
    gctx.exitLoader()
  for dir in ctx.config.cgiDir.mitems:
    if dir.len > 0 and dir[^1] != '/':
      dir &= '/'
  return ctx

# Called whenever there is more data available to read.
proc handleRead(ctx: LoaderContext, handle: LoaderHandle,
    unregRead: var seq[LoaderHandle], unregWrite: var seq[OutputHandle]) =
  while true:
    let buffer = newLoaderBuffer()
    try:
      let n = handle.istream.recvData(buffer)
      if n == 0:
        break
      for output in handle.outputs:
        if ctx.pushBuffer(output, buffer) == pbrUnregister:
          unregWrite.add(output)
      if n < buffer.cap:
        break
    except ErrorAgain, ErrorWouldBlock: # retry later
      break
    except ErrorBrokenPipe: # sender died; stop streaming
      unregRead.add(handle)
      break

# This is only called when an OutputHandle could not read enough of one (or
# more) buffers, and we asked select to notify us when it will be available.
proc handleWrite(ctx: LoaderContext, output: OutputHandle,
    unregWrite: var seq[OutputHandle]) =
  while output.currentBuffer != nil:
    let buffer = output.currentBuffer
    try:
      let n = output.ostream.sendData(buffer, output.currentBufferIdx)
      output.currentBufferIdx += n
      if output.currentBufferIdx < buffer.len:
        break
      output.bufferCleared() # swap out buffer
    except ErrorAgain, ErrorWouldBlock: # never mind
      break
    except ErrorBrokenPipe: # receiver died; stop streaming
      unregWrite.add(output)
      break
  if output.currentBuffer == nil:
    if output.istreamAtEnd:
      # after EOF, no need to send anything more here
      unregWrite.add(output)
    else:
      # all buffers sent, no need to select on this output again for now
      output.registered = false
      ctx.selector.unregister(output.ostream.fd)

proc finishCycle(ctx: LoaderContext, unregRead: var seq[LoaderHandle],
    unregWrite: var seq[OutputHandle]) =
  # Unregister handles queued for unregistration.
  # It is possible for both unregRead and unregWrite to contain duplicates. To
  # avoid double-close/double-unregister, we set the istream/ostream of
  # unregistered handles to nil.
  for handle in unregRead:
    if handle.istream != nil:
      ctx.selector.unregister(handle.istream.fd)
      ctx.handleMap.del(handle.istream.fd)
      handle.istream.close()
      handle.istream = nil
      for output in handle.outputs:
        output.istreamAtEnd = true
        if output.currentBuffer == nil:
          unregWrite.add(output)
  for output in unregWrite:
    if output.ostream != nil:
      if output.registered:
        ctx.selector.unregister(output.ostream.fd)
      ctx.outputMap.del(output.ostream.fd)
      if output.clientId != NullStreamId:
        ctx.delOutput(output.clientId)
      output.ostream.close()
      output.ostream = nil
      let handle = output.parent
      let i = handle.outputs.find(output)
      handle.outputs.del(i)
      if handle.outputs.len == 0 and handle.istream != nil:
        # premature end of all output streams; kill istream too
        ctx.selector.unregister(handle.istream.fd)
        ctx.handleMap.del(handle.istream.fd)
        handle.istream.close()
        handle.istream = nil
    if output.sostream != nil:
      #TODO it is not clear what should happen when multiple outputs exist.
      #
      # Normally, sostream is created after redirection, and must be written
      # to & closed after the input has completely been written into the
      # output stream. e.g. runMailcapEntryFile uses this to wait for the file
      # to be completely downloaded before executing an entry that takes a
      # file parameter.
      #
      # We should either block clone in this case, or find a better way to
      # wait for file downloads to finish. (Note that the buffer remaining
      # opened until the file has been downloaded is a somewhat useful visual
      # indication; while it does not show progress (bad), it does at least
      # show that *something* has been opened. An alternative should probably
      # add a temporary entry to a file download screen or something.)
      try:
        output.sostream.swrite(true)
      except IOError:
        # ignore error, that just means the buffer has already closed the
        # stream
        discard
      output.sostream.close()
      output.sostream = nil

proc runFileLoader*(fd: cint, config: LoaderConfig) =
  var ctx = initLoaderContext(fd, config)
  while ctx.alive:
    let events = ctx.selector.select(-1)
    var unregRead: seq[LoaderHandle] = @[]
    var unregWrite: seq[OutputHandle] = @[]
    for event in events:
      if Read in event.events:
        if event.fd == ctx.fd: # incoming connection
          ctx.acceptConnection()
        else:
          ctx.handleRead(ctx.handleMap[event.fd], unregRead, unregWrite)
      if Write in event.events:
        ctx.handleWrite(ctx.outputMap[event.fd], unregWrite)
      if Error in event.events:
        assert event.fd != ctx.fd
        ctx.outputMap.withValue(event.fd, outputp): # ostream died
          unregWrite.add(outputp[])
        do: # istream died
          let handle = ctx.handleMap[event.fd]
          unregRead.add(handle)
    ctx.finishCycle(unregRead, unregWrite)
  ctx.exitLoader()

proc getAttribute(contentType, attrname: string): string =
  let kvs = contentType.after(';')
  var i = kvs.find(attrname)
  var s = ""
  if i != -1 and kvs.len > i + attrname.len and
      kvs[i + attrname.len] == '=':
    i += attrname.len + 1
    while i < kvs.len and kvs[i] in AsciiWhitespace:
      inc i
    var q = false
    for j, c in kvs.toOpenArray(i, kvs.high):
      if q:
        s &= c
      elif c == '\\':
        q = true
      elif c == ';' or c in AsciiWhitespace:
        break
      else:
        s &= c
  return s

proc applyHeaders(loader: FileLoader, request: Request, response: Response) =
  if "Content-Type" in response.headers.table:
    #TODO this is inefficient and broken on several levels. (In particular,
    # it breaks mailcap named attributes other than charset.)
    # Ideally, contentType would be a separate object type.
    let header = response.headers.table["Content-Type"][0].toLowerAscii()
    response.contentType = header.until(';').strip().toLowerAscii()
    response.charset = getCharset(header.getAttribute("charset"))
  else:
    response.contentType = guessContentType($response.url.path,
      "application/octet-stream", DefaultGuess)
  if "Location" in response.headers.table:
    if response.status in 301u16..303u16 or response.status in 307u16..308u16:
      let location = response.headers.table["Location"][0]
      let url = parseURL(location, option(request.url))
      if url.isSome:
        if (response.status == 303 and
            request.httpMethod notin {HTTP_GET, HTTP_HEAD}) or
            (response.status == 301 or response.status == 302 and
            request.httpMethod == HTTP_POST):
          response.redirect = newRequest(url.get, HTTP_GET,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)
        else:
          response.redirect = newRequest(url.get, request.httpMethod,
            body = request.body, multipart = request.multipart,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)

#TODO: add init
proc fetch*(loader: FileLoader, input: Request): FetchPromise =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  input.clientId = (loader.clientPid, int(stream.fd))
  stream.swrite(LOAD)
  stream.swrite(input)
  stream.flush()
  let fd = int(stream.source.getFd())
  loader.registerFun(fd)
  let promise = FetchPromise()
  loader.connecting[fd] = ConnectData(
    promise: promise,
    request: input,
    stream: stream
  )
  return promise

proc reconnect*(loader: FileLoader, data: ConnectData) =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  data.request.clientId = (loader.clientPid, int(stream.fd))
  stream.swrite(LOAD)
  stream.swrite(data.request)
  stream.flush()
  let fd = int(stream.source.getFd())
  loader.registerFun(fd)
  loader.connecting[fd] = ConnectData(
    promise: data.promise,
    request: data.request,
    stream: stream
  )

proc switchStream*(data: var ConnectData, stream: SocketStream) =
  data.stream = stream

proc switchStream*(loader: FileLoader, data: var OngoingData,
    stream: SocketStream) =
  data.response.body = stream
  let fd = int(stream.source.getFd())
  let realCloseImpl = stream.closeImpl
  stream.closeImpl = nil
  data.response.unregisterFun = proc() =
    loader.ongoing.del(fd)
    loader.unregistered.add(fd)
    loader.unregisterFun(fd)
    realCloseImpl(stream)

proc suspend*(loader: FileLoader, fds: seq[int]) =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(SUSPEND)
  stream.swrite(loader.clientPid)
  stream.swrite(fds)
  stream.close()

proc resume*(loader: FileLoader, fds: seq[int]) =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(RESUME)
  stream.swrite(loader.clientPid)
  stream.swrite(fds)
  stream.close()

proc tee*(loader: FileLoader, targetId: StreamId): SocketStream =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(TEE)
  stream.swrite(targetId)
  let clientId: StreamId = (loader.clientPid, int(stream.fd))
  stream.swrite(clientId)
  return stream

const BufferSize = 4096

proc handleHeaders(loader: FileLoader, request: Request, response: Response,
    stream: SocketStream) =
  var status: int
  stream.sread(status)
  response.status = cast[uint16](status)
  response.headers = newHeaders()
  stream.sread(response.headers)
  loader.applyHeaders(request, response)
  # Only a stream of the response body may arrive after this point.
  response.body = stream

proc onConnected*(loader: FileLoader, fd: int) =
  let connectData = loader.connecting[fd]
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var res: int
  stream.sread(res)
  let response = newResponse(res, request, fd, stream)
  if res == 0:
    loader.handleHeaders(request, response, stream)
    assert loader.unregisterFun != nil
    let realCloseImpl = stream.closeImpl
    stream.closeImpl = nil
    response.unregisterFun = proc() =
      loader.ongoing.del(fd)
      loader.unregistered.add(fd)
      loader.unregisterFun(fd)
      realCloseImpl(stream)
    loader.ongoing[fd] = OngoingData(
      response: response,
      bodyRead: response.bodyRead
    )
    stream.source.getFd().setBlocking(false)
    promise.resolve(JSResult[Response].ok(response))
  else:
    var msg: string
    # msg is discarded.
    #TODO maybe print if called from trusted code (i.e. global == client)?
    stream.sread(msg)
    loader.unregisterFun(fd)
    loader.unregistered.add(fd)
    let err = newTypeError("NetworkError when attempting to fetch resource")
    promise.resolve(JSResult[Response].err(err))
  loader.connecting.del(fd)

proc onRead*(loader: FileLoader, fd: int) =
  loader.ongoing.withValue(fd, buffer):
    let response = buffer[].response
    while not response.body.atEnd():
      let olen = buffer[].buf.len
      try:
        buffer[].buf.setLen(olen + BufferSize)
        let n = response.body.readData(addr buffer[].buf[olen], BufferSize)
        buffer[].buf.setLen(olen + n)
        if n == 0:
          break
      except ErrorAgain, ErrorWouldBlock:
        buffer[].buf.setLen(olen)
        break
    if response.body.atEnd():
      buffer[].bodyRead.resolve(buffer[].buf)
      buffer[].bodyRead = nil
      buffer[].buf = ""
      response.unregisterFun()

proc onError*(loader: FileLoader, fd: int) =
  loader.ongoing.withValue(fd, buffer):
    let response = buffer[].response
    when defined(debug):
      var lbuf {.noinit.}: array[BufferSize, char]
      if not response.body.atEnd():
        let n = response.body.readData(addr lbuf[0], lbuf.len)
        assert n == 0
      assert response.body.atEnd()
    buffer[].bodyRead.resolve(buffer[].buf)
    buffer[].bodyRead = nil
    buffer[].buf = ""
    response.unregisterFun()

proc doRequest*(loader: FileLoader, request: Request): Response =
  let response = Response(url: request.url)
  let stream = connectSocketStream(loader.process, false, blocking = true)
  request.clientId = (loader.clientPid, int(stream.fd))
  stream.swrite(LOAD)
  stream.swrite(request)
  stream.flush()
  stream.sread(response.res)
  if response.res == 0:
    loader.handleHeaders(request, response, stream)
  else:
    stream.sread(response.internalMessage)
  return response

proc addref*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(ADDREF)
    stream.close()

proc unref*(loader: FileLoader) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(UNREF)
    stream.close()

proc setReferrerPolicy*(loader: FileLoader, referrerpolicy: ReferrerPolicy) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(SET_REFERRER_POLICY)
    stream.swrite(referrerpolicy)
    stream.close()

proc passFd*(pid: Pid, id: string, fd: FileHandle) =
  let stream = connectSocketStream(pid, buffered = false)
  if stream != nil:
    stream.swrite(PASS_FD)
    stream.swrite(id)
    stream.sendFileHandle(fd)
    stream.close()
