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
# else:
#  S: error message
#
# The body is passed to the stream as-is, so effectively nothing can follow it.

import std/deques
import std/nativesockets
import std/net
import std/options
import std/os
import std/posix
import std/selectors
import std/streams
import std/strutils
import std/tables

import config/chapath
import io/posixstream
import io/promise
import io/serialize
import io/serversocket
import io/socketstream
import io/tempfile
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
import types/referrer
import types/urimethodmap
import types/url
import utils/twtstr

export request
export response

type
  FileLoader* = ref object
    key*: ClientKey
    process*: int
    clientPid*: int
    connecting*: Table[int, ConnectData]
    ongoing*: Table[int, OngoingData]
    unregistered*: seq[int]
    registerFun*: proc(fd: int)
    unregisterFun*: proc(fd: int)

  ConnectData = object
    promise: Promise[JSResult[Response]]
    stream*: SocketStream
    request: Request

  OngoingData* = object
    buf: string
    response*: Response
    bodyRead: Promise[string]

  LoaderCommand = enum
    lcAddCacheFile
    lcAddClient
    lcLoad
    lcPassFd
    lcRemoveCachedItem
    lcRemoveClient
    lcResume
    lcShareCachedItem
    lcSuspend
    lcTee

  ClientKey* = array[32, uint8]

  CachedItemObj = object
    id: int
    path: string
    refc: int

  CachedItem = ref CachedItemObj

  ClientData = ref object
    pid: int
    key: ClientKey
    cacheMap: seq[CachedItem]
    config: LoaderClientConfig

  LoaderContext = ref object
    pagerClient: ClientData
    ssock: ServerSocket
    alive: bool
    config: LoaderConfig
    libexecPath: string
    handleMap: Table[int, LoaderHandle]
    outputMap: Table[int, OutputHandle]
    selector: Selector[int]
    # List of file descriptors passed by the pager.
    passedFdMap: Table[string, FileHandle] # host -> fd
    # List of existing clients (buffer or pager) that may make requests.
    clientData: Table[int, ClientData] # pid -> data
    # ID of next output. TODO: find a better allocation scheme
    outputNum: int

  LoaderConfig* = object
    cgiDir*: seq[string]
    uriMethodMap*: URIMethodMap
    w3mCGICompat*: bool
    tmpdir*: string

  LoaderClientConfig* = object
    cookieJar*: CookieJar
    defaultHeaders*: Headers
    filter*: URLFilter
    proxy*: URL
    # When set to false, requests with a proxy URL are overridden by the
    # loader proxy (i.e. the variable above).
    acceptProxy*: bool
    referrerPolicy*: ReferrerPolicy

  FetchPromise* = Promise[JSResult[Response]]

#TODO this may be too low if we want to use urimethodmap for everything
const MaxRewrites = 4

func canRewriteForCGICompat(ctx: LoaderContext; path: string): bool =
  if path.startsWith("/cgi-bin/") or path.startsWith("/$LIB/"):
    return true
  for dir in ctx.config.cgiDir:
    if path.startsWith(dir):
      return true
  return false

proc rejectHandle(handle: LoaderHandle; code: ConnectErrorCode; msg = "") =
  handle.sendResult(code, msg)
  handle.close()

func findOutput(ctx: LoaderContext; id: int): OutputHandle =
  assert id != -1
  for it in ctx.outputMap.values:
    if it.outputId == id:
      return it
  return nil

func findCachedHandle(ctx: LoaderContext; cacheId: int): LoaderHandle =
  assert cacheId != -1
  for it in ctx.handleMap.values:
    if it.cacheId == cacheId:
      return it
  return nil

type PushBufferResult = enum
  pbrDone, pbrUnregister

