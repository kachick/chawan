import std/deques
import std/net
import std/tables

import io/bufwriter
import io/dynstream
import io/posixstream
import loader/headers

when defined(debug):
  import types/url

const LoaderBufferPageSize = 4064 # 4096 - 32

type
  LoaderBufferObj = object
    page*: ptr UncheckedArray[uint8]
    len*: int

  LoaderBuffer* = ref LoaderBufferObj

  OutputHandle* = ref object
    parent*: LoaderHandle
    currentBuffer*: LoaderBuffer
    currentBufferIdx*: int
    buffers*: Deque[LoaderBuffer]
    ostream*: PosixStream
    istreamAtEnd*: bool
    ownerPid*: int
    outputId*: int
    registered*: bool
    suspended*: bool
    dead*: bool
    when defined(debug):
      url*: URL

  HandleParserState* = enum
    hpsBeforeLines, hpsAfterFirstLine, hpsControlDone

  HeaderParser* = ref object
    state*: HandleParserState
    lineBuffer*: string
    crSeen*: bool
    headers*: Headers
    status*: uint16

  ResponseState = enum
    rsBeforeResult, rsAfterFailure, rsBeforeStatus, rsBeforeHeaders,
    rsAfterHeaders

  LoaderHandle* = ref object
    istream*: PosixStream # stream for taking input
    outputs*: seq[OutputHandle] # list of outputs to be streamed into
    cacheId*: int # if cached, our ID in a client cacheMap
    parser*: HeaderParser # only exists for CGI handles
    rstate: ResponseState # track response state
    when defined(debug):
      url*: URL

{.warning[Deprecated]:off.}:
  proc `=destroy`(buffer: var LoaderBufferObj) =
    if buffer.page != nil:
      dealloc(buffer.page)
      buffer.page = nil

# for debugging
when defined(debug):
  func `$`*(buffer: LoaderBuffer): string =
    var s = newString(buffer.len)
    copyMem(addr s[0], addr buffer.page[0], buffer.len)
    return s

# Create a new loader handle, with the output stream ostream.
proc newLoaderHandle*(ostream: PosixStream; outputId, pid: int): LoaderHandle =
  let handle = LoaderHandle(cacheId: -1)
  handle.outputs.add(OutputHandle(
    ostream: ostream,
    parent: handle,
    outputId: outputId,
    ownerPid: pid,
    suspended: true
  ))
  return handle

proc findOutputHandle*(handle: LoaderHandle; fd: int): OutputHandle =
  for output in handle.outputs:
    if output.ostream.fd == fd:
      return output
  return nil

func cap*(buffer: LoaderBuffer): int {.inline.} =
  return LoaderBufferPageSize

template isEmpty*(output: OutputHandle): bool =
  output.currentBuffer == nil and not output.suspended

proc newLoaderBuffer*(): LoaderBuffer =
  return LoaderBuffer(
    page: cast[ptr UncheckedArray[uint8]](alloc(LoaderBufferPageSize)),
    len: 0
  )

proc bufferCleared*(output: OutputHandle) =
  assert output.currentBuffer != nil
  output.currentBufferIdx = 0
  if output.buffers.len > 0:
    output.currentBuffer = output.buffers.popFirst()
  else:
    output.currentBuffer = nil

proc tee*(outputIn: OutputHandle; ostream: PosixStream; outputId, pid: int) =
  let parent = outputIn.parent
  parent.outputs.add(OutputHandle(
    parent: parent,
    ostream: ostream,
    currentBuffer: outputIn.currentBuffer,
    currentBufferIdx: outputIn.currentBufferIdx,
    buffers: outputIn.buffers,
    istreamAtEnd: outputIn.istreamAtEnd,
    outputId: outputId,
    ownerPid: pid,
    suspended: outputIn.suspended
  ))

template output*(handle: LoaderHandle): OutputHandle =
  handle.outputs[0]

proc sendResult*(handle: LoaderHandle; res: int; msg = "") =
  assert handle.rstate == rsBeforeResult
  inc handle.rstate
  let output = handle.output
  let blocking = output.ostream.blocking
  output.ostream.setBlocking(true)
  output.ostream.withPacketWriter w:
    w.swrite(res)
    if res == 0: # success
      assert msg == ""
      w.swrite(output.outputId)
      inc handle.rstate
    else: # error
      w.swrite(msg)
  output.ostream.setBlocking(blocking)

proc sendStatus*(handle: LoaderHandle; status: uint16) =
  assert handle.rstate == rsBeforeStatus
  inc handle.rstate
  let blocking = handle.output.ostream.blocking
  handle.output.ostream.setBlocking(true)
  handle.output.ostream.withPacketWriter w:
    w.swrite(status)
  handle.output.ostream.setBlocking(blocking)

proc sendHeaders*(handle: LoaderHandle; headers: Headers) =
  assert handle.rstate == rsBeforeHeaders
  inc handle.rstate
  let blocking = handle.output.ostream.blocking
  handle.output.ostream.setBlocking(true)
  handle.output.ostream.withPacketWriter w:
    w.swrite(headers)
  handle.output.ostream.setBlocking(blocking)

proc recvData*(ps: PosixStream; buffer: LoaderBuffer): int {.inline.} =
  let n = ps.recvData(addr buffer.page[0], buffer.cap)
  buffer.len = n
  return n

proc sendData*(ps: PosixStream; buffer: LoaderBuffer; si = 0): int {.inline.} =
  assert buffer.len - si > 0
  return ps.sendData(addr buffer.page[si], buffer.len - si)

proc iclose*(handle: LoaderHandle) =
  if handle.istream != nil:
    if handle.rstate notin {rsBeforeResult, rsAfterFailure, rsAfterHeaders}:
      assert handle.outputs.len == 1
      # not an ideal solution, but better than silently eating malformed
      # headers
      try:
        handle.sendStatus(500)
        handle.sendHeaders(newHeaders())
        handle.output.ostream.setBlocking(true)
        const msg = "Error: malformed header in CGI script"
        discard handle.output.ostream.sendData(msg)
      except ErrorBrokenPipe:
        discard # receiver is dead
    handle.istream.sclose()
    handle.istream = nil

proc close*(handle: LoaderHandle) =
  handle.iclose()
  for output in handle.outputs:
    #TODO assert not output.registered
    if output.ostream != nil:
      output.ostream.sclose()
      output.ostream = nil
