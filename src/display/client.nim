import options
import os
import streams
import tables
import terminal
import times

when defined(posix):
  import posix

import std/monotimes
import std/selectors

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
import js/javascript
import types/cookie
import types/url
import utils/twtstr

type
  Client* = ref ClientObj
  ClientObj* = object
    attrs: TermAttributes
    feednext: bool
    s: string
    errormessage: string
    userstyle: CSSStylesheet
    loader: FileLoader
    console {.jsget.}: Console
    pager {.jsget.}: Pager
    line {.jsget.}: LineEdit
    config: Config
    jsrt: JSRuntime
    jsctx: JSContext
    timeoutid: int
    timeouts: Table[int, tuple[handler: proc(), time: int64]]
    added_timeouts: Table[int, tuple[handler: proc(), time: int64]]
    removed_timeouts: seq[int]
    intervals: Table[int, tuple[handler: proc(), time: int64, wait: int, del: JSValue]]
    added_intervals: Table[int, tuple[handler: proc(), time: int64, wait: int, del: JSValue]]
    removed_intervals: seq[int]

  Console* = ref object
    err*: Stream
    lastcontainer*: Container
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

proc statusMode(client: Client) =
  print(HVP(client.attrs.height + 1, 1))
  print(EL())

proc doRequest(client: Client, req: Request): Response {.jsfunc.} =
  client.loader.doRequest(req)

proc interruptHandler(rt: JSRuntime, opaque: pointer): int {.cdecl.} =
  let client = cast[Client](opaque)
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
  unblockStdin(client.console.tty.getFileHandle())
  result = client.jsctx.eval(src, filename, JS_EVAL_TYPE_GLOBAL)
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
  free(ret)
  for k, v in client.added_timeouts:
    client.timeouts[k] = v
  client.added_timeouts.clear()
  for k, v in client.added_intervals:
    client.intervals = client.added_intervals
  client.added_intervals.clear()

proc command(client: Client, src: string) =
  restoreStdin(client.console.tty.getFileHandle())
  let previ = client.console.err.getPosition()
  client.command0(src)
  client.console.err.setPosition(previ)
  #TODO yeah this won't work...
  #if client.console.lastcontainer == nil:
  #  let source = BufferSource(t: STRING, slocation: parseUrl("javascript:void(0);").get, str: client.console.err.readAll(), contenttype: some("text/plain"))
  #  let container = newBuffer(client.config, client.console.tty, source)
  #  client.console.lastcontainer = container
  #  client.pager.addContainer(container)
  #else:
  #  client.console.lastbuf.istream = newStringStream(client.console.lastbuf.source & client.console.err.readAll())
  #  client.console.lastbuf.streamclosed = false
  #client.console.lastbuf.setupBuffer()
  #client.console.lastbuf.cursorLastLine()

proc command(client: Client): bool {.jsfunc.} =
  client.statusMode()
  client.pager.lineedit = some(readLine("COMMAND: ", client.attrs.width, config = client.config, tty = client.console.tty))

proc commandMode(client: Client) {.jsfunc.} =
  client.pager.commandMode = client.command()

proc quit(client: Client, code = 0) {.jsfunc.} =
  if stdout.isatty():
    print(HVP(getTermAttributes(stdout).height, 1))
    print('\n')
    print(EL())
    stdout.showCursor()
  when defined(posix):
    assert kill(client.loader.process, cint(SIGTERM)) == 0
  quit(code)

proc feedNext(client: Client) {.jsfunc.} =
  client.feednext = true

proc input(client: Client) =
  restoreStdin(client.console.tty.getFileHandle())
  if client.pager.commandMode:
    client.commandMode()
    return
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
    client.s = ""
  else:
    client.feedNext = false
  if client.pager.container != nil:
    if client.pager.lineedit.isNone:
      client.pager.refreshStatusMsg()
      client.pager.displayStatus()
      client.pager.displayCursor()

proc c_setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>", tags: [].}

proc inputLoop(client: Client) =
  discard c_setvbuf(client.console.tty, nil, IONBF, 0) #??? I thought raw mode would take care of this
  client.pager.selector.registerHandle(int(client.console.tty.getFileHandle()), {Read}, nil)
  while true:
    let events = client.pager.selector.select(-1)
    for event in events:
      if event.fd == client.console.tty.getFileHandle():
        client.input()
        stdout.flushFile()
      else:
        let container = client.pager.fdmap[FileHandle(event.fd)]
        if not client.pager.handleEvent(container):
          disableRawMode()
          for msg in client.pager.status:
            eprint msg
          client.quit(1)
    if client.pager.lineedit.isNone and client.pager.switched:
      client.pager.refreshDisplay(client.pager.container)
      client.pager.displayPage()
      client.pager.switched = false
    if client.pager.command != "":
      client.command(client.pager.command)
      client.pager.command = ""

#TODO this is dumb
proc readFile(client: Client, path: string): string {.jsfunc.} =
  try:
    return readFile(path)
  except IOError:
    discard

#TODO ditto
proc writeFile(client: Client, path: string, content: string) {.jsfunc.} =
  writeFile(path, content)

