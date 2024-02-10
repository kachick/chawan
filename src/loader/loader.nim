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
    connecting*: Table[int, ConnectData]
    ongoing*: Table[int, OngoingData]
    unregistered*: seq[int]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)

  ConnectData = object
    promise: Promise[JSResult[Response]]
    stream: Stream
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

  LoaderContext = ref object
    refcount: int
    ssock: ServerSocket
    alive: bool
    config: LoaderConfig
    handleMap: Table[int, LoaderHandle]
    outputMap: Table[int, OutputHandle]
    clientFdMap: seq[tuple[pid, fd: int, output: OutputHandle]]
    referrerpolicy: ReferrerPolicy
    selector: Selector[int]
    fd: int

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

proc loadResource(ctx: LoaderContext, request: Request, handle: LoaderHandle) =
  var redo = true
  var tries = 0
  var prevurl: URL = nil
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
      handle.loadCGI(request, ctx.config.cgiDir, ctx.config.libexecPath, prevurl)
      if handle.istream == nil:
        handle.close()
      else:
        let output = handle.output
        output.ostream.setBlocking(false)
        ctx.selector.registerHandle(handle.istream.fd, {Read}, 0)
        ctx.selector.registerHandle(output.ostream.fd, {Write}, 0)
        let ofl = fcntl(handle.istream.fd, F_GETFL, 0)
        discard fcntl(handle.istream.fd, F_SETFL, ofl or O_NONBLOCK)
        ctx.handleMap[handle.istream.fd] = handle
        if output.sostream != nil:
          # replace the fd with the new one in outputMap if stream was
          # redirected
          # (kind of a hack, but should always work)
          ctx.outputMap[output.ostream.fd] = output
          ctx.outputMap.del(output.sostream.fd)
          # currently only the main buffer stream can have redirects, and we
          # don't suspend/resume it; if we did, we would have to put the new
          # output stream's clientFd in clientFdMap too.
          ctx.clientFdMap.del(output.sostream.fd)
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

proc onLoad(ctx: LoaderContext, stream: SocketStream) =
  var request: Request
  stream.sread(request)
  let handle = newLoaderHandle(
    stream,
    request.canredir,
    request.clientPid,
    request.clientFd
  )
  assert request.clientPid != 0
  when defined(debug):
    handle.url = request.url
  if not ctx.config.filter.match(request.url):
    handle.rejectHandle(ERROR_DISALLOWED_URL)
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
    ctx.clientFdMap.add((request.clientPid, request.clientFd, handle.output))
    ctx.loadResource(request, handle)

func findClientFdEntry(ctx: LoaderContext, pid, fd: int): int =
  for i, (itpid, itfd, _) in ctx.clientFdMap:
    if pid == itpid and fd == itfd:
      return i
  return -1

func findOutputByClientFd(ctx: LoaderContext, pid, fd: int): OutputHandle =
  let i = ctx.findClientFdEntry(pid, fd)
  if i != -1:
    return ctx.clientFdMap[i].output
  return nil

proc acceptConnection(ctx: LoaderContext) =
  let stream = ctx.ssock.acceptSocketStream()
  try:
    var cmd: LoaderCommand
    stream.sread(cmd)
    case cmd
    of LOAD:
      ctx.onLoad(stream)
    of TEE:
      var clientPid: int
      var clientFd: int
      var pid: int
      var fd: int
      stream.sread(pid)
      stream.sread(fd)
      stream.sread(clientPid)
      stream.sread(clientFd)
      let output = ctx.findOutputByClientFd(pid, fd)
      if output != nil:
        output.tee(stream, clientPid, clientFd)
      stream.swrite(output != nil)
    of SUSPEND:
      var pid: int
      var fds: seq[int]
      stream.sread(pid)
      stream.sread(fds)
      for fd in fds:
        let output = ctx.findOutputByClientFd(pid, fd)
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
        let output = ctx.findOutputByClientFd(pid, fd)
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
  except ErrorBrokenPipe:
    # receiving end died while reading the file; give up.
    stream.close()

proc exitLoader(ctx: LoaderContext) =
  ctx.ssock.close()
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

