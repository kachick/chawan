import cstrutils
import nativesockets
import net
import options
import os
import selectors
import streams
import strutils
import tables
import terminal

when defined(posix):
  import posix

import std/exitprocs

import bindings/quickjs
import config/config
import css/sheet
import display/lineedit
import display/term
import display/window
import html/chadombuilder
import html/dom
import html/event
import io/posixstream
import io/promise
import io/socketstream
import js/base64
import js/domexception
import js/error
import js/fromjs
import js/intl
import js/javascript
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
import types/url
import types/opt
import utils/twtstr
import xhr/formdata
import xhr/xmlhttprequest

import chakasu/charset

type
  Client* = ref object
    alive: bool
    attrs: WindowAttributes
    config {.jsget.}: Config
    console {.jsget.}: Console
    errormessage: string
    fd: int
    fdmap: Table[int, Container]
    feednext: bool
    forkserver: ForkServer
    notnum: bool # has a non-numeric character been input already?
    jsctx: JSContext
    jsrt: JSRuntime
    line {.jsget.}: LineEdit
    loader: FileLoader
    mainproc: Pid
    pager {.jsget.}: Pager
    precnum: int32 # current number prefix (when vi-numeric-prefix is true)
    s: string # current input buffer
    selector: Selector[Container]
    store {.jsget, jsset.}: Document
    timeouts: TimeoutState[Container]
    userstyle: CSSStylesheet

  Console = ref object
    err: Stream
    pager: Pager
    container: Container
    prev: Container
    ibuf: string
    tty: File

jsDestructor(Client)
jsDestructor(Console)

proc readChar(console: Console): char =
  if console.ibuf == "":
    try:
      return console.tty.readChar()
    except EOFError:
      quit(1)
  result = console.ibuf[0]
  console.ibuf = console.ibuf.substr(1)

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
  if client.console == nil or client.console.tty == nil: return
  try:
    let c = client.console.tty.readChar()
    if c == char(3): #C-c
      client.console.ibuf = ""
      return 1
    else:
      client.console.ibuf &= c
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
        client.console.err.write(str.get & '\n')
        client.console.err.flush()
  JS_FreeValue(client.jsctx, ret)

proc command(client: Client, src: string) =
  client.command0(src)
  client.console.container.requestLines().then(proc() =
    client.console.container.cursorLastLine())

proc suspend(client: Client) {.jsfunc.} =
  client.pager.term.quit()
  discard kill(client.mainproc, cint(SIGSTOP))
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

proc evalAction(client: Client, action: string, arg0: int32) =
  let ret = client.evalJS(action, "<command>")
  let ctx = client.jsctx
  if JS_IsFunction(ctx, ret):
    if arg0 != 0:
      var arg0 = toJS(ctx, arg0)
      JS_FreeValue(ctx, JS_Call(ctx, ret, JS_UNDEFINED, 1, addr arg0))
      JS_FreeValue(ctx, arg0)
    else: # no precnum
      JS_FreeValue(ctx, JS_Call(ctx, ret, JS_UNDEFINED, 0, nil))
  JS_FreeValue(ctx, ret)

# The maximum number we are willing to accept.
# This should be fine for 32-bit signed ints (which precnum currently is).
# We can always increase it further (e.g. by switching to uint32, uint64...) if
# it proves to be too low.
const MaxPrecNum = 100000000

proc handleCommandInput(client: Client, c: char) =
  if client.config.input.vi_numeric_prefix and not client.notnum:
    if client.precnum != 0 and c == '0' or c in '1' .. '9':
      if client.precnum < MaxPrecNum: # better ignore than eval...
        client.precnum *= 10
        client.precnum += cast[int32](decValue(c))
      return
    else:
      client.notnum = true
  client.s &= c
  let action = getNormalAction(client.config, client.s)
  client.evalAction(action, client.precnum)
  if not client.feedNext:
    client.precnum = 0
    client.notnum = false
    client.handlePagerEvents()
    client.pager.refreshStatusMsg()