# Either write data to the target output, or append it to the list of buffers to
# write and register the output in our selector.
proc pushBuffer(ctx: LoaderContext; output: OutputHandle; buffer: LoaderBuffer;
    si: int): PushBufferResult =
  if output.suspended:
    if output.currentBuffer == nil:
      output.currentBuffer = buffer
      output.currentBufferIdx = si
    else:
      # si must be 0 here in all cases. Why? Well, it indicates the first unread
      # position after reading headers, and at that point currentBuffer will
      # be empty.
      #
      # Obviously, this breaks down if anything is pushed into the stream
      # before the header parser destroys itself. For now it never does, so we
      # should be fine.
      doAssert si == 0
      output.buffers.addLast(buffer)
  elif output.currentBuffer == nil:
    var n = si
    try:
      n += output.ostream.sendData(buffer, si)
    except ErrorAgain:
      discard
    except ErrorBrokenPipe:
      return pbrUnregister
    if n < buffer.len:
      output.currentBuffer = buffer
      output.currentBufferIdx = n
      ctx.selector.registerHandle(output.ostream.fd, {Write}, 0)
      output.registered = true
  else:
    output.buffers.addLast(buffer)
  pbrDone

proc getOutputId(ctx: LoaderContext): int =
  result = ctx.outputNum
  inc ctx.outputNum

type AddCacheFileResult = tuple[outputId: int; cacheFile: string]

proc addCacheFile(ctx: LoaderContext; client: ClientData; output: OutputHandle):
    AddCacheFileResult =
  if output.parent != nil and output.parent.cacheId != -1:
    # may happen e.g. if client tries to cache a `cache:' URL
    return (output.parent.cacheId, "") #TODO can we get the file name somehow?
  let tmpf = getTempFile(ctx.config.tmpdir)
  let ps = newPosixStream(tmpf, O_CREAT or O_WRONLY, 0o600)
  if unlikely(ps == nil):
    return (-1, "")
  if output.currentBuffer != nil:
    let n = ps.sendData(output.currentBuffer, output.currentBufferIdx)
    if unlikely(n < output.currentBuffer.len - output.currentBufferIdx):
      ps.close()
      return (-1, "")
  for buffer in output.buffers:
    let n = ps.sendData(buffer)
    if unlikely(n < buffer.len):
      ps.close()
      return (-1, "")
  let cacheId = output.outputId
  if output.parent != nil:
    output.parent.cacheId = cacheId
    output.parent.outputs.add(OutputHandle(
      parent: output.parent,
      ostream: ps,
      istreamAtEnd: output.istreamAtEnd,
      outputId: ctx.getOutputId()
    ))
  client.cacheMap.add(CachedItem(id: cacheId, path: tmpf, refc: 1))
  return (cacheId, tmpf)

proc addFd(ctx: LoaderContext; handle: LoaderHandle) =
  let output = handle.output
  output.ostream.setBlocking(false)
  handle.istream.setBlocking(false)
  ctx.selector.registerHandle(handle.istream.fd, {Read}, 0)
  assert handle.istream.fd notin ctx.handleMap
  assert output.ostream.fd notin ctx.outputMap
  ctx.handleMap[handle.istream.fd] = handle
  ctx.outputMap[output.ostream.fd] = output

type HandleReadResult = enum
  hrrDone, hrrUnregister

# Called whenever there is more data available to read.
proc handleRead(ctx: LoaderContext; handle: LoaderHandle;
    unregWrite: var seq[OutputHandle]): HandleReadResult =
  var unregs = 0
  let maxUnregs = handle.outputs.len
  while true:
    let buffer = newLoaderBuffer()
    try:
      let n = handle.istream.recvData(buffer)
      if n == 0: # EOF
        return hrrUnregister
      var si = 0
      if handle.parser != nil:
        si = handle.parseHeaders(buffer)
        if si == -1: # died while parsing headers; unregister
          return hrrUnregister
        if si == n: # parsed the entire buffer as headers; skip output handling
          continue
      for output in handle.outputs:
        if output.dead:
          # do not push to unregWrite candidates
          continue
        case ctx.pushBuffer(output, buffer, si)
        of pbrUnregister:
          output.dead = true
          unregWrite.add(output)
          inc unregs
        of pbrDone: discard
      if unregs == maxUnregs:
        # early return: no more outputs to write to
        break
      if n < buffer.cap:
        break
    except ErrorAgain: # retry later
      break
    except ErrorBrokenPipe: # sender died; stop streaming
      return hrrUnregister
  hrrDone

