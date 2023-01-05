import nativesockets
import net
import options
import os
import selectors
import streams
import tables
import terminal

when defined(posix):
  import posix

import std/exitprocs

import bindings/quickjs
import buffer/container
import css/sheet
import config/config
import display/pager
import display/term
import html/dom
import html/htmlparser
import io/lineedit
import io/loader
import io/promise
import io/request
import io/window
import ips/forkserver
import ips/serialize
import ips/serversocket
import ips/socketstream
import js/javascript
import types/cookie
import types/dispatcher
import types/url

type
  Client* = ref ClientObj
  ClientObj* = object
    alive: bool
    attrs: WindowAttributes
    dispatcher: Dispatcher
    feednext: bool
    s: string
    errormessage: string
    userstyle: CSSStylesheet
    loader: FileLoader
    console {.jsget.}: Console
    pager {.jsget.}: Pager
    line {.jsget.}: LineEdit
    config {.jsget.}: Config
    jsrt: JSRuntime
    jsctx: JSContext
    timeoutid: int
    timeouts: Table[int, tuple[handler: (proc()), fdi: int]]
    intervals: Table[int, tuple[handler: (proc()), fdi: int, tofree: JSValue]]
    timeout_fdis: Table[int, int]
    interval_fdis: Table[int, int]
    fdmap: Table[int, Container]
    ssock: ServerSocket
    selector: Selector[Container]

  Console = ref object
    err: Stream
    pager: Pager
    container: Container
    prev: Container
    ibuf: string
    tty: File

proc readChar(console: Console): char =
  if console.ibuf == "":
    try:
      return console.tty.readChar()
    except EOFError:
      quit(1)
  result = console.ibuf[0]
  console.ibuf = console.ibuf.substr(1)

proc `=destroy`(client: var ClientObj) =
  if client.jsctx != nil:
    free(client.jsctx)
  if client.jsrt != nil:
    free(client.jsrt)

proc doRequest(client: Client, req: Request): Response {.jsfunc.} =
  client.loader.doRequest(req)

proc interruptHandler(rt: JSRuntime, opaque: pointer): int {.cdecl.} =
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
  while JS_IsJobPending(client.jsrt):
    var ctx: JSContext
    let r = JS_ExecutePendingJob(client.jsrt, addr ctx)
    if r == -1:
      ctx.writeException(client.console.err)

proc evalJS(client: Client, src, filename: string): JSValue =
  if client.console.tty != nil:
    unblockStdin(client.console.tty.getFileHandle())
  result = client.jsctx.eval(src, filename, JS_EVAL_TYPE_GLOBAL)
  client.runJSJobs()
  if client.console.tty != nil:
    restoreStdin(client.console.tty.getFileHandle())

proc evalJSFree(client: Client, src, filename: string) =
  JS_FreeValue(client.jsctx, client.evalJS(src, filename))

proc command0(client: Client, src: string, filename = "<command>", silence = false) =
  let ret = client.evalJS(src, filename)
  if JS_IsException(ret):
    client.jsctx.writeException(client.console.err)
  else:
    if not silence:
      let str = toString(client.jsctx, ret)
      if str.issome:
        client.console.err.write(str.get & '\n')
        client.console.err.flush()
  JS_FreeValue(client.jsctx, ret)

proc command(client: Client, src: string) =
  client.command0(src)
  client.console.container.requestLines().then(proc() =
    client.console.container.cursorLastLine())

proc quit(client: Client, code = 0) {.jsfunc.} =
  if client.alive:
    client.alive = false
    client.pager.quit()
  quit(code)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

proc alert(client: Client, msg: string) {.jsfunc.} =
  client.pager.alert(msg)

proc handlePagerEvents(client: Client) =
  let container = client.pager.container
  if container != nil:
    client.pager.handleEvents(container)

