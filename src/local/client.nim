import std/nativesockets
import std/net
import std/options
import std/os
import std/selectors
import std/streams
import std/strutils
import std/tables
import std/unicode

when defined(posix):
  import std/posix

import std/exitprocs

import bindings/constcharp
import bindings/quickjs
import config/config
import display/lineedit
import display/term
import display/winattrs
import html/chadombuilder
import html/dom
import html/event
import io/posixstream
import io/promise
import io/socketstream
import js/base64
import js/console
import js/domexception
import js/encoding
import js/error
import js/fromjs
import js/intl
import js/javascript
import js/jstypes
import js/module
import js/timeout
import js/tojs
import loader/headers
import loader/loader
import loader/request
import local/container
import local/pager
import server/forkserver
import types/blob
import types/cookie
import types/opt
import types/url
import utils/twtstr
import xhr/formdata
import xhr/xmlhttprequest

import chakasu/charset

type
  Client* = ref object
    alive: bool
    config {.jsget.}: Config
    consoleWrapper: ConsoleWrapper
    fdmap: Table[int, Container]
    feednext: bool
    forkserver: ForkServer
    ibuf: string
    jsctx: JSContext
    jsrt: JSRuntime
    loader: FileLoader
    pager {.jsget.}: Pager
    selector: Selector[int]
    timeouts: TimeoutState

  ConsoleWrapper = object
    console: Console
    container: Container
    prev: Container

jsDestructor(Client)

func console(client: Client): Console {.jsfget.} =
  return client.consoleWrapper.console

proc readChar(client: Client): char =
  if client.ibuf == "":
    try:
      return client.pager.infile.readChar()
    except EOFError:
      quit(1)
  else:
    result = client.ibuf[0]
    client.ibuf.delete(0..0)

proc finalize(client: Client) {.jsfin.} =
  if client.jsctx != nil:
    free(client.jsctx)
  if client.jsrt != nil:
    free(client.jsrt)

proc doRequest(client: Client, req: Request): Response {.jsfunc.} =
  return client.loader.doRequest(req)

proc fetch[T: Request|string](client: Client, req: T,
    init = none(RequestInit)): JSResult[FetchPromise] {.jsfunc.} =
  let req = ?newRequest(client.jsctx, req, init)
  return ok(client.loader.fetch(req))

proc interruptHandler(rt: JSRuntime, opaque: pointer): cint {.cdecl.} =
  let client = cast[Client](opaque)
  if client.console == nil or client.pager.infile == nil: return
  try:
    let c = client.pager.infile.readChar()
    if c == char(3): #C-c
      client.ibuf = ""
      return 1
    else:
      client.ibuf &= c
  except IOError:
    discard
  return 0

proc runJSJobs(client: Client) =
  client.jsrt.runJSJobs(client.console.err)

proc evalJS(client: Client, src, filename: string, module = false): JSValue =
  client.pager.term.unblockStdin()
  let flags = if module:
    JS_EVAL_TYPE_MODULE
  else:
    JS_EVAL_TYPE_GLOBAL
  result = client.jsctx.eval(src, filename, flags)
  client.runJSJobs()
  client.pager.term.restoreStdin()

proc evalJSFree(client: Client, src, filename: string) =
  JS_FreeValue(client.jsctx, client.evalJS(src, filename))

proc command0(client: Client, src: string, filename = "<command>",
    silence = false, module = false) =
  let ret = client.evalJS(src, filename, module = module)
  if JS_IsException(ret):
    client.jsctx.writeException(client.console.err)
  else:
    if not silence:
      let str = fromJS[string](client.jsctx, ret)
      if str.isSome:
        client.console.log(str.get)
  JS_FreeValue(client.jsctx, ret)

proc command(client: Client, src: string) =
  client.command0(src)
  let container = client.consoleWrapper.container
  container.requestLines().then(proc() =
    container.cursorLastLine())

proc suspend(client: Client) {.jsfunc.} =
  client.pager.term.quit()
  discard kill(0, cint(SIGTSTP))
  client.pager.term.restart()

proc quit(client: Client, code = 0) {.jsfunc.} =
  if client.alive:
    client.alive = false
    client.pager.quit()
    let ctx = client.jsctx
    var global = JS_GetGlobalObject(ctx)
    JS_FreeValue(ctx, global)
    if client.jsctx != nil:
      free(client.jsctx)
    #TODO
    #if client.jsrt != nil:
    #  free(client.jsrt)
  quit(code)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

proc alert(client: Client, msg: string) {.jsfunc.} =
  client.pager.alert(msg)