# stream is a regular file, so we can't select on it.
# cachedHandle is used for attaching the output handle to a different
# LoaderHandle when loadFromCache is called while a download is still ongoing
# (and thus some parts of the document are not cached yet).
proc loadStreamRegular(ctx: LoaderContext; handle, cachedHandle: LoaderHandle) =
  assert handle.parser == nil # parser is only used with CGI
  var unregWrite: seq[OutputHandle] = @[]
  let r = ctx.handleRead(handle, unregWrite)
  for output in unregWrite:
    output.parent = nil
    let i = handle.outputs.find(output)
    if output.registered:
      ctx.selector.unregister(output.ostream.fd)
      output.registered = false
    handle.outputs.del(i)
  for output in handle.outputs:
    if r == hrrUnregister:
      output.ostream.close()
      output.ostream = nil
    elif cachedHandle != nil:
      output.parent = cachedHandle
      cachedHandle.outputs.add(output)
      ctx.outputMap[output.ostream.fd] = output
    elif output.registered or output.suspended:
      output.parent = nil
      output.istreamAtEnd = true
      ctx.outputMap[output.ostream.fd] = output
    else:
      assert output.ostream.fd notin ctx.outputMap
      output.ostream.close()
      output.ostream = nil
  handle.outputs.setLen(0)
  handle.istream.close()
  handle.istream = nil

proc loadStream(ctx: LoaderContext; client: ClientData; handle: LoaderHandle;
    request: Request) =
  ctx.passedFdMap.withValue(request.url.pathname, fdp):
    handle.sendResult(0)
    handle.sendStatus(200)
    handle.sendHeaders(newHeaders())
    let ps = newPosixStream(fdp[])
    var stats: Stat
    doAssert fstat(fdp[], stats) != -1
    handle.istream = ps
    ctx.passedFdMap.del(request.url.pathname)
    if S_ISCHR(stats.st_mode) or S_ISREG(stats.st_mode):
      # regular file: e.g. cha <file
      # or character device: e.g. cha </dev/null
      handle.output.ostream.setBlocking(false)
      # not loading from cache, so cachedHandle is nil
      ctx.loadStreamRegular(handle, nil)
  do:
    handle.sendResult(ERROR_FILE_NOT_FOUND, "stream not found")

func find(cacheMap: seq[CachedItem]; id: int): int =
  for i, it in cacheMap:
    if it.id == id:
      return i
  -1

proc loadFromCache(ctx: LoaderContext; client: ClientData; handle: LoaderHandle;
    request: Request) =
  var id = -1
  var startFrom = 0
  try:
    id = parseInt(request.url.pathname)
    if request.url.query.isSome:
      startFrom = parseInt(request.url.query.get)
  except ValueError:
    discard
  let n = client.cacheMap.find(id)
  if n != -1:
    let ps = newPosixStream(client.cacheMap[n].path, O_RDONLY, 0)
    if startFrom != 0:
      ps.seek(startFrom)
    if ps == nil:
      handle.rejectHandle(ERROR_FILE_NOT_IN_CACHE)
      client.cacheMap.del(n)
      return
    handle.sendResult(0)
    handle.sendStatus(200)
    handle.sendHeaders(newHeaders())
    handle.istream = ps
    handle.output.ostream.setBlocking(false)
    let cachedHandle = ctx.findCachedHandle(id)
    ctx.loadStreamRegular(handle, cachedHandle)
  else:
    handle.sendResult(ERROR_URL_NOT_IN_CACHE)

