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
import html/dom
import html/htmlparser
import io/lineedit
import io/loader
import io/request
import io/term
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
    sevent: seq[Container]
    config: Config
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
    return console.tty.readChar()
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
  if client.console.tty == nil: return
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

proc evalJS(client: Client, src, filename: string): JSObject =
  if client.console.tty != nil:
    unblockStdin(client.console.tty.getFileHandle())
  result = client.jsctx.eval(src, filename, JS_EVAL_TYPE_GLOBAL)
  if client.console.tty != nil:
    restoreStdin(client.console.tty.getFileHandle())

proc evalJSFree(client: Client, src, filename: string) =
  free(client.evalJS(src, filename))

proc command0(client: Client, src: string, filename = "<command>", silence = false) =
  let ret = client.evalJS(src, filename)
  if ret.isException():
    client.jsctx.writeException(client.console.err)
  else:
    if not silence:
      let str = ret.toString()
      if str.issome:
        client.console.err.write(str.get & '\n')
        client.console.err.flush()
  free(ret)

proc command(client: Client, src: string) =
  restoreStdin(client.console.tty.getFileHandle())
  client.command0(src)
  client.console.container.cursorLastLine()

proc quit(client: Client, code = 0) {.jsfunc.} =
  if client.alive:
    client.alive = false
    client.pager.quit()
  quit(code)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

proc alert(client: Client, msg: string) {.jsfunc.} =
  client.pager.alert(msg)

proc input(client: Client) =
  restoreStdin(client.console.tty.getFileHandle())
  while true:
    let c = client.console.readChar()
    client.s &= c
    if client.pager.lineedit.isSome:
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
        elif not client.feedNext:
          client.evalJSFree(action, "<command>")
        if client.pager.lineedit.isNone:
          client.line = nil
        if not client.feedNext:
          client.pager.updateReadLine()
    else:
      let action = getNormalAction(client.config, client.s)
      client.evalJSFree(action, "<command>")
      if not client.feedNext:
        client.pager.refreshStatusMsg()
    if not client.feedNext:
      client.s = ""
      break
    else:
      client.feedNext = false

proc setTimeout[T: JSObject|string](client: Client, handler: T, timeout = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  let fdi = client.selector.registerTimer(timeout, true, nil)
  client.timeout_fdis[fdi] = id
  when T is string:
    client.timeouts[id] = ((proc() =
      client.evalJSFree(handler, "setTimeout handler")
    ), fdi)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.timeouts[id] = ((proc() =
      let ret = JSObject(ctx: handler.ctx, val: fun).callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
      JS_FreeValue(ret.ctx, fun)
    ), fdi)
  return id

proc setInterval[T: JSObject|string](client: Client, handler: T, interval = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  let fdi = client.selector.registerTimer(interval, false, nil)
  client.interval_fdis[fdi] = id
  when T is string:
    client.intervals[id] = ((proc() =
      client.evalJSFree(handler, "setInterval handler")
    ), fdi, JS_NULL)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.intervals[id] = ((proc() =
      let obj = JSObject(ctx: handler.ctx, val: fun)
      let ret = obj.callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
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
      client.sevent.add(container)
    else:
      #TODO uh what?
      eprint "???"
      stream.close()

proc log(console: Console, ss: varargs[string]) {.jsfunc.} =
  for i in 0..<ss.len:
    console.err.write(ss[i])
    if i != ss.high:
      console.err.write(' ')
  console.err.write('\n')
  console.err.flush()

proc inputLoop(client: Client) =
  let selector = client.selector
  selector.registerHandle(int(client.console.tty.getFileHandle()), {Read}, nil)
  let sigwinch = selector.registerSignal(int(SIGWINCH), nil)
  let redrawtimer = client.selector.registerTimer(1000, false, nil)
  while true:
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        if event.fd == client.console.tty.getFileHandle():
          client.input()
          stdout.flushFile()
        else:
          let container = client.fdmap[event.fd]
          if not client.pager.handleEvent(container):
            client.quit(1)
      if Error in event.events:
        #TODO handle errors
        client.alert("Error in selected fds, check console")
        client.console.log($event)
      if Signal in event.events: 
        if event.fd == sigwinch:
          client.attrs = getWindowAttributes(client.console.tty)
          client.pager.windowChange(client.attrs)
        else: assert false
      if Event.Timer in event.events:
        if event.fd == redrawtimer:
          if client.pager.container != nil:
            client.pager.container.requestLines()
        elif event.fd in client.interval_fdis:
          client.intervals[client.interval_fdis[event.fd]].handler()
        elif event.fd in client.timeout_fdis:
          let id = client.timeout_fdis[event.fd]
          let timeout = client.timeouts[id]
          timeout.handler()
          client.clearTimeout(id)
    if client.pager.scommand != "":
      client.command(client.pager.scommand)
      client.pager.scommand = ""
      client.pager.refreshStatusMsg()
    client.pager.draw()
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
    result.pager = pager
    result.tty = tty
    pager.registerContainer(result.container)
  else:
    result.err = newFileStream(stderr)

proc dumpBuffers(client: Client) =
  let ostream = newFileStream(stdout)
  for container in client.pager.containers:
    client.pager.drawBuffer(container, ostream)
    discard client.pager.handleEvents(container)
  stdout.close()

proc launchClient*(client: Client, pages: seq[string], ctype: Option[string], dump: bool) =
  var tty: File
  var dump = dump
  if not dump:
    if stdin.isatty():
      tty = stdin
    elif stdout.isatty():
      discard open(tty, "/dev/tty", fmRead)
    else:
      dump = true
  client.ssock = initServerSocket(false)
  client.selector = newSelector[Container]()
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
  if not stdin.isatty:
    client.pager.readPipe(ctype, stdin.getFileHandle())
  else:
    client.console.tty = stdin

  for page in pages:
    client.pager.loadURL(page, ctype = ctype)
  client.acceptBuffers()
  client.pager.refreshStatusMsg()
  if not dump:
    client.inputLoop()
  else:
    client.dumpBuffers()
  client.quit()

proc nimGCStats(client: Client): string {.jsfunc.} =
  return GC_getStatistics()

proc jsGCStats(client: Client): string {.jsfunc.} =
  return client.jsrt.getMemoryUsage()

proc show(console: Console) {.jsfunc.} =
  if console.pager.container != console.container:
    console.prev = console.pager.container
    console.pager.setContainer(console.container)

proc hide(console: Console) {.jsfunc.} =
  if console.pager.container == console.container:
    console.pager.setContainer(console.prev)

proc sleep(client: Client, millis: int) {.jsfunc.} =
  sleep millis

proc newClient*(config: Config, dispatcher: Dispatcher): Client =
  new(result)
  result.config = config
  result.dispatcher = dispatcher
  result.attrs = getWindowAttributes(stdout)
  result.loader = dispatcher.forkserver.newFileLoader()
  result.pager = newPager(config, result.attrs, dispatcher)
  result.jsrt = newJSRuntime()
  result.jsrt.setInterruptHandler(interruptHandler, cast[pointer](result))
  let ctx = result.jsrt.newJSContext()
  result.jsctx = ctx
  var global = ctx.getGlobalObject()
  ctx.registerType(Client, asglobal = true)
  global.setOpaque(result)
  ctx.setProperty(global.val, "client", global.val)
  free(global)

  ctx.registerType(Console)

  ctx.addCookieModule()
  ctx.addUrlModule()
  ctx.addDOMModule()
  ctx.addHTMLModule()
  ctx.addRequestModule()
  ctx.addLineEditModule()
  ctx.addPagerModule()
  ctx.addContainerModule()