proc handlePagerEvents(client: Client) =
  let container = client.pager.container
  if container != nil:
    client.pager.handleEvents(container)

proc evalAction(client: Client, action: string, arg0: int32): EmptyPromise =
  var ret = client.evalJS(action, "<command>")
  let ctx = client.jsctx
  var p = EmptyPromise()
  p.resolve()
  if JS_IsFunction(ctx, ret):
    if arg0 != 0:
      var arg0 = toJS(ctx, arg0)
      let ret2 = JS_Call(ctx, ret, JS_UNDEFINED, 1, addr arg0)
      JS_FreeValue(ctx, arg0)
      JS_FreeValue(ctx, ret)
      ret = ret2
      JS_FreeValue(ctx, arg0)
    else: # no precnum
      let ret2 = JS_Call(ctx, ret, JS_UNDEFINED, 0, nil)
      JS_FreeValue(ctx, ret)
      ret = ret2
  if JS_IsException(ret):
    client.jsctx.writeException(client.console.err)
  if JS_IsObject(ret):
    let maybep = fromJS[EmptyPromise](ctx, ret)
    if maybep.isOk:
      p = maybep.get
  JS_FreeValue(ctx, ret)
  return p

# The maximum number we are willing to accept.
# This should be fine for 32-bit signed ints (which precnum currently is).
# We can always increase it further (e.g. by switching to uint32, uint64...) if
# it proves to be too low.
const MaxPrecNum = 100000000

proc handleCommandInput(client: Client, c: char): EmptyPromise =
  if client.config.input.vi_numeric_prefix and not client.pager.notnum:
    if client.pager.precnum != 0 and c == '0' or c in '1' .. '9':
      if client.pager.precnum < MaxPrecNum: # better ignore than eval...
        client.pager.precnum *= 10
        client.pager.precnum += cast[int32](decValue(c))
      return
    else:
      client.pager.notnum = true
  client.pager.inputBuffer &= c
  let action = getNormalAction(client.config, client.pager.inputBuffer)
  let p = client.evalAction(action, client.pager.precnum)
  if not client.feednext:
    client.pager.precnum = 0
    client.pager.notnum = false
    client.handlePagerEvents()
  return p

proc input(client: Client): EmptyPromise =
  var p: EmptyPromise = nil
  client.pager.term.restoreStdin()
  var buf: string
  while true:
    let c = client.readChar()
    if client.pager.askpromise != nil:
      if c == 'y':
        client.pager.fulfillAsk(true)
      elif c == 'n':
        client.pager.fulfillAsk(false)
    elif client.pager.askcharpromise != nil:
      buf &= c
      if buf.validateUtf8() != -1:
        continue
      client.pager.fulfillCharAsk(buf)
    elif client.pager.lineedit.isSome:
      client.pager.inputBuffer &= c
      let edit = client.pager.lineedit.get
      if edit.escNext:
        edit.escNext = false
        if edit.write(client.pager.inputBuffer, client.pager.term.cs):
          client.pager.inputBuffer = ""
      else:
        let action = getLinedAction(client.config, client.pager.inputBuffer)
        if action == "":
          if edit.write(client.pager.inputBuffer, client.pager.term.cs):
            client.pager.inputBuffer = ""
          else:
            client.feednext = true
        elif not client.feednext:
          discard client.evalAction(action, 0)
        if not client.feednext:
          client.pager.updateReadLine()
    else:
      p = client.handleCommandInput(c)
      if not client.feednext:
        client.pager.inputBuffer = ""
        client.pager.refreshStatusMsg()
        break
      client.pager.refreshStatusMsg()
      client.pager.draw()
    if not client.feednext:
      client.pager.inputBuffer = ""
      break
    else:
      client.feednext = false
  client.pager.inputBuffer = ""
  if p == nil:
    p = EmptyPromise()
    p.resolve()
  return p

proc setTimeout[T: JSValue|string](client: Client, handler: T,
    timeout = 0i32): int32 {.jsfunc.} =
  return client.timeouts.setTimeout(handler, timeout)

proc setInterval[T: JSValue|string](client: Client, handler: T,
    interval = 0i32): int32 {.jsfunc.} =
  return client.timeouts.setInterval(handler, interval)

proc clearTimeout(client: Client, id: int32) {.jsfunc.} =
  client.timeouts.clearTimeout(id)

proc clearInterval(client: Client, id: int32) {.jsfunc.} =
  client.timeouts.clearInterval(id)

let SIGWINCH {.importc, header: "<signal.h>", nodecl.}: cint

