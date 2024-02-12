import std/deques
import std/net
import std/streams
import std/tables

import io/posixstream
import io/serialize
import io/socketstream
import loader/headers
import loader/streamid

when defined(debug):
  import types/url

const LoaderBufferPageSize = 4064 # 4096 - 32

type
  LoaderBufferObj = object
    page: ptr UncheckedArray[uint8]
    len: int

  LoaderBuffer* = ref LoaderBufferObj

  OutputHandle* = ref object
    parent*: LoaderHandle
    currentBuffer*: LoaderBuffer
    currentBufferIdx*: int
    buffers: Deque[LoaderBuffer]
    ostream*: PosixStream
    istreamAtEnd*: bool
    sostream*: PosixStream # saved ostream when redirected
    clientId*: StreamId
    registered*: bool

  LoaderHandle* = ref object
    # Stream for taking input
    istream*: PosixStream
    # Only the first handle can be redirected, because a) mailcap can only
    # redirect the first handle and b) async redirects would result in race
    # conditions that would be difficult to untangle.
    canredir: bool
    outputs*: seq[OutputHandle]
    cached*: bool
    cachepath*: string
    when defined(debug):
      url*: URL

{.warning[Deprecated]:off.}:
  proc `=destroy`(buffer: var LoaderBufferObj) =
    if buffer.page != nil:
      dealloc(buffer.page)
      buffer.page = nil

# Create a new loader handle, with the output stream ostream.
proc newLoaderHandle*(ostream: PosixStream, canredir: bool, clientId: StreamId):
    LoaderHandle =
  let handle = LoaderHandle(
    canredir: canredir
  )
  handle.outputs.add(OutputHandle(
    ostream: ostream,
    parent: handle,
    clientId: clientId
  ))
  return handle

proc findOutputHandle*(handle: LoaderHandle, fd: int): OutputHandle =
  for output in handle.outputs:
    if output.ostream.fd == fd:
      return output
  return nil

func `[]`*(buffer: LoaderBuffer, i: int): var uint8 {.inline.} =
  return buffer[].page[i]

func cap*(buffer: LoaderBuffer): int {.inline.} =
  return LoaderBufferPageSize

func len*(buffer: LoaderBuffer): var int {.inline.} =
  return buffer[].len

proc `len=`*(buffer: LoaderBuffer, i: int) {.inline.} =
  buffer[].len = i

proc newLoaderBuffer*(): LoaderBuffer =
  return LoaderBuffer(
    page: cast[ptr UncheckedArray[uint8]](alloc(LoaderBufferPageSize)),
    len: 0
  )

proc addBuffer*(output: OutputHandle, buffer: LoaderBuffer) =
  if output.currentBuffer == nil:
    output.currentBuffer = buffer
  else:
    output.buffers.addLast(buffer)

proc bufferCleared*(output: OutputHandle) =
  assert output.currentBuffer != nil
  output.currentBufferIdx = 0
  if output.buffers.len > 0:
    output.currentBuffer = output.buffers.popFirst()
  else:
    output.currentBuffer = nil

proc tee*(outputIn: OutputHandle, ostream: PosixStream, clientId: StreamId) =
  outputIn.parent.outputs.add(OutputHandle(
    parent: outputIn.parent,
    ostream: ostream,
    currentBuffer: outputIn.currentBuffer,
    currentBufferIdx: outputIn.currentBufferIdx,
    buffers: outputIn.buffers,
    istreamAtEnd: outputIn.istreamAtEnd,
    clientId: clientId
  ))

template output*(handle: LoaderHandle): OutputHandle =
  handle.outputs[0]

proc sendResult*(handle: LoaderHandle, res: int, msg = "") =
  handle.output.ostream.swrite(res)
  if res == 0: # success
    assert msg == ""
  else: # error
    handle.output.ostream.swrite(msg)

proc sendStatus*(handle: LoaderHandle, status: int) =
  handle.output.ostream.swrite(status)

proc sendHeaders*(handle: LoaderHandle, headers: Headers) =
  let output = handle.output
  output.ostream.swrite(headers)
  if handle.canredir:
    var redir: bool
    output.ostream.sread(redir)
    output.ostream.sread(handle.cached)
    if redir:
      let fd = SocketStream(output.ostream).recvFileHandle()
      output.sostream = output.ostream
      output.ostream = newPosixStream(fd)

proc sendData*(output: OutputHandle, p: pointer, nmemb: int): int =
  return output.ostream.sendData(p, nmemb)

proc close*(handle: LoaderHandle) =
  for output in handle.outputs:
    assert output.sostream == nil
    if output.ostream != nil:
      output.ostream.close()
      output.ostream = nil
  if handle.istream != nil:
    handle.istream.close()
    handle.istream = nil