proc loadResource(ctx: LoaderContext; client: ClientData; request: Request;
    handle: LoaderHandle) =
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
      handle.loadCGI(request, ctx.config.cgiDir, ctx.libexecPath, prevurl)
      if handle.istream != nil:
        ctx.addFd(handle)
      else:
        handle.close()
    elif request.url.scheme == "stream":
      ctx.loadStream(client, handle, request)
      if handle.istream != nil:
        ctx.addFd(handle)
      else:
        handle.close()
    elif request.url.scheme == "cache":
      ctx.loadFromCache(client, handle, request)
      assert handle.istream == nil
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

proc onLoad(ctx: LoaderContext; stream: SocketStream; client: ClientData) =
  var request: Request
  stream.sread(request)
  let handle = newLoaderHandle(stream, ctx.getOutputId(), client.pid,
    request.suspended)
  when defined(debug):
    handle.url = request.url
    handle.output.url = request.url
  if not client.config.filter.match(request.url):
    handle.rejectHandle(ERROR_DISALLOWED_URL)
  else:
    for k, v in client.config.defaultHeaders.table:
      if k notin request.headers.table:
        request.headers.table[k] = v
    let cookieJar = client.config.cookieJar
    if cookieJar != nil and cookieJar.cookies.len > 0:
      if "Cookie" notin request.headers.table:
        let cookie = cookieJar.serialize(request.url)
        if cookie != "":
          request.headers["Cookie"] = cookie
    if request.referrer != nil and "Referer" notin request.headers:
      let r = request.referrer.getReferrer(request.url,
        client.config.referrerPolicy)
      if r != "":
        request.headers["Referer"] = r
    if request.proxy == nil or not client.config.acceptProxy:
      request.proxy = client.config.proxy
    ctx.loadResource(client, request, handle)

proc addClient(ctx: LoaderContext; stream: SocketStream) =
  var key: ClientKey
  var pid: int
  var config: LoaderClientConfig
  stream.sread(key)
  stream.sread(pid)
  stream.sread(config)
  if pid in ctx.clientData or key == default(ClientKey):
    stream.swrite(false)
  else:
    ctx.clientData[pid] = ClientData(pid: pid, key: key, config: config)
    stream.swrite(true)
  stream.close()

proc cleanup(client: ClientData) =
  for it in client.cacheMap:
    dec it.refc
    if it.refc == 0:
      discard unlink(cstring(it.path))

proc removeClient(ctx: LoaderContext; stream: SocketStream) =
  var pid: int
  stream.sread(pid)
  if pid in ctx.clientData:
    let client = ctx.clientData[pid]
    client.cleanup()
    ctx.clientData.del(pid)
  stream.close()

proc addCacheFile(ctx: LoaderContext; stream: SocketStream) =
  var outputId: int
  var targetPid: int
  stream.sread(outputId)
  stream.sread(targetPid)
  let output = ctx.findOutput(outputId)
  assert output != nil
  let targetClient = ctx.clientData[targetPid]
  let (id, file) = ctx.addCacheFile(targetClient, output)
  stream.swrite(id)
  stream.swrite(file)
  stream.close()

proc shareCachedItem(ctx: LoaderContext; stream: SocketStream) =
  # share a cached file with another buffer. this is for newBufferFrom
  # (i.e. view source)
  var sourcePid: int # pid of source client
  var targetPid: int # pid of target client
  var id: int
  stream.sread(sourcePid)
  stream.sread(targetPid)
  stream.sread(id)
  let sourceClient = ctx.clientData[sourcePid]
  let targetClient = ctx.clientData[targetPid]
  let n = sourceClient.cacheMap.find(id)
  let item = sourceClient.cacheMap[n]
  inc item.refc
  targetClient.cacheMap.add(item)
  stream.close()

proc passFd(ctx: LoaderContext; stream: SocketStream) =
  var id: string
  stream.sread(id)
  let fd = stream.recvFileHandle()
  ctx.passedFdMap[id] = fd
  stream.close()

