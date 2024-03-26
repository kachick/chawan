import std/exitprocs
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

import bindings/constcharp
import bindings/quickjs
import config/config
import html/chadombuilder
import html/dom
import html/event
import html/formdata
import html/xmlhttprequest
import io/bufstream
import io/bufwriter
import io/dynstream
import io/filestream
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
import local/lineedit
import local/pager
import local/term
import server/buffer
import server/forkserver
import types/blob
import types/cookie
import types/opt
import types/url
import utils/twtstr

import chagashi/charset

type
  Client* = ref object
    alive: bool
    config {.jsget.}: Config
    consoleWrapper: ConsoleWrapper
    fdmap: Table[int, Container]
    feednext: bool
    jsctx: JSContext
    jsrt: JSRuntime
    pager {.jsget.}: Pager
    timeouts: TimeoutState
    pressed: tuple[col: int, row: int]

  ConsoleWrapper = object
    console: Console
    container: Container
    prev: Container

jsDestructor(Client)

func console(client: Client): Console {.jsfget.} =
  return client.consoleWrapper.console

template selector(client: Client): Selector[int] =
  client.pager.selector

template loader(client: Client): FileLoader =
  client.pager.loader

template forkserver(client: Client): ForkServer =
  client.pager.forkserver

template readChar(client: Client): char =
  client.pager.term.readChar()

proc finalize(client: Client) {.jsfin.} =
  if client.jsctx != nil:
    free(client.jsctx)
  if client.jsrt != nil:
    free(client.jsrt)

proc fetch[T: Request|string](client: Client, req: T,
    init = none(RequestInit)): JSResult[FetchPromise] {.jsfunc.} =
  let req = ?newRequest(client.jsctx, req, init)
  return ok(client.loader.fetch(req))

proc interruptHandler(rt: JSRuntime, opaque: pointer): cint {.cdecl.} =
  let client = cast[Client](opaque)
  if client.console == nil or client.pager.term.istream == nil:
    return 0
  try:
    let c = client.pager.term.istream.sreadChar()
    if c == char(3): #C-c
      client.pager.term.ibuf = ""
      return 1
    else:
      client.pager.term.ibuf &= c
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
  if container != nil:
    container.tailOnLoad = true

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

proc evalActionJS(client: Client; action: string): JSValue =
  client.config.cmd.map.withValue(action, p):
    return JS_DupValue(client.jsctx, p[])
  return client.evalJS(action, "<command>")

proc evalAction(client: Client; action: string; arg0: int32): EmptyPromise =
  var ret = client.evalActionJS(action)
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
  if action != "":
    let p = client.evalAction(action, client.pager.precnum)
    if not client.feednext:
      client.pager.precnum = 0
      client.pager.notnum = false
      client.handlePagerEvents()
    return p
  if client.config.input.use_mouse:
    if client.pager.inputBuffer == "\e[<":
      let input = client.pager.term.parseMouseInput()
      if input.isSome:
        let input = input.get
        let container = client.pager.container
        if container != nil:
          case input.button
          of mibLeft:
            case input.t
            of mitPress:
              client.pressed = (input.col, input.row)
            of mitRelease:
              #TODO this does not work very well with double width chars,
              # because pressed could be equivalent to two separate cells
              if client.pressed == (input.col, input.row):
                if input.col == container.acursorx and
                    input.row == container.acursory:
                  container.click()
                else:
                  container.setCursorXY(container.fromx + input.col,
                    container.fromy + input.row)
              else:
                let diff = (input.col - client.pressed.col,
                  input.row - client.pressed.row)
                if diff[0] > 0:
                  container.scrollLeft(diff[0])
                else:
                  container.scrollRight(-diff[0])
                if diff[1] > 0:
                  container.scrollUp(diff[1])
                else:
                  container.scrollDown(-diff[1])
              client.pressed = (-1, -1)
            else: discard
          of mibMiddle:
            if input.t == mitRelease: # release, to emulate w3m
              client.pager.discardBuffer()
          of mibWheelUp:
            if input.t == mitPress:
              container.scrollUp(5)
          of mibWheelDown:
            if input.t == mitPress:
              container.scrollDown(5)
          of mibWheelLeft:
            if input.t == mitPress:
              container.scrollLeft(5)
          of mibWheelRight:
            if input.t == mitPress:
              container.scrollRight(5)
          of mibThumbInner:
            if input.t == mitPress:
              discard client.pager.prevBuffer()
          of mibThumbTip:
            if input.t == mitPress:
              discard client.pager.nextBuffer()
          else: discard
      client.pager.inputBuffer = ""
    elif "\e[<".startsWith(client.pager.inputBuffer):
      client.feednext = true
  return nil

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
      #TODO this is not perfect, because it results in us never displaying
      # lone escape. maybe a timeout for escape display would be useful
      if not "\e[<".startsWith(client.pager.inputBuffer):
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