import bindings/quickjs

proc setTimeout[T: JSObject|string](client: Client, handler: T, timeout = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  when T is string:
    client.added_timeouts[id] = ((proc() =
      client.evalJSFree(handler, "setTimeout handler")
    ), getMonoTime().ticks div 1_000_000 + timeout)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.added_timeouts[id] = ((proc() =
      let ret = JSObject(ctx: handler.ctx, val: fun).callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
      JS_FreeValue(ret.ctx, fun)
    ), getMonoTime().ticks div 1_000_000 + timeout)
  return id

proc setInterval[T: JSObject|string](client: Client, handler: T, interval = 0): int {.jsfunc.} =
  let id = client.timeoutid
  inc client.timeoutid
  when T is string:
    client.added_intervals[id] = ((proc() =
      client.evalJSFree(handler, "setInterval handler")
    ), getMonoTime().ticks div 1_000_000 + interval, interval, JS_NULL)
  else:
    let fun = JS_DupValue(handler.ctx, handler.val)
    client.added_intervals[id] = ((proc() =
      let ret = JSObject(ctx: handler.ctx, val: fun).callFunction()
      if ret.isException():
        ret.ctx.writeException(client.console.err)
      JS_FreeValue(ret.ctx, ret.val)
    ), getMonoTime().ticks div 1_000_000 + interval, interval, fun)
  return id

proc clearTimeout(client: Client, id: int) {.jsfunc.} =
  client.removed_timeouts.add(id)

proc clearInterval(client: Client, id: int) {.jsfunc.} =
  client.removed_intervals.add(id)

proc jsEventLoop(client: Client) =
  while client.timeouts.len > 0 or client.intervals.len > 0:
    var wait = -1
    let curr = getMonoTime().ticks div 1_000_000
    for k, v in client.timeouts:
      if v.time <= curr:
        v.handler()
        client.removed_timeouts.add(k)
    for k, v in client.intervals.mpairs:
      if v.time <= curr:
        v.handler()
        v.time = curr + v.wait
    for k, v in client.added_timeouts:
      client.timeouts[k] = v
    client.added_timeouts.clear()
    for k, v in client.added_intervals:
      client.intervals[k] = v
    client.added_intervals.clear()
    for k in client.removed_timeouts:
      client.timeouts.del(k)
    for k in client.removed_intervals:
      if k in client.intervals and client.intervals[k].del != JS_NULL:
        JS_FreeValue(client.jsctx, client.intervals[k].del)
      client.intervals.del(k)
    client.removed_timeouts.setLen(0)
    client.removed_intervals.setLen(0)
    for k, v in client.timeouts:
      if wait != -1:
        wait = min(wait, int(v.time - curr))
      else:
        wait = int(v.time - curr)
    for k, v in client.intervals:
      if wait != -1:
        wait = min(wait, int(v.time - curr))
      else:
        wait = int(v.time - curr)
    if wait > 0:
      sleep(wait)

proc launchClient*(client: Client, pages: seq[string], ctype: Option[string], dump: bool) =
  if client.config.startup != "":
    let s = readFile(client.config.startup)
    client.console.err = newFileStream(stderr)
    client.command0(s, client.config.startup, silence = true)
    client.jsEventLoop()
    client.console.err = newStringStream()
    quit()
  client.userstyle = client.config.stylesheet.parseStylesheet()
  if not stdin.isatty:
    client.pager.readPipe(ctype)
  else:
    client.console.tty = stdin

  for page in pages:
    client.pager.loadURL(page, ctype = ctype)

  if stdout.isatty and not dump:
    when defined(posix):
      enableRawMode(client.console.tty.getFileHandle())
    client.inputLoop()
  else:
    for msg in client.pager.status:
      eprint msg
    for container in client.pager.containers:
      container.render()
      container.drawBuffer()
    stdout.close()
  client.quit()

proc nimGCStats(client: Client): string {.jsfunc.} =
  return GC_getStatistics()

proc jsGCStats(client: Client): string {.jsfunc.} =
  return client.jsrt.getMemoryUsage()

func newConsole(): Console =
  new(result)
  result.err = newStringStream()

proc log(console: Console, ss: varargs[string]) {.jsfunc.} =
  for i in 0..<ss.len:
    console.err.write(ss[i])
    if i != ss.high:
      console.err.write(' ')
  console.err.write('\n')

proc sleep(client: Client, millis: int) {.jsfunc.} =
  sleep millis

proc newClient*(config: Config): Client =
  new(result)
  result.config = config
  result.console = newConsole()
  if stdin.isatty():
    result.console.tty = stdin
  elif stdout.isatty():
    discard open(result.console.tty, "/dev/tty", fmRead)
  result.attrs = getTermAttributes(stdout)
  result.loader = newFileLoader()
  result.pager = newPager(config, result.attrs, result.console.tty)
  let rt = newJSRuntime()
  rt.setInterruptHandler(interruptHandler, cast[pointer](result))
  let ctx = rt.newJSContext()
  result.jsrt = rt
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