proc input(client: Client) =
  restoreStdin(client.console.tty.getFileHandle())
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
        if edit.write(client.s):
          client.s = ""
      else:
        let action = getLinedAction(client.config, client.s)
        if action == "":
          if edit.write(client.s):
            client.s = ""
          else:
            client.feedNext = true
        elif not client.feednext:
          client.evalJSFree(action, "<command>")
        if client.pager.lineedit.isNone:
          client.line = nil
        if not client.feedNext:
          client.pager.updateReadLine()
    else:
      client.s &= c
      let action = getNormalAction(client.config, client.s)
      client.evalJSFree(action, "<command>")
      if not client.feedNext:
        client.handlePagerEvents()
        client.pager.refreshStatusMsg()
    if not client.feednext:
      client.s = ""
      break
    else:
      client.feednext = false
  client.s = ""

proc setTimeout[T: JSValue|string](client: Client, handler: T, timeout = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  let fdi = client.selector.registerTimer(timeout, true, nil)
  client.timeout_fdis[fdi] = id
  when T is string:
    client.timeouts[id] = ((proc() =
      client.evalJSFree(handler, "setTimeout handler")
    ), fdi)
  else:
    let fun = JS_DupValue(client.jsctx, handler)
    client.timeouts[id] = ((proc() =
      let ret = JS_Call(client.jsctx, fun, JS_UNDEFINED, 0, nil)
      if JS_IsException(ret):
        client.jsctx.writeException(client.console.err)
      JS_FreeValue(client.jsctx, ret)
      JS_FreeValue(client.jsctx, fun)
    ), fdi)
  return id

proc setInterval[T: JSValue|string](client: Client, handler: T, interval = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  let fdi = client.selector.registerTimer(interval, false, nil)
  client.interval_fdis[fdi] = id
  when T is string:
    client.intervals[id] = ((proc() =
      client.evalJSFree(handler, "setInterval handler")
    ), fdi, JS_NULL)
  else:
    let fun = JS_DupValue(client.jsctx, handler)
    client.intervals[id] = ((proc() =
      let ret = JS_Call(client.jsctx, handler, JS_UNDEFINED, 0, nil)
      if JS_IsException(ret):
        client.jsctx.writeException(client.console.err)
      JS_FreeValue(client.jsctx, ret)
    ), fdi, fun)
  return id

proc clearTimeout(client: Client, id: int) {.jsfunc.} =
  if id in client.timeouts:
    let timeout = client.timeouts[id]
    client.selector.unregister(timeout.fdi)
    client.timeout_fdis.del(timeout.fdi)
    client.timeouts.del(id)

proc clearInterval(client: Client, id: int) {.jsfunc.} =
  if id in client.intervals:
    let interval = client.intervals[id]
    client.selector.unregister(interval.fdi)
    JS_FreeValue(client.jsctx, interval.tofree)
    client.interval_fdis.del(interval.fdi)
    client.intervals.del(id)

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
  while client.pager.procmap.len > 0:
    let stream = client.ssock.acceptSocketStream()
    var pid: Pid
    stream.sread(pid)
    if pid in client.pager.procmap:
      let container = client.pager.procmap[pid]
      client.pager.procmap.del(pid)
      container.setStream(stream)
      let fd = stream.source.getFd()
      client.fdmap[int(fd)] = container
      client.selector.registerHandle(fd, {Read}, nil)
      client.pager.handleEvents(container)
    else:
      #TODO uh what?
      client.console.log("???")
      stream.close()

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

proc handleRead(client: Client, fd: int) =
  if client.console.tty != nil and fd == client.console.tty.getFileHandle():
    client.input()
    client.handlePagerEvents()
  elif fd == client.dispatcher.forkserver.estream.fd:
    var nl = true
    while true:
      try:
        let c = client.dispatcher.forkserver.estream.readChar()
        if nl:
          client.console.err.write("STDERR: ")
          nl = false
        client.console.err.write(c)
        nl = c == '\n'
      except IOError:
        break
    client.console.err.flush()
  else:
    let container = client.fdmap[fd]
    client.pager.handleEvent(container)

proc handleError(client: Client, fd: int) =
  if client.console.tty != nil and fd == client.console.tty.getFileHandle():
    #TODO do something here...
    stderr.write("Error in tty\n")
    quit(1)
  elif fd == client.dispatcher.forkserver.estream.fd:
    #TODO do something here...
    stderr.write("Fork server crashed :(\n")
    quit(1)
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
      quit(1)

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
      if Event.Timer in event.events:
        if event.fd in client.interval_fdis:
          client.intervals[client.interval_fdis[event.fd]].handler()
        elif event.fd in client.timeout_fdis:
          let id = client.timeout_fdis[event.fd]
          let timeout = client.timeouts[id]
          timeout.handler()
          client.clearTimeout(id)
    if client.pager.scommand != "":
      client.command(client.pager.scommand)
      client.pager.scommand = ""
      client.handlePagerEvents()
    client.acceptBuffers()
    if client.pager.container == nil:
      # No buffer to display.
      quit(1)
    client.pager.showAlerts()
    client.pager.draw()

proc headlessLoop(client: Client) =
  while client.timeouts.len + client.intervals.len != 0 or client.pager.numload > 0:
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        client.handleRead(event.fd)
      if Error in event.events:
        client.handleError(event.fd)
      if Event.Timer in event.events:
        if event.fd in client.interval_fdis:
          client.intervals[client.interval_fdis[event.fd]].handler()
        elif event.fd in client.timeout_fdis:
          let id = client.timeout_fdis[event.fd]
          let timeout = client.timeouts[id]
          timeout.handler()
          client.clearTimeout(id)
    client.acceptBuffers()

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
    result.container = pager.readPipe0(some("text/plain"), pipefd[0], option(url), "Browser console")
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
      client.handleRead(client.dispatcher.forkserver.estream.fd)
      quit(1)
  stdout.close()

proc launchClient*(client: Client, pages: seq[string], ctype: Option[string], dump: bool) =
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
  client.ssock = initServerSocket(false)
  client.selector = newSelector[Container]()
  client.selector.registerHandle(int(client.dispatcher.forkserver.estream.fd), {Read}, nil)
  client.pager.launchPager(tty)
  client.console = newConsole(client.pager, tty)
  client.alive = true
  addExitProc((proc() = client.quit()))
  if client.config.startup != "":
    let s = if fileExists(client.config.startup):
      readFile(client.config.startup)
    else:
      client.config.startup
    client.command0(s, client.config.startup, silence = true)
  client.userstyle = client.config.stylesheet.parseStylesheet()

  if not stdin.isatty():
    client.pager.readPipe(ctype, stdin.getFileHandle())

  for page in pages:
    client.pager.loadURL(page, ctype = ctype)
  client.acceptBuffers()
  client.pager.refreshStatusMsg()
  if not dump:
    client.inputLoop()
  else:
    client.dumpBuffers()
  if client.config.headless:
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

proc newClient*(config: Config, dispatcher: Dispatcher): Client =
  new(result)
  result.config = config
  result.dispatcher = dispatcher
  result.attrs = getWindowAttributes(stdout)
  result.loader = dispatcher.forkserver.newFileLoader()
  result.jsrt = newJSRuntime()
  result.jsrt.setInterruptHandler(interruptHandler, cast[pointer](result))
  let ctx = result.jsrt.newJSContext()
  result.jsctx = ctx
  result.pager = newPager(config, result.attrs, dispatcher, ctx)
  var global = JS_GetGlobalObject(ctx)
  ctx.registerType(Client, asglobal = true)
  setOpaque(ctx, global, result)
  ctx.setProperty(global, "client", global)
  JS_FreeValue(ctx, global)

  ctx.registerType(Console)

  ctx.addCookieModule()
  ctx.addURLModule()
  ctx.addDOMModule()
  ctx.addHTMLModule()
  ctx.addRequestModule()
  ctx.addLineEditModule()
  ctx.addConfigModule()
  ctx.addPagerModule()
  ctx.addContainerModule()