proc showConsole(client: Client) {.jsfunc.} =
  let container = client.consoleWrapper.container
  if client.pager.container != container:
    client.consoleWrapper.prev = client.pager.container
    client.pager.setContainer(container)
    container.requestLines()

proc hideConsole(client: Client) {.jsfunc.} =
  if client.pager.container == client.consoleWrapper.container:
    client.pager.setContainer(client.consoleWrapper.prev)

proc consoleBuffer(client: Client): Container {.jsfget.} =
  return client.consoleWrapper.container

proc acceptBuffers(client: Client) =
  while client.pager.unreg.len > 0:
    let (pid, stream) = client.pager.unreg.pop()
    let fd = stream.source.getFd()
    if int(fd) in client.fdmap:
      client.selector.unregister(fd)
      client.fdmap.del(int(fd))
    else:
      client.pager.procmap.del(pid)
    stream.close()
  var accepted: seq[Pid]
  for pid, container in client.pager.procmap:
    let stream = connectSocketStream(pid, buffered = false, blocking = true)
    if stream == nil:
      client.pager.alert("Error: failed to set up buffer")
      continue
    container.setStream(stream)
    let fd = stream.source.getFd()
    client.fdmap[int(fd)] = container
    client.selector.registerHandle(fd, {Read}, 0)
    client.pager.handleEvents(container)
    accepted.add(pid)
  client.pager.procmap.clear()

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

proc handleRead(client: Client, fd: int) =
  if client.pager.infile != nil and fd == client.pager.infile.getFileHandle():
    client.input().then(proc() =
      client.handlePagerEvents()
    )
  elif fd == client.forkserver.estream.fd:
    var nl = false
    const prefix = "STDERR: "
    var s = prefix
    while true:
      try:
        let c = client.forkserver.estream.readChar()
        if nl and s.len > prefix.len:
          client.console.err.write(s)
          s = prefix
          nl = false
        s &= c
        nl = c == '\n'
      except IOError:
        break
    if s.len > prefix.len:
      client.console.err.write(s)
    client.console.err.flush()
  elif fd in client.loader.connecting:
    client.loader.onConnected(fd)
    client.runJSJobs()
  elif fd in client.loader.ongoing:
    client.loader.onRead(fd)
  elif fd in client.loader.unregistered:
    discard # ignore
  else:
    let container = client.fdmap[fd]
    client.pager.handleEvent(container)

proc flushConsole*(client: Client) {.jsfunc.} =
  if client.console == nil:
    # hack for when client crashes before console has been initialized
    client.consoleWrapper = ConsoleWrapper(
      console: newConsole(newFileStream(stderr))
    )
  client.handleRead(client.forkserver.estream.fd)

proc handleError(client: Client, fd: int) =
  if client.pager.infile != nil and fd == client.pager.infile.getFileHandle():
    #TODO do something here...
    stderr.write("Error in tty\n")
    quit(1)
  elif fd == client.forkserver.estream.fd:
    #TODO do something here...
    stderr.write("Fork server crashed :(\n")
    quit(1)
  elif fd in client.loader.connecting:
    #TODO handle error?
    discard
  elif fd in client.loader.ongoing:
    client.loader.onError(fd)
  elif fd in client.loader.unregistered:
    discard # already unregistered...
  else:
    if fd in client.fdmap:
      let container = client.fdmap[fd]
      if container != client.consoleWrapper.container:
        client.console.log("Error in buffer", $container.location)
      else:
        client.consoleWrapper.container = nil
      client.selector.unregister(fd)
      client.fdmap.del(fd)
    if client.consoleWrapper.container != nil:
      client.showConsole()
    else:
      doAssert false

proc inputLoop(client: Client) =
  let selector = client.selector
  discard c_setvbuf(client.pager.infile, nil, IONBF, 0)
  selector.registerHandle(int(client.pager.infile.getFileHandle()), {Read}, 0)
  let sigwinch = selector.registerSignal(int(SIGWINCH), 0)
  while true:
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        client.handleRead(event.fd)
      if Error in event.events:
        client.handleError(event.fd)
      if Signal in event.events:
        assert event.fd == sigwinch
        let attrs = getWindowAttributes(client.pager.infile)
        client.pager.windowChange(attrs)
      if selectors.Event.Timer in event.events:
        let r = client.timeouts.runTimeoutFd(event.fd)
        assert r
        client.pager.container.requestLines().then(proc() =
          client.pager.container.cursorLastLine())
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()
    if client.pager.scommand != "":
      client.command(client.pager.scommand)
      client.pager.scommand = ""
      client.handlePagerEvents()
    if client.pager.container == nil:
      # No buffer to display.
      quit(1)
    client.pager.showAlerts()
    client.pager.draw()