proc hideConsole(client: Client) {.jsfunc.} =
  if client.pager.container == client.consoleWrapper.container:
    client.pager.setContainer(client.consoleWrapper.prev)

proc consoleBuffer(client: Client): Container {.jsfget.} =
  return client.consoleWrapper.container

proc acceptBuffers(client: Client) =
  let pager = client.pager
  while pager.unreg.len > 0:
    let container = pager.unreg.pop()
    if container.iface != nil: # fully connected
      let stream = container.iface.stream
      let fd = int(stream.source.fd)
      client.selector.unregister(fd)
      client.fdmap.del(fd)
      stream.sclose()
    elif container.process != -1: # connecting to buffer process
      let i = pager.findProcMapItem(container.process)
      pager.procmap.del(i)
    elif (let i = pager.findConnectingContainer(container); i != -1):
      # connecting to URL
      let stream = pager.connectingContainers[i].stream
      client.selector.unregister(stream.fd)
      stream.sclose()
      pager.connectingContainers.del(i)
  let registerFun = proc(fd: int) =
    client.selector.unregister(fd)
    client.selector.registerHandle(fd, {Read, Write}, 0)
  for item in pager.procmap:
    let container = item.container
    let stream = connectSocketStream(container.process)
    if stream == nil:
      pager.alert("Error: failed to set up buffer")
      continue
    let key = pager.addLoaderClient(container.process, container.loaderConfig)
    stream.withPacketWriter w:
      w.swrite(key)
      let loader = pager.loader
      if item.fdin != -1:
        let outputId = item.istreamOutputId
        if container.cacheId == -1:
          (container.cacheId, container.cacheFile) =
            loader.addCacheFile(outputId, loader.clientPid)
        var outCacheId = container.cacheId
        let pid = container.process
        if item.fdout == item.fdin:
          loader.shareCachedItem(container.cacheId, pid)
          loader.resume(@[item.istreamOutputId])
        else:
          outCacheId = loader.addCacheFile(item.ostreamOutputId, pid).outputId
          loader.resume(@[item.istreamOutputId, item.ostreamOutputId])
        w.swrite(outCacheId)
    if item.fdin != -1:
      # pass down fdout
      # must come after the previous block so the first packet is flushed
      stream.sendFileHandle(item.fdout)
      discard close(item.fdout)
      container.setStream(stream, registerFun)
    else:
      # buffer is cloned, no need to cache anything
      container.setCloneStream(stream, registerFun)
    let fd = int(stream.fd)
    client.fdmap[fd] = container
    client.selector.registerHandle(fd, {Read}, 0)
    pager.handleEvents(container)
  pager.procmap.setLen(0)