proc runFileLoader*(fd: cint, config: LoaderConfig) =
  var ctx = initLoaderContext(fd, config)
  while ctx.alive:
    let events = ctx.selector.select(-1)
    var unregRead: seq[LoaderHandle]
    var unregWrite: seq[OutputHandle]
    for event in events:
      if Read in event.events:
        if event.fd == ctx.fd: # incoming connection
          ctx.acceptConnection()
        else:
          let handle = ctx.handleMap[event.fd]
          assert event.fd == handle.istream.fd
          while true:
            let buffer = newLoaderBuffer()
            try:
              buffer.len = handle.istream.recvData(addr buffer[0], buffer.cap)
              if buffer.len == 0:
                break
              handle.addBuffer(buffer)
              if buffer.len < buffer.cap:
                break
            except ErrorAgain, ErrorWouldBlock: # retry later
              break
            except ErrorBrokenPipe: # sender died; stop streaming
              unregRead.add(handle)
              break
      if Write in event.events:
        let output = ctx.outputMap[event.fd]
        while output.currentBuffer != nil:
          let buffer = output.currentBuffer
          try:
            let i = output.currentBufferIdx
            assert buffer.len - i > 0
            let n = output.sendData(addr buffer[i], buffer.len - i)
            output.currentBufferIdx += n
            if output.currentBufferIdx < buffer.len:
              break
            output.bufferCleared() # swap out buffer
          except ErrorAgain, ErrorWouldBlock: # never mind
            break
          except ErrorBrokenPipe: # receiver died; stop streaming
            unregWrite.add(output)
            break
        if output.istreamAtEnd and output.currentBuffer == nil:
          # after EOF, but not appended in this send cycle
          unregWrite.add(output)
      if Error in event.events:
        assert event.fd != ctx.fd
        ctx.outputMap.withValue(event.fd, outputp): # ostream died
          unregWrite.add(outputp[])
        do: # istream died
          let handle = ctx.handleMap[event.fd]
          unregRead.add(handle)
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
        ctx.selector.unregister(output.ostream.fd)
        ctx.outputMap.del(output.ostream.fd)
        if output.clientFd != -1:
          let i = ctx.findClientFdEntry(output.clientPid, output.clientFd)
          ctx.clientFdMap.del(i)
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
  input.clientPid = getpid()
  input.clientFd = int(stream.fd)
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
  data.request.clientPid = getpid()
  data.request.clientFd = int(stream.fd)
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

proc switchStream*(data: var ConnectData, stream: Stream) =
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

proc suspend*(loader: FileLoader, pid: int, fds: seq[int]) =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(SUSPEND)
  stream.swrite(pid)
  stream.swrite(fds)
  stream.close()

proc resume*(loader: FileLoader, pid: int, fds: seq[int]) =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(RESUME)
  stream.swrite(pid)
  stream.swrite(fds)
  stream.close()

proc tee*(loader: FileLoader, pid, fd: int): Stream =
  let stream = connectSocketStream(loader.process, false, blocking = true)
  stream.swrite(TEE)
  stream.swrite(pid)
  stream.swrite(fd)
  stream.swrite(int(getpid()))
  stream.swrite(int(stream.fd))
  return stream

const BufferSize = 4096

proc handleHeaders(loader: FileLoader, request: Request, response: Response,
    stream: Stream): bool =
  var status: int
  stream.sread(status)
  response.status = cast[uint16](status)
  response.headers = newHeaders()
  stream.sread(response.headers)
  loader.applyHeaders(request, response)
  # Only a stream of the response body may arrive after this point.
  response.body = stream
  return true # success

proc onConnected*(loader: FileLoader, fd: int) =
  let connectData = loader.connecting[fd]
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var res: int
  stream.sread(res)
  let response = newResponse(res, request, fd, stream)
  if res == 0 and loader.handleHeaders(request, response, stream):
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
    SocketStream(stream).source.getFd().setBlocking(false)
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

proc doRequest*(loader: FileLoader, request: Request, blocking = true,
    canredir = false): Response =
  let response = Response(url: request.url)
  let stream = connectSocketStream(loader.process, false, blocking = true)
  if canredir:
    request.canredir = true #TODO set this somewhere else?
  request.clientPid = getpid()
  request.clientFd = int(stream.fd)
  stream.swrite(LOAD)
  stream.swrite(request)
  stream.flush()
  stream.sread(response.res)
  if response.res == 0:
    if loader.handleHeaders(request, response, stream):
      if not blocking:
        stream.source.getFd().setBlocking(blocking)
  else:
    var msg: string
    stream.sread(msg)
    if msg != "":
      response.internalMessage = msg
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

proc setReferrerPolicy*(loader: FileLoader, referrerpolicy: ReferrerPolicy) =
  let stream = connectSocketStream(loader.process)
  if stream != nil:
    stream.swrite(SET_REFERRER_POLICY)
    stream.swrite(referrerpolicy)
  stream.close()