func hasSelectFds(client: Client): bool =
  return not client.timeouts.empty or
    client.pager.numload > 0 or
    client.loader.connecting.len > 0 or
    client.loader.ongoing.len > 0 or
    client.pager.procmap.len > 0

proc headlessLoop(client: Client) =
  while client.hasSelectFds():
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        client.handleRead(event.fd)
      if Error in event.events:
        client.handleError(event.fd)
      if selectors.Event.Timer in event.events:
        let r = client.timeouts.runTimeoutFd(event.fd)
        assert r
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()

proc clientLoadJSModule(ctx: JSContext, module_name: cstringConst,
    opaque: pointer): JSModuleDef {.cdecl.} =
  let global = JS_GetGlobalObject(ctx)
  JS_FreeValue(ctx, global)
  var x: Option[URL]
  if module_name[0] == '/' or module_name[0] == '.' and
      (module_name[1] == '/' or
      module_name[1] == '.' and module_name[2] == '/'):
    let cur = getCurrentDir()
    x = parseURL($module_name, parseURL("file://" & cur & "/"))
  else:
    x = parseURL($module_name)
  if x.isNone or x.get.scheme != "file":
    JS_ThrowTypeError(ctx, "Invalid URL: %s", module_name)
    return nil
  try:
    let f = readFile($x.get.path)
    return finishLoadModule(ctx, f, cstring(module_name))
  except IOError:
    JS_ThrowTypeError(ctx, "Failed to open file %s", module_name)
    return nil

proc readBlob(client: Client, path: string): Option[WebFile] {.jsfunc.} =
  try:
    return some(newWebFile(path))
  except IOError:
    discard

#TODO this is dumb
proc readFile(client: Client, path: string): string {.jsfunc.} =
  try:
    return readFile(path)
  except IOError:
    discard

#TODO ditto
proc writeFile(client: Client, path: string, content: string) {.jsfunc.} =
  writeFile(path, content)

const ConsoleTitle = "Browser Console"

proc addConsole(pager: Pager, interactive: bool, clearFun, showFun, hideFun:
    proc()): ConsoleWrapper =
  if interactive:
    var pipefd: array[0..1, cint]
    if pipe(pipefd) == -1:
      raise newException(Defect, "Failed to open console pipe.")
    let url = newURL("stream:console").get
    let container = pager.readPipe0(some("text/plain"), CHARSET_UNKNOWN,
      pipefd[0], some(url), ConsoleTitle, canreinterpret = false)
    let err = newPosixStream(pipefd[1])
    err.writeLine("Type (M-c) console.hide() to return to buffer mode.")
    err.flush()
    pager.registerContainer(container)
    let console = newConsole(
      err,
      clearFun = clearFun,
      showFun = showFun,
      hideFun = hideFun
    )
    return ConsoleWrapper(
      console: console,
      container: container
    )
  else:
    let err = newFileStream(stderr)
    return ConsoleWrapper(
      console: newConsole(err)
    )