proc input(client: Client) =
  client.pager.term.restoreStdin()
  while true:
    let c = client.console.readChar()
    if client.pager.askpromise != nil:
      if c == 'y':
        client.pager.fulfillAsk(true)
        client.runJSJobs()
      elif c == 'n':
        client.pager.fulfillAsk(false)
        client.runJSJobs()
    elif client.pager.lineedit.isSome:
      client.s &= c
      let edit = client.pager.lineedit.get
      client.line = edit
      if edit.escNext:
        edit.escNext = false
        if edit.write(client.s, client.pager.term.cs):
          client.s = ""
      else:
        let action = getLinedAction(client.config, client.s)
        if action == "":
          if edit.write(client.s, client.pager.term.cs):
            client.s = ""
          else:
            client.feedNext = true
        elif not client.feednext:
          client.evalAction(action, 0)
        if client.pager.lineedit.isNone:
          client.line = nil
        if not client.feedNext:
          client.pager.updateReadLine()
    else:
      client.handleCommandInput(c)
    if not client.feednext:
      client.s = ""
      break
    else:
      client.feednext = false
  client.s = ""

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

proc log(console: Console, ss: varargs[string]) {.jsfunc.} =
  for i in 0..<ss.len:
    console.err.write(ss[i])
    if i != ss.high:
      console.err.write(' ')
  console.err.write('\n')
  console.err.flush()

proc show(console: Console) {.jsfunc.} =
  if console.pager.container != console.container:
    console.prev = console.pager.container
    console.pager.setContainer(console.container)
    console.container.requestLines()

proc hide(console: Console) {.jsfunc.} =
  if console.pager.container == console.container:
    console.pager.setContainer(console.prev)

proc buffer(console: Console): Container {.jsfget.} =
  return console.container

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
  for pid, container in client.pager.procmap:
    let stream = connectSocketStream(pid, buffered = false, blocking = true)
    container.setStream(stream)
    let fd = stream.source.getFd()
    client.fdmap[int(fd)] = container
    client.selector.registerHandle(fd, {Read}, nil)
    client.pager.handleEvents(container)
  client.pager.procmap.clear()

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

proc handleRead(client: Client, fd: int) =
  if client.console.tty != nil and fd == client.console.tty.getFileHandle():
    client.input()
    client.handlePagerEvents()
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
  client.handleRead(client.forkserver.estream.fd)

proc handleError(client: Client, fd: int) =
  if client.console.tty != nil and fd == client.console.tty.getFileHandle():
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
      if container != client.console.container:
        client.console.log("Error in buffer", $container.location)
      else:
        client.console.container = nil
      client.selector.unregister(fd)
      client.fdmap.del(fd)
    if client.console.container != nil:
      client.console.show()
    else:
      doAssert false

proc inputLoop(client: Client) =
  let selector = client.selector
  discard c_setvbuf(client.console.tty, nil, IONBF, 0)
  selector.registerHandle(int(client.console.tty.getFileHandle()), {Read}, nil)
  let sigwinch = selector.registerSignal(int(SIGWINCH), nil)
  while true:
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        client.handleRead(event.fd)
      if Error in event.events:
        client.handleError(event.fd)
      if Signal in event.events: 
        assert event.fd == sigwinch
        client.attrs = getWindowAttributes(client.console.tty)
        client.pager.windowChange(client.attrs)
      if selectors.Event.Timer in event.events:
        assert client.timeouts.runTimeoutFd(event.fd)
        client.runJSJobs()
        client.console.container.requestLines().then(proc() =
          client.console.container.cursorLastLine())
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
        assert client.timeouts.runTimeoutFd(event.fd)
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()