proc removeCachedItem(ctx: LoaderContext; stream: SocketStream;
    client: ClientData) =
  var id: int
  stream.sread(id)
  let n = client.cacheMap.find(id)
  if n != -1:
    let item = client.cacheMap[n]
    client.cacheMap.del(n)
    dec item.refc
    if item.refc == 0:
      discard unlink(cstring(item.path))
  stream.close()

proc tee(ctx: LoaderContext; stream: SocketStream; client: ClientData) =
  var sourceId: int
  var targetPid: int
  stream.sread(sourceId)
  stream.sread(targetPid)
  let output = ctx.findOutput(sourceId)
  # only allow tee'ing outputs owned by client
  doAssert output.ownerPid == client.pid
  if output != nil:
    let id = ctx.getOutputId()
    output.tee(stream, id, targetPid)
    stream.swrite(id)
    stream.setBlocking(false)
  else:
    stream.swrite(-1)
    stream.close()

proc suspend(ctx: LoaderContext; stream: SocketStream; client: ClientData) =
  var ids: seq[int]
  stream.sread(ids)
  for id in ids:
    let output = ctx.findOutput(id)
    if output != nil:
      output.suspended = true
      if output.registered:
        # do not waste cycles trying to push into output
        output.registered = false
        ctx.selector.unregister(output.ostream.fd)

proc resume(ctx: LoaderContext; stream: SocketStream; client: ClientData) =
  var ids: seq[int]
  stream.sread(ids)
  for id in ids:
    let output = ctx.findOutput(id)
    if output != nil:
      output.suspended = false
      assert not output.registered
      output.registered = true
      ctx.selector.registerHandle(output.ostream.fd, {Write}, 0)

proc acceptConnection(ctx: LoaderContext) =
  let stream = ctx.ssock.acceptSocketStream()
  try:
    var myPid: int
    var key: ClientKey
    stream.sread(myPid)
    stream.sread(key)
    if myPid notin ctx.clientData:
      # possibly already removed
      stream.close()
      return
    let client = ctx.clientData[myPid]
    if client.key != key:
      # ditto
      stream.close()
      return
    var cmd: LoaderCommand
    stream.sread(cmd)
    template privileged_command =
      doAssert client == ctx.pagerClient
    case cmd
    of lcAddClient:
      privileged_command
      ctx.addClient(stream)
    of lcRemoveClient:
      privileged_command
      ctx.removeClient(stream)
    of lcAddCacheFile:
      privileged_command
      ctx.addCacheFile(stream)
    of lcShareCachedItem:
      privileged_command
      ctx.shareCachedItem(stream)
    of lcPassFd:
      privileged_command
      ctx.passFd(stream)
    of lcRemoveCachedItem:
      ctx.removeCachedItem(stream, client)
    of lcLoad:
      ctx.onLoad(stream, client)
    of lcTee:
      ctx.tee(stream, client)
    of lcSuspend:
      ctx.suspend(stream, client)
    of lcResume:
      ctx.resume(stream, client)
  except ErrorBrokenPipe:
    # receiving end died while reading the file; give up.
    stream.close()

proc exitLoader(ctx: LoaderContext) =
  ctx.ssock.close()
  for client in ctx.clientData.values:
    client.cleanup()
  exitnow(1)

