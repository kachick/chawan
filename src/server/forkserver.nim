import std/options
import std/os
import std/posix
import std/streams
import std/tables

import config/config
import display/term
import io/posixstream
import io/serialize
import io/serversocket
import loader/loader
import server/buffer
import types/urimethodmap
import types/url
import utils/strwidth

import chagashi/charset

type
  ForkCommand = enum
    fcForkBuffer, fcForkLoader, fcRemoveChild, fcLoadConfig

  ForkServer* = ref object
    istream: Stream
    ostream: Stream
    estream*: PosixStream

  ForkServerContext = object
    istream: Stream
    ostream: Stream
    children: seq[int]
    loaderPid: int

proc newFileLoader*(forkserver: ForkServer; config: LoaderConfig): FileLoader =
  forkserver.ostream.swrite(fcForkLoader)
  forkserver.ostream.swrite(config)
  forkserver.ostream.flush()
  var process: int
  forkserver.istream.sread(process)
  return FileLoader(process: process, clientPid: getCurrentProcessId())

proc loadForkServerConfig*(forkserver: ForkServer, config: Config) =
  forkserver.ostream.swrite(fcLoadConfig)
  forkserver.ostream.swrite(config.getForkServerConfig())
  forkserver.ostream.flush()

proc removeChild*(forkserver: ForkServer, pid: int) =
  forkserver.ostream.swrite(fcRemoveChild)
  forkserver.ostream.swrite(pid)
  forkserver.ostream.flush()

proc forkBuffer*(forkserver: ForkServer; config: BufferConfig; url: URL;
    request: Request; attrs: WindowAttributes; ishtml: bool;
    charsetStack: seq[Charset]): int =
  forkserver.ostream.swrite(fcForkBuffer)
  forkserver.ostream.swrite(config)
  forkserver.ostream.swrite(url)
  forkserver.ostream.swrite(request)
  forkserver.ostream.swrite(attrs)
  forkserver.ostream.swrite(ishtml)
  forkserver.ostream.swrite(charsetStack)
  forkserver.ostream.flush()
  var bufferPid: int
  forkserver.istream.sread(bufferPid)
  bufferPid

proc trapSIGINT() =
  # trap SIGINT, so e.g. an external editor receiving an interrupt in the
  # same process group can't just kill the process
  # Note that the main process normally quits on interrupt (thus terminating
  # all child processes as well).
  setControlCHook(proc() {.noconv.} = discard)

proc forkLoader(ctx: var ForkServerContext, config: LoaderConfig): int =
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open pipe.")
  let pid = fork()
  if pid == 0:
    # child process
    trapSIGINT()
    for i in 0 ..< ctx.children.len: ctx.children[i] = 0
    ctx.children.setLen(0)
    zeroMem(addr ctx, sizeof(ctx))
    discard close(pipefd[0]) # close read
    try:
      runFileLoader(pipefd[1], config)
    except CatchableError:
      let e = getCurrentException()
      # taken from system/excpt.nim
      let msg = e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n"
      stderr.write(msg)
      quit(1)
    doAssert false
  let readfd = pipefd[0] # get read
  discard close(pipefd[1]) # close write
  var readf: File
  if not open(readf, FileHandle(readfd), fmRead):
    raise newException(Defect, "Failed to open output handle.")
  let c = readf.readChar()
  assert c == char(0u8)
  close(readf)
  discard close(pipefd[0])
  return pid