proc clearConsole(client: Client) =
  var pipefd: array[0..1, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open console pipe.")
  let url = newURL("stream:console").get
  let pager = client.pager
  let replacement = pager.readPipe0(some("text/plain"), CHARSET_UNKNOWN,
    pipefd[0], some(url), ConsoleTitle, canreinterpret = false)
  replacement.replace = client.consoleWrapper.container
  pager.registerContainer(replacement)
  client.consoleWrapper.container = replacement
  let console = client.consoleWrapper.console
  console.err.close()
  console.err = newPosixStream(pipefd[1])

proc dumpBuffers(client: Client) =
  client.headlessLoop()
  let ostream = newFileStream(stdout)
  for container in client.pager.containers:
    try:
      client.pager.drawBuffer(container, ostream)
      client.pager.handleEvents(container)
    except IOError:
      client.console.log("Error in buffer", $container.location)
      # check for errors
      client.handleRead(client.forkserver.estream.fd)
      quit(1)
  stdout.close()

proc launchClient*(client: Client, pages: seq[string],
    contentType: Option[string], cs: Charset, dump: bool) =
  var infile: File
  var dump = dump
  if not dump:
    if stdin.isatty():
      infile = stdin
    if stdout.isatty():
      if infile == nil:
        dump = not open(infile, "/dev/tty", fmRead)
    else:
      dump = true
  let selector = newSelector[int]()
  let efd = int(client.forkserver.estream.fd)
  selector.registerHandle(efd, {Read}, 0)
  client.loader.registerFun = proc(fd: int) =
    selector.registerHandle(fd, {Read}, 0)
  client.loader.unregisterFun = proc(fd: int) =
    selector.unregister(fd)
  client.selector = selector
  client.pager.launchPager(infile)
  let clearFun = proc() =
    client.clearConsole()
  let showFun = proc() =
    client.showConsole()
  let hideFun = proc() =
    client.hideConsole()
  client.consoleWrapper = addConsole(client.pager, interactive = infile != nil,
    clearFun, showFun, hideFun)
  #TODO passing console.err here makes it impossible to change it later. maybe
  # better associate it with jsctx
  client.timeouts = newTimeoutState(client.selector, client.jsctx,
    client.console.err, proc(src, file: string) = client.evalJSFree(src, file))
  client.alive = true
  addExitProc((proc() = client.quit()))
  if client.config.start.startup_script != "":
    let s = if fileExists(client.config.start.startup_script):
      readFile(client.config.start.startup_script)
    else:
      client.config.start.startup_script
    let ismodule = client.config.start.startup_script.endsWith(".mjs")
    client.command0(s, client.config.start.startup_script, silence = true,
      module = ismodule)

  if not stdin.isatty():
    client.pager.readPipe(contentType, cs, stdin.getFileHandle(), "*stdin*")

  for page in pages:
    client.pager.loadURL(page, ctype = contentType, cs = cs)
  client.pager.showAlerts()
  client.acceptBuffers()
  if not dump:
    client.inputLoop()
  else:
    client.dumpBuffers()
  if client.config.start.headless:
    client.headlessLoop()
  client.quit()

proc nimGCStats(client: Client): string {.jsfunc.} =
  return GC_getStatistics()

proc jsGCStats(client: Client): string {.jsfunc.} =
  return client.jsrt.getMemoryUsage()

proc nimCollect(client: Client) {.jsfunc.} =
  GC_fullCollect()

proc jsCollect(client: Client) {.jsfunc.} =
  JS_RunGC(client.jsrt)

proc sleep(client: Client, millis: int) {.jsfunc.} =
  sleep millis

proc atob(client: Client, data: string): DOMResult[NarrowString] {.jsfunc.} =
  return atob(data)

proc btoa(client: Client, data: JSString): DOMResult[string] {.jsfunc.} =
  return btoa(data)

func line(client: Client): LineEdit {.jsfget.} =
  return client.pager.lineedit.get(nil)

proc addJSModules(client: Client, ctx: JSContext) =
  ctx.addDOMExceptionModule()
  ctx.addConsoleModule()
  ctx.addCookieModule()
  ctx.addURLModule()
  ctx.addEventModule()
  ctx.addDOMModule()
  ctx.addHTMLModule()
  ctx.addIntlModule()
  ctx.addBlobModule()
  ctx.addFormDataModule()
  ctx.addXMLHttpRequestModule()
  ctx.addHeadersModule()
  ctx.addRequestModule()
  ctx.addResponseModule()
  ctx.addLineEditModule()
  ctx.addConfigModule()
  ctx.addPagerModule()
  ctx.addContainerModule()
  ctx.addEncodingModule()

func getClient(client: Client): Client {.jsfget: "client".} =
  return client

proc newClient*(config: Config, forkserver: ForkServer): Client =
  setControlCHook(proc() {.noconv.} = quit(1))
  let jsrt = newJSRuntime()
  JS_SetModuleLoaderFunc(jsrt, normalizeModuleName, clientLoadJSModule, nil)
  let jsctx = jsrt.newJSContext()
  let attrs = getWindowAttributes(stdout)
  let pager = newPager(config, attrs, forkserver, jsctx)
  let client = Client(
    config: config,
    forkserver: forkserver,
    loader: forkserver.newFileLoader(
      defaultHeaders = config.getDefaultHeaders(),
      proxy = config.getProxy(),
      urimethodmap = config.getURIMethodMap(),
      cgiDir = pager.cgiDir,
      acceptProxy = true,
      w3mCGICompat = config.external.w3m_cgi_compat
    ),
    jsrt: jsrt,
    jsctx: jsctx,
    pager: pager
  )
  jsrt.setInterruptHandler(interruptHandler, cast[pointer](client))
  var global = JS_GetGlobalObject(jsctx)
  jsctx.registerType(Client, asglobal = true)
  setGlobal(jsctx, global, client)
  JS_FreeValue(jsctx, global)
  client.addJSModules(jsctx)
  return client
