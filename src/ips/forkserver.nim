import streams

when defined(posix):
  import posix

import buffer/buffer
import config/config
import io/loader
import io/request
import io/urlfilter
import io/window
import ips/serialize
import ips/serversocket
import types/buffersource
import utils/twtstr

type
  ForkCommand* = enum
    FORK_BUFFER, FORK_LOADER, REMOVE_CHILD, LOAD_CONFIG

  ForkServer* = ref object
    process*: Pid
    istream*: Stream
    ostream*: Stream

  ForkServerContext = object
    istream: Stream
    ostream: Stream
    children: seq[(Pid, Pid)]

proc newFileLoader*(forkserver: ForkServer, defaultHeaders: HeaderList = DefaultHeaders, filter = newURLFilter()): FileLoader =
  forkserver.ostream.swrite(FORK_LOADER)
  forkserver.ostream.swrite(defaultHeaders)
  forkserver.ostream.swrite(filter)
  forkserver.ostream.flush()
  forkserver.istream.sread(result)

proc loadForkServerConfig*(forkserver: ForkServer, config: Config) =
  forkserver.ostream.swrite(LOAD_CONFIG)
  forkserver.ostream.swrite(config.getForkServerConfig())
  forkserver.ostream.flush()

proc removeChild*(forkserver: Forkserver, pid: Pid) =
  forkserver.ostream.swrite(REMOVE_CHILD)
  forkserver.ostream.swrite(pid)
  forkserver.ostream.flush()

proc forkLoader(ctx: var ForkServerContext, defaultHeaders: HeaderList, filter: URLFilter): FileLoader =
  var pipefd: array[2, cint]
  if pipe(pipefd) == -1:
    raise newException(Defect, "Failed to open pipe.")
  let pid = fork()
  if pid == 0:
    # child process
    for i in 0 ..< ctx.children.len: ctx.children[i] = (Pid(0), Pid(0))
    ctx.children.setLen(0)
    zeroMem(addr ctx, sizeof(ctx))
    discard close(pipefd[0]) # close read
    runFileLoader(pipefd[1], defaultHeaders, filter)
    assert false
  let readfd = pipefd[0] # get read
  discard close(pipefd[1]) # close write
  var readf: File
  if not open(readf, FileHandle(readfd), fmRead):
    raise newException(Defect, "Failed to open output handle.")
  assert readf.readChar() == char(0u8)
  close(readf)
  discard close(pipefd[0])
  return FileLoader(process: pid)

proc forkBuffer(ctx: var ForkServerContext): Pid =
  var source: BufferSource
  var config: BufferConfig
  var attrs: WindowAttributes
  var mainproc: Pid
  ctx.istream.sread(source)
  ctx.istream.sread(config)
  ctx.istream.sread(attrs)
  ctx.istream.sread(mainproc)
  let loader = ctx.forkLoader(DefaultHeaders, config.filter) #TODO make this configurable
  let pid = fork()
  if pid == 0:
    for i in 0 ..< ctx.children.len: ctx.children[i] = (Pid(0), Pid(0))
    ctx.children.setLen(0)
    zeroMem(addr ctx, sizeof(ctx))
    launchBuffer(config, source, attrs, loader, mainproc)
    assert false
  ctx.children.add((pid, loader.process))
  return pid

proc runForkServer() =
  var ctx: ForkServerContext
  ctx.istream = newFileStream(stdin)
  ctx.ostream = newFileStream(stdout)
  while true:
    try:
      var cmd: ForkCommand
      ctx.istream.sread(cmd)
      case cmd
      of REMOVE_CHILD:
        var pid: Pid
        ctx.istream.sread(pid)
        for i in 0 .. ctx.children.high:
          if ctx.children[i][0] == pid:
            ctx.children.del(i)
            break
      of FORK_BUFFER:
        ctx.ostream.swrite(ctx.forkBuffer())
      of FORK_LOADER:
        var defaultHeaders: HeaderList
        var filter: URLFilter
        ctx.istream.sread(defaultHeaders)
        ctx.istream.sread(filter)
        let loader = ctx.forkLoader(defaultHeaders, filter)
        ctx.ostream.swrite(loader)
        ctx.children.add((loader.process, Pid(-1)))
      of LOAD_CONFIG:
        var config: ForkServerConfig
        ctx.istream.sread(config)
        width_table = makewidthtable(config.ambiguous_double)
        SocketDirectory = config.tmpdir
      ctx.ostream.flush()
    except IOError:
      # EOF
      break
  ctx.istream.close()
  ctx.ostream.close()
  # Clean up when the main process crashed.
  for childpair in ctx.children:
    let a = childpair[0]
    let b = childpair[1]
    discard kill(cint(a), cint(SIGTERM))
    if b != -1:
      discard kill(cint(b), cint(SIGTERM))
  quit(0)

proc newForkServer*(): ForkServer =
  new(result)
  var pipefd_in: array[2, cint]
  var pipefd_out: array[2, cint]
  if pipe(pipefd_in) == -1:
    raise newException(Defect, "Failed to open input pipe.")
  if pipe(pipefd_out) == -1:
    raise newException(Defect, "Failed to open output pipe.")
  let pid = fork()
  if pid == -1:
    raise newException(Defect, "Failed to fork the fork process.")
  elif pid == 0:
    # child process
    let readfd = pipefd_in[0]
    discard close(pipefd_in[1]) # close write
    let writefd = pipefd_out[1]
    discard close(pipefd_out[0]) # close read
    discard dup2(readfd, stdin.getFileHandle())
    discard dup2(writefd, stdout.getFileHandle())
    discard close(pipefd_in[0])
    discard close(pipefd_out[1])
    runForkServer()
    assert false
  else:
    discard close(pipefd_in[0]) # close read
    discard close(pipefd_out[1]) # close write
    var readf, writef: File
    if not open(writef, pipefd_in[1], fmWrite):
      raise newException(Defect, "Failed to open output handle")
    if not open(readf, pipefd_out[0], fmRead):
      raise newException(Defect, "Failed to open input handle")
    result.ostream = newFileStream(writef)
    result.istream = newFileStream(readf)