var gctx: LoaderContext
proc initLoaderContext(fd: cint; config: LoaderConfig): LoaderContext =
  var ctx = LoaderContext(
    alive: true,
    config: config,
    selector: newSelector[int](),
    libexecPath: ChaPath("${%CHA_LIBEXEC_DIR}").unquote().get
  )
  gctx = ctx
  #TODO ideally, buffered would be true. Unfortunately this conflicts with
  # sendFileHandle/recvFileHandle.
  let myPid = getCurrentProcessId()
  ctx.ssock = initServerSocket(myPid, buffered = false, blocking = true)
  let sfd = int(ctx.ssock.sock.getFd())
  ctx.selector.registerHandle(sfd, {Read}, 0)
  # The server has been initialized, so the main process can resume execution.
  let ps = newPosixStream(fd)
  ps.write(char(0u8))
  ps.close()
  onSignal SIGTERM:
    discard sig
    gctx.exitLoader()
  for dir in ctx.config.cgiDir.mitems:
    if dir.len > 0 and dir[^1] != '/':
      dir &= '/'
  # get pager's key
  let stream = ctx.ssock.acceptSocketStream()
  block readNullKey:
    var pid: int # ignore pid
    stream.sread(pid)
    # pager's key is still null
    var key: ClientKey
    stream.sread(key)
    doAssert key == default(ClientKey)
  var cmd: LoaderCommand
  stream.sread(cmd)
  doAssert cmd == lcAddClient
  var key: ClientKey
  var pid: int
  var config: LoaderClientConfig
  stream.sread(key)
  stream.sread(pid)
  stream.sread(config)
  stream.swrite(true)
  ctx.pagerClient = ClientData(key: key, pid: pid, config: config)
  ctx.clientData[pid] = ctx.pagerClient
  stream.close()
  # unblock main socket
  ctx.ssock.sock.getFd().setBlocking(false)
  return ctx

# This is only called when an OutputHandle could not read enough of one (or
# more) buffers, and we asked select to notify us when it will be available.
proc handleWrite(ctx: LoaderContext; output: OutputHandle;
    unregWrite: var seq[OutputHandle]) =
  while output.currentBuffer != nil:
    let buffer = output.currentBuffer
    try:
      let n = output.ostream.sendData(buffer, output.currentBufferIdx)
      output.currentBufferIdx += n
      if output.currentBufferIdx < buffer.len:
        break
      output.bufferCleared() # swap out buffer
    except ErrorAgain: # never mind
      break
    except ErrorBrokenPipe: # receiver died; stop streaming
      unregWrite.add(output)
      break
  if output.isEmpty:
    if output.istreamAtEnd:
      # after EOF, no need to send anything more here
      unregWrite.add(output)
    else:
      # all buffers sent, no need to select on this output again for now
      output.registered = false
      ctx.selector.unregister(output.ostream.fd)