proc handleRead(client: Client; fd: int) =
  if client.pager.term.istream != nil and fd == client.pager.term.istream.fd:
    client.input().then(proc() =
      client.handlePagerEvents()
    )
  elif (let i = client.pager.findConnectingContainer(fd); i != -1):
    client.pager.handleConnectingContainer(i)
  elif fd == client.forkserver.estream.fd:
    const BufferSize = 4096
    const prefix = "STDERR: "
    var buffer {.noinit.}: array[BufferSize, char]
    let estream = client.forkserver.estream
    var hadlf = true
    while true:
      try:
        let n = estream.recvData(addr buffer[0], BufferSize)
        if n == 0:
          break
        var i = 0
        while i < n:
          var j = n
          var found = false
          for k in i ..< n:
            if buffer[k] == '\n':
              j = k + 1
              found = true
              break
          if hadlf:
            client.console.err.write(prefix)
          if j - i > 0:
            client.console.err.write(buffer.toOpenArray(i, j - 1))
          i = j
          hadlf = found
      except ErrorAgain:
        break
    if not hadlf:
      client.console.err.write('\n')
    client.console.err.sflush()
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

proc handleWrite(client: Client, fd: int) =
  let container = client.fdmap[fd]
  if container.iface.stream.flushWrite():
    client.selector.unregister(fd)
    client.selector.registerHandle(fd, {Read}, 0)

proc flushConsole*(client: Client) {.jsfunc.} =
  if client.console == nil:
    # hack for when client crashes before console has been initialized
    client.consoleWrapper = ConsoleWrapper(
      console: newConsole(newDynFileStream(stderr))
    )
  client.handleRead(client.forkserver.estream.fd)

proc handleError(client: Client, fd: int) =
  if client.pager.term.istream != nil and fd == client.pager.term.istream.fd:
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
  elif (let i = client.pager.findConnectingContainer(fd); i != -1):
    client.pager.handleConnectingContainerError(i)
  else:
    if fd in client.fdmap:
      let container = client.fdmap[fd]
      if container != client.consoleWrapper.container:
        client.console.log("Error in buffer", $container.url)
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
  selector.registerHandle(int(client.pager.term.istream.fd), {Read}, 0)
  let sigwinch = selector.registerSignal(int(SIGWINCH), 0)
  while true:
    let events = client.selector.select(-1)
    for event in events:
      if Read in event.events:
        client.handleRead(event.fd)
      if Write in event.events:
        client.handleWrite(event.fd)
      if Error in event.events:
        client.handleError(event.fd)
      if Signal in event.events:
        assert event.fd == sigwinch
        client.pager.windowChange()
      if selectors.Event.Timer in event.events:
        let r = client.timeouts.runTimeoutFd(event.fd)
        assert r
        let container = client.consoleWrapper.container
        if container != nil:
          container.tailOnLoad = true
    client.runJSJobs()
    client.loader.unregistered.setLen(0)
    client.acceptBuffers()
    if client.pager.scommand != "":
      client.command(client.pager.scommand)
      client.pager.scommand = ""
      client.handlePagerEvents()
    if client.pager.container == nil and client.pager.lineedit.isNone:
      # No buffer to display.
      if not client.pager.hasload:
        # Failed to load every single URL the user passed us. We quit, and that
        # will dump all alerts to stderr.
        quit(1)
      else:
        # At least one connection has succeeded, but we have nothing to display.
        # Normally, this means that the input stream has been redirected to a
        # file or to an external program. That also means we can't just exit
        # without potentially interrupting that stream.
        #TODO: a better UI would be querying the number of ongoing streams in
        # loader, and then asking for confirmation if there is at least one.
        client.pager.term.setCursor(0, client.pager.term.attrs.height - 1)
        client.pager.term.anyKey("Hit any key to quit Chawan:")
        quit(0)
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
      if Write in event.events:
        client.handleWrite(event.fd)
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

proc addConsole(pager: Pager; interactive: bool; clearFun, showFun, hideFun:
    proc()): ConsoleWrapper =
  if interactive and pager.config.start.console_buffer:
    var pipefd: array[0..1, cint]
    if pipe(pipefd) == -1:
      raise newException(Defect, "Failed to open console pipe.")
    let url = newURL("stream:console").get
    let container = pager.readPipe0("text/plain", CHARSET_UNKNOWN, pipefd[0],
      url, ConsoleTitle, {})
    let err = newPosixStream(pipefd[1])
    err.write("Type (M-c) console.hide() to return to buffer mode.\n")
    let console = newConsole(err, clearFun, showFun, hideFun)
    return ConsoleWrapper(console: console, container: container)
  else:
    let err = newPosixStream(stderr.getFileHandle())
    return ConsoleWrapper(console: newConsole(err))

