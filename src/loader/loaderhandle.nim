import std/deques
import std/net
import std/streams

import io/posixstream
import io/serialize
import io/socketstream
import loader/headers

when defined(debug):
  import types/url

type
  LoaderBufferPage = array[4056, uint8] # 4096 - 8 - 32

  LoaderBufferObj = object
    page*: LoaderBufferPage
    len: int

  LoaderBuffer* = ptr LoaderBufferObj

  OutputHandle* = object

  LoaderHandle* = ref object
    ostream*: PosixStream #TODO un-extern
    # Stream for taking input
    istream*: PosixStream
    # Only the first handle can be redirected, because a) mailcap can only
    # redirect the first handle and b) async redirects would result in race
    # conditions that would be difficult to untangle.
    canredir: bool
    sostream*: PosixStream # saved ostream when redirected
    currentBuffer*: LoaderBuffer
    currentBufferIdx*: int
    buffers: Deque[LoaderBuffer]
    when defined(debug):
      url*: URL

# Create a new loader handle, with the output stream ostream.
proc newLoaderHandle*(ostream: PosixStream, canredir: bool): LoaderHandle =
  return LoaderHandle(
    ostream: ostream,
    canredir: canredir
  )

func `[]`*(buffer: LoaderBuffer, i: int): var uint8 {.inline.} =
  return buffer[].page[i]

func cap*(buffer: LoaderBuffer): int {.inline.} =
  return buffer[].page.len

func len*(buffer: LoaderBuffer): var int {.inline.} =
  return buffer[].len

proc `len=`*(buffer: LoaderBuffer, i: int) {.inline.} =
  buffer[].len = i

proc newLoaderBuffer*(): LoaderBuffer =
  let buffer = cast[LoaderBuffer](alloc(sizeof(LoaderBufferObj)))
  buffer.len = 0
  return buffer

proc addBuffer*(handle: LoaderHandle, buffer: LoaderBuffer) =
  if handle.currentBuffer == nil:
    handle.currentBuffer = buffer
  else:
    handle.buffers.addLast(buffer)

proc bufferCleared*(handle: LoaderHandle) =
  assert handle.currentBuffer != nil
  handle.currentBufferIdx = 0
  dealloc(handle.currentBuffer)
  if handle.buffers.len > 0:
    handle.currentBuffer = handle.buffers.popFirst()
  else:
    handle.currentBuffer = nil

proc addOutputStream*(handle: LoaderHandle, stream: Stream) =
  doAssert false
  #TODO TODO TODO fix this
  #let ms = newMultiStream(handle.ostream, stream)
  #handle.ostream = ms

proc sendResult*(handle: LoaderHandle, res: int, msg = "") =
  handle.ostream.swrite(res)
  if res == 0: # success
    assert msg == ""
  else: # error
    handle.ostream.swrite(msg)

proc sendStatus*(handle: LoaderHandle, status: int) =
  handle.ostream.swrite(status)

proc sendHeaders*(handle: LoaderHandle, headers: Headers) =
  handle.ostream.swrite(headers)
  if handle.canredir:
    var redir: bool
    handle.ostream.sread(redir)
    if redir:
      let fd = SocketStream(handle.ostream).recvFileHandle()
      handle.sostream = handle.ostream
      handle.ostream = newPosixStream(fd)

proc sendData*(handle: LoaderHandle, p: pointer, nmemb: int): int =
  return handle.ostream.sendData(p, nmemb)

proc close*(handle: LoaderHandle) =
  assert handle.sostream == nil
  if handle.ostream != nil:
    handle.ostream.close()
    handle.ostream = nil
  if handle.istream != nil:
    handle.istream.close()
    handle.istream = nil