proc finishCycle(ctx: LoaderContext; unregRead: var seq[LoaderHandle];
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
      if handle.parser != nil:
        handle.finishParse()
      for output in handle.outputs:
        output.istreamAtEnd = true
        if output.isEmpty:
          unregWrite.add(output)
  for output in unregWrite:
    if output.ostream != nil:
      if output.registered:
        ctx.selector.unregister(output.ostream.fd)
      ctx.outputMap.del(output.ostream.fd)
      output.ostream.close()
      output.ostream = nil
      let handle = output.parent
      if handle != nil: # may be nil if from loadStream S_ISREG
        let i = handle.outputs.find(output)
        handle.outputs.del(i)
        if handle.outputs.len == 0 and handle.istream != nil:
          # premature end of all output streams; kill istream too
          ctx.selector.unregister(handle.istream.fd)
          ctx.handleMap.del(handle.istream.fd)
          handle.istream.close()
          handle.istream = nil
          if handle.parser != nil:
            handle.finishParse()

proc runFileLoader*(fd: cint; config: LoaderConfig) =
  var ctx = initLoaderContext(fd, config)
  let fd = int(ctx.ssock.sock.getFd())
  while ctx.alive:
    let events = ctx.selector.select(-1)
    var unregRead: seq[LoaderHandle] = @[]
    var unregWrite: seq[OutputHandle] = @[]
    for event in events:
      if Read in event.events:
        if event.fd == fd: # incoming connection
          ctx.acceptConnection()
        else:
          let handle = ctx.handleMap[event.fd]
          case ctx.handleRead(handle, unregWrite)
          of hrrDone: discard
          of hrrUnregister: unregRead.add(handle)
      if Write in event.events:
        ctx.handleWrite(ctx.outputMap[event.fd], unregWrite)
      if Error in event.events:
        assert event.fd != fd
        ctx.outputMap.withValue(event.fd, outputp): # ostream died
          unregWrite.add(outputp[])
        do: # istream died
          let handle = ctx.handleMap[event.fd]
          unregRead.add(handle)
    ctx.finishCycle(unregRead, unregWrite)
  ctx.exitLoader()

proc getRedirect*(response: Response; request: Request): Request =
  if "Location" in response.headers.table:
    if response.status in 301u16..303u16 or response.status in 307u16..308u16:
      let location = response.headers.table["Location"][0]
      let url = parseURL(location, option(request.url))
      if url.isSome:
        if (response.status == 303 and
            request.httpMethod notin {HTTP_GET, HTTP_HEAD}) or
            (response.status == 301 or response.status == 302 and
            request.httpMethod == HTTP_POST):
          return newRequest(url.get, HTTP_GET,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)
        else:
          return newRequest(url.get, request.httpMethod,
            body = request.body, multipart = request.multipart,
            mode = request.mode, credentialsMode = request.credentialsMode,
            destination = request.destination)
  return nil

proc connect(loader: FileLoader; buffered = true): SocketStream =
  let stream = connectSocketStream(loader.process, buffered, blocking = true)
  if stream != nil:
    stream.swrite(loader.clientPid)
    stream.swrite(loader.key)
    return stream
  return nil

# Start a request. This should not block (not for a significant amount of time
# anyway).
proc startRequest*(loader: FileLoader; request: Request): SocketStream =
  let stream = loader.connect(buffered = false)
  stream.swrite(lcLoad)
  stream.swrite(request)
  stream.flush()
  return stream

#TODO: add init
proc fetch*(loader: FileLoader; input: Request): FetchPromise =
  let stream = loader.startRequest(input)
  let fd = int(stream.fd)
  loader.registerFun(fd)
  let promise = FetchPromise()
  loader.connecting[fd] = ConnectData(
    promise: promise,
    request: input,
    stream: stream
  )
  return promise

proc reconnect*(loader: FileLoader; data: ConnectData) =
  data.stream.close()
  let stream = loader.connect(buffered = false)
  stream.swrite(lcLoad)
  stream.swrite(data.request)
  stream.flush()
  let fd = int(stream.fd)
  loader.registerFun(fd)
  loader.connecting[fd] = ConnectData(
    promise: data.promise,
    request: data.request,
    stream: stream
  )

proc switchStream*(data: var ConnectData; stream: SocketStream) =
  data.stream = stream

proc switchStream*(loader: FileLoader; data: var OngoingData;
    stream: SocketStream) =
  data.response.body = stream
  let fd = int(stream.fd)
  let realCloseImpl = stream.closeImpl
  stream.closeImpl = nil
  data.response.unregisterFun = proc() =
    loader.ongoing.del(fd)
    loader.unregistered.add(fd)
    loader.unregisterFun(fd)
    realCloseImpl(stream)

proc suspend*(loader: FileLoader; fds: seq[int]) =
  let stream = loader.connect()
  stream.swrite(lcSuspend)
  stream.swrite(fds)
  stream.close()

proc resume*(loader: FileLoader; fds: seq[int]) =
  let stream = loader.connect()
  stream.swrite(lcResume)
  stream.swrite(fds)
  stream.close()

proc tee*(loader: FileLoader; sourceId, targetPid: int): (SocketStream, int) =
  let stream = loader.connect(buffered = false)
  stream.swrite(lcTee)
  stream.swrite(sourceId)
  stream.swrite(targetPid)
  var outputId: int
  stream.sread(outputId)
  return (stream, outputId)

proc addCacheFile*(loader: FileLoader; outputId, targetPid: int):
    AddCacheFileResult =
  let stream = loader.connect()
  if stream == nil:
    return (-1, "")
  stream.swrite(lcAddCacheFile)
  stream.swrite(outputId)
  stream.swrite(targetPid)
  stream.flush()
  var outputId: int
  var cacheFile: string
  stream.sread(outputId)
  stream.sread(cacheFile)
  return (outputId, cacheFile)

const BufferSize = 4096

proc handleHeaders(response: Response; request: Request; stream: SocketStream) =
  stream.sread(response.outputId)
  stream.sread(response.status)
  stream.sread(response.headers)

proc onConnected*(loader: FileLoader, fd: int) =
  let connectData = loader.connecting[fd]
  let stream = connectData.stream
  let promise = connectData.promise
  let request = connectData.request
  var res: int
  stream.sread(res)
  let response = newResponse(res, request, stream)
  if res == 0:
    response.handleHeaders(request, stream)
    # Only a stream of the response body may arrive after this point.
    response.body = stream
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
    stream.setBlocking(false)
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

proc onRead*(loader: FileLoader; fd: int) =
  loader.ongoing.withValue(fd, buffer):
    let response = buffer[].response
    while not response.body.atEnd():
      let olen = buffer[].buf.len
      try:
        buffer[].buf.setLen(olen + BufferSize)
        let n = response.body.recvData(addr buffer[].buf[olen], BufferSize)
        buffer[].buf.setLen(olen + n)
        if n == 0:
          break
      except ErrorAgain:
        buffer[].buf.setLen(olen)
        break
    if response.body.atEnd():
      buffer[].bodyRead.resolve(buffer[].buf)
      buffer[].bodyRead = nil
      buffer[].buf = ""
      response.unregisterFun()

proc onError*(loader: FileLoader; fd: int) =
  loader.ongoing.withValue(fd, buffer):
    let response = buffer[].response
    when defined(debug):
      var lbuf {.noinit.}: array[BufferSize, char]
      if not response.body.atEnd():
        let n = response.body.recvData(addr lbuf[0], lbuf.len)
        assert n == 0
      assert response.body.atEnd()
    buffer[].bodyRead.resolve(buffer[].buf)
    buffer[].bodyRead = nil
    buffer[].buf = ""
    response.unregisterFun()

# Note: this blocks until headers are received.
proc doRequest*(loader: FileLoader; request: Request): Response =
  let stream = loader.startRequest(request)
  let response = Response(url: request.url)
  stream.sread(response.res)
  if response.res == 0:
    response.handleHeaders(request, stream)
    # Only a stream of the response body may arrive after this point.
    response.body = stream
  else:
    var msg: string
    stream.sread(msg)
    stream.close()
  return response

proc shareCachedItem*(loader: FileLoader; id, targetPid: int) =
  let stream = loader.connect()
  if stream != nil:
    stream.swrite(lcShareCachedItem)
    stream.swrite(loader.clientPid)
    stream.swrite(targetPid)
    stream.swrite(id)
    stream.close()

proc passFd*(loader: FileLoader; id: string; fd: FileHandle) =
  let stream = loader.connect(buffered = false)
  if stream != nil:
    stream.swrite(lcPassFd)
    stream.swrite(id)
    stream.sendFileHandle(fd)
    stream.close()

proc removeCachedItem*(loader: FileLoader; outputId: int) =
  let stream = loader.connect()
  if stream != nil:
    stream.swrite(lcRemoveCachedItem)
    stream.swrite(outputId)
    stream.close()

proc addClient*(loader: FileLoader; key: ClientKey; pid: int;
    config: LoaderClientConfig): bool =
  let stream = loader.connect()
  stream.swrite(lcAddClient)
  stream.swrite(key)
  stream.swrite(pid)
  stream.swrite(config)
  stream.flush()
  stream.sread(result)
  stream.close()

proc removeClient*(loader: FileLoader; pid: int) =
  let stream = loader.connect()
  if stream != nil:
    stream.swrite(lcRemoveClient)
    stream.swrite(pid)
    stream.close()