proc clientLoadJSModule(ctx: JSContext, module_name: cstring,
    opaque: pointer): JSModuleDef {.cdecl.} =
  let global = JS_GetGlobalObject(ctx)
  JS_FreeValue(ctx, global)
  var x: Option[URL]
  if module_name.startsWith("/") or module_name.startsWith("./") or
      module_name.startsWith("../"):
    let cur = getCurrentDir()
    x = parseURL($module_name, parseURL("file://" & cur & "/"))
  else:
    x = parseURL($module_name)
  if x.isNone or x.get.scheme != "file":
    JS_ThrowTypeError(ctx, "Invalid URL: %s", module_name)
    return nil
  try:
    let f = readFile($x.get.path)
    return finishLoadModule(ctx, f, module_name)
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

proc newConsole(pager: Pager, tty: File): Console =
  new(result)
  if tty != nil:
    var pipefd: array[0..1, cint]
    if pipe(pipefd) == -1:
      raise newException(Defect, "Failed to open console pipe.")
    let url = newURL("javascript:console.show()")
    result.container = pager.readPipe0(some("text/plain"), CHARSET_UNKNOWN,
      pipefd[0], option(url.get(nil)), "Browser console")
    var f: File
    if not open(f, pipefd[1], fmWrite):
      raise newException(Defect, "Failed to open file for console pipe.")
    result.err = newFileStream(f)
    result.err.writeLine("Type (M-c) console.hide() to return to buffer mode.")
    result.err.flush()
    result.pager = pager
    result.tty = tty
    pager.registerContainer(result.container)
  else:
    result.err = newFileStream(stderr)

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
  var tty: File
  var dump = dump
  if not dump:
    if stdin.isatty():
      tty = stdin
    if stdout.isatty():
      if tty == nil:
        dump = not open(tty, "/dev/tty", fmRead)
    else:
      dump = true
  let selector = newSelector[Container]()
  let efd = int(client.forkserver.estream.fd)
  selector.registerHandle(efd, {Read}, nil)
  client.loader.registerFun = proc(fd: int) =
    selector.registerHandle(fd, {Read}, nil)
  client.loader.unregisterFun = proc(fd: int) =
    selector.unregister(fd)
  client.selector = selector
  client.pager.launchPager(tty)
  client.console = newConsole(client.pager, tty)
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
  client.userstyle = client.config.css.stylesheet.parseStylesheet()

  if not stdin.isatty():
    client.pager.readPipe(contentType, cs, stdin.getFileHandle())

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

proc atob(client: Client, data: string): DOMResult[string] {.jsfunc.} =
  return atob(data)

proc btoa(client: Client, data: string): DOMResult[string] {.jsfunc.} =
  return btoa(data)

proc addJSModules(client: Client, ctx: JSContext) =
  ctx.addDOMExceptionModule()
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

func getClient(client: Client): Client {.jsfget: "client".} =
  return client

proc newClient*(config: Config, forkserver: ForkServer, mainproc: Pid): Client =
  setControlCHook(proc() {.noconv.} = quit(1))
  let jsrt = newJSRuntime()
  JS_SetModuleLoaderFunc(jsrt, normalizeModuleName, clientLoadJSModule, nil)
  let jsctx = jsrt.newJSContext()
  let attrs = getWindowAttributes(stdout)
  let client = Client(
    config: config,
    forkserver: forkserver,
    mainproc: mainproc,
    attrs: attrs,
    loader: forkserver.newFileLoader(
      defaultHeaders = config.getDefaultHeaders(),
      proxy = config.getProxy(),
      acceptProxy = true
    ),
    jsrt: jsrt,
    jsctx: jsctx,
    pager: newPager(config, attrs, forkserver, mainproc, jsctx)
  )
  jsrt.setInterruptHandler(interruptHandler, cast[pointer](client))
  var global = JS_GetGlobalObject(jsctx)
  jsctx.registerType(Client, asglobal = true)
  setGlobal(jsctx, global, client)
  JS_FreeValue(jsctx, global)
  jsctx.registerType(Console)
  client.addJSModules(jsctx)
  return client