var gssock: ServerSocket
proc forkBuffer(ctx: var ForkServerContext): int =
  var config: BufferConfig
  var url: URL
  var request: Request
  var attrs: WindowAttributes
  var ishtml: bool
  var charsetStack: seq[Charset]
  ctx.istream.sread(config)
  ctx.istream.sread(url)
  ctx.istream.sread(request)
  ctx.istream.sread(attrs)
  ctx.istream.sread(ishtml)
  ctx.istream.sread(charsetStack)
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open pipe.")
  let pid = fork()
  if pid == -1:
    raise newException(Defect, "Failed to fork process.")
  if pid == 0:
    # child process
    trapSIGINT()
    for i in 0 ..< ctx.children.len: ctx.children[i] = 0
    ctx.children.setLen(0)
    let loaderPid = ctx.loaderPid
    zeroMem(addr ctx, sizeof(ctx))
    discard close(pipefd[0]) # close read
    let pid = getCurrentProcessId()
    let ssock = initServerSocket(pid, buffered = false)
    gssock = ssock
    onSignal SIGTERM:
      # This will be overridden after buffer has been set up; it is only
      # necessary to avoid a race condition when buffer is killed before that.
      discard sig
      gssock.close()
    let ps = newPosixStream(pipefd[1])
    ps.write(char(0))
    ps.close()
    discard close(stdin.getFileHandle())
    discard close(stdout.getFileHandle())
    let loader = FileLoader(
      process: loaderPid,
      clientPid: pid
    )
    try:
      launchBuffer(config, url, request, attrs, ishtml, charsetStack, loader,
        ssock)
    except CatchableError:
      let e = getCurrentException()
      # taken from system/excpt.nim
      let msg = e.getStackTrace() & "Error: unhandled exception: " & e.msg &
        " [" & $e.name & "]\n"
      stderr.write(msg)
      quit(1)
    doAssert false
  discard close(pipefd[1]) # close write
  let ps = newPosixStream(pipefd[0])
  let c = ps.readChar()
  assert c == char(0)
  ps.close()
  ctx.children.add(pid)
  return pid

proc runForkServer() =
  var ctx = ForkServerContext(
    istream: newPosixStream(stdin.getFileHandle()),
    ostream: newPosixStream(stdout.getFileHandle())
  )
  while true:
    try:
      var cmd: ForkCommand
      ctx.istream.sread(cmd)
      case cmd
      of fcRemoveChild:
        var pid: int
        ctx.istream.sread(pid)
        let i = ctx.children.find(pid)
        if i != -1:
          ctx.children.del(i)
      of fcForkBuffer:
        ctx.ostream.swrite(ctx.forkBuffer())
      of fcForkLoader:
        assert ctx.loaderPid == 0
        var config: LoaderConfig
        ctx.istream.sread(config)
        let pid = ctx.forkLoader(config)
        ctx.ostream.swrite(pid)
        ctx.loaderPid = pid
        ctx.children.add(pid)
      of fcLoadConfig:
        var config: ForkServerConfig
        ctx.istream.sread(config)
        set_cjk_ambiguous(config.ambiguous_double)
        SocketDirectory = config.tmpdir
      ctx.ostream.flush()
    except EOFError:
      # EOF
      break
  ctx.istream.close()
  ctx.ostream.close()
  # Clean up when the main process crashed.
  for child in ctx.children:
    discard kill(cint(child), cint(SIGTERM))
  quit(0)

proc newForkServer*(): ForkServer =
  var pipefd_in: array[2, cint] # stdin in forkserver
  var pipefd_out: array[2, cint] # stdout in forkserver
  var pipefd_err: array[2, cint] # stderr in forkserver
  if pipe(pipefd_in) == -1:
    raise newException(Defect, "Failed to open input pipe.")
  if pipe(pipefd_out) == -1:
    raise newException(Defect, "Failed to open output pipe.")
  if pipe(pipefd_err) == -1:
    raise newException(Defect, "Failed to open error pipe.")
  let pid = fork()
  if pid == -1:
    raise newException(Defect, "Failed to fork the fork process.")
  elif pid == 0:
    # child process
    trapSIGINT()
    discard close(pipefd_in[1]) # close write
    discard close(pipefd_out[0]) # close read
    discard close(pipefd_err[0]) # close read
    let readfd = pipefd_in[0]
    let writefd = pipefd_out[1]
    let errfd = pipefd_err[1]
    discard dup2(readfd, stdin.getFileHandle())
    discard dup2(writefd, stdout.getFileHandle())
    discard dup2(errfd, stderr.getFileHandle())
    stderr.flushFile()
    discard close(pipefd_in[0])
    discard close(pipefd_out[1])
    discard close(pipefd_err[1])
    runForkServer()
    doAssert false
  else:
    discard close(pipefd_in[0]) # close read
    discard close(pipefd_out[1]) # close write
    discard close(pipefd_err[1]) # close write
    var writef, readf: File
    if not open(writef, pipefd_in[1], fmWrite):
      raise newException(Defect, "Failed to open output handle")
    if not open(readf, pipefd_out[0], fmRead):
      raise newException(Defect, "Failed to open input handle")
    let estream = newPosixStream(pipefd_err[0])
    estream.setBlocking(false)
    return ForkServer(
      ostream: newFileStream(writef),
      istream: newFileStream(readf),
      estream: estream
    )