proc clearConsole(client: Client) =
  var pipefd: array[0..1, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open console pipe.")
  let url = newURL("stream:console").get
  let pager = client.pager
  let replacement = pager.readPipe0("text/plain", CHARSET_UNKNOWN, pipefd[0],
    url, ConsoleTitle, {})
  replacement.replace = client.consoleWrapper.container
  pager.replace(client.consoleWrapper.container, replacement)
  client.consoleWrapper.container = replacement
  let console = client.consoleWrapper.console
  console.err.sclose()
  console.err = newPosixStream(pipefd[1])

proc dumpBuffers(client: Client) =
  client.headlessLoop()
  let ostream = newFileStream(stdout)
  for container in client.pager.containers:
    try:
      client.pager.drawBuffer(container, ostream)
      client.pager.handleEvents(container)
    except IOError:
      client.console.log("Error in buffer", $container.url)
      # check for errors
      client.handleRead(client.forkserver.estream.fd)
      quit(1)

proc launchClient*(client: Client; pages: seq[string];
    contentType: Option[string]; cs: Charset; dump: bool) =
  var istream: PosixStream
  var dump = dump
  if not dump:
    if stdin.isatty():
      istream = newPosixStream(stdin.getFileHandle())
    dump = istream == nil
    if stdout.isatty():
      istream = newPosixStream("/dev/tty", O_RDONLY, 0)
      if istream != nil:
        dump = false
    else:
      dump = true
  let selector = newSelector[int]()
  let efd = int(client.forkserver.estream.fd)
  selector.registerHandle(efd, {Read}, 0)
  client.loader.registerFun = proc(fd: int) =
    selector.registerHandle(fd, {Read}, 0)
  client.loader.unregisterFun = proc(fd: int) =
    selector.unregister(fd)
  client.pager.launchPager(istream, selector)
  let clearFun = proc() =
    client.clearConsole()
  let showFun = proc() =
    client.showConsole()
  let hideFun = proc() =
    client.hideConsole()
  client.consoleWrapper = client.pager.addConsole(interactive = istream != nil,
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
    # stdin may very well receive ANSI text
    let contentType = contentType.get("text/x-ansi")
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

proc btoa(ctx: JSContext, client: Client, data: JSValue): DOMResult[string]
    {.jsfunc.} =
  return btoa(ctx, data)

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

proc newClient*(config: Config; forkserver: ForkServer; jsctx: JSContext;
    warnings: seq[string]): Client =
  setControlCHook(proc() {.noconv.} = quit(1))
  let jsrt = JS_GetRuntime(jsctx)
  JS_SetModuleLoaderFunc(jsrt, normalizeModuleName, clientLoadJSModule, nil)
  let pager = newPager(config, forkserver, jsctx, warnings)
  let loader = forkserver.newFileLoader(LoaderConfig(
    urimethodmap: config.external.urimethodmap,
    w3mCGICompat: config.external.w3m_cgi_compat,
    cgiDir: seq[string](config.external.cgi_dir),
    tmpdir: config.external.tmpdir
  ))
  pager.setLoader(loader)
  let client = Client(config: config, jsrt: jsrt, jsctx: jsctx, pager: pager)
  jsrt.setInterruptHandler(interruptHandler, cast[pointer](client))
  var global = JS_GetGlobalObject(jsctx)
  jsctx.registerType(Client, asglobal = true)
  setGlobal(jsctx, global, client)
  jsctx.definePropertyE(global, "cmd", config.cmd.jsObj)
  config.cmd.jsObj = JS_NULL
  JS_FreeValue(jsctx, global)
  client.addJSModules(jsctx)
  return client
