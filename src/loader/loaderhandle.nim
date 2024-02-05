import std/deques
import std/net
import std/streams

import io/multistream
import io/posixstream
import io/serialize
import io/socketstream
import loader/headers

import types/url
type
  LoaderBufferPage = array[4056, uint8] # 4096 - 8 - 32

  LoaderBufferObj = object
    page*: LoaderBufferPage
    len: int

  LoaderBuffer* = ptr LoaderBufferObj

  LoaderHandle* = ref object
    ostream*: PosixStream #TODO un-extern
    # Stream for taking input
    istream*: PosixStream
    # Only the first handle can be redirected, because a) mailcap can only
    # redirect the first handle and b) async redirects would result in race
    # conditions that would be difficult to untangle.
    canredir: bool
    sostream: Stream # saved ostream when redirected
    sostream_suspend: Stream # saved ostream when suspended
    fd*: int # ostream fd
    currentBuffer*: LoaderBuffer
    currentBufferIdx*: int
    buffers: Deque[LoaderBuffer]
    url*: URL #TODO TODO TODO debug

# Create a new loader handle, with the output stream ostream.
proc newLoaderHandle*(ostream: PosixStream, canredir: bool, url: URL): LoaderHandle =
  return LoaderHandle(
    ostream: ostream,
    canredir: canredir,
    fd: int(SocketStream(ostream).source.getFd()),
    url: url
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
  if likely(handle.sostream_suspend != nil):
    let ms = newMultiStream(handle.sostream_suspend, stream)
    handle.sostream_suspend = ms
  else:
    # In buffer, addOutputStream is used as follows:
    # * suspend handle
    # * tee handle (-> call addOutputStream)
    # * resume handle
    # This means that this code path will never be executed, as
    # sostream_suspend is never nil when the function is called.
    # (Feel free to remove this assertion if this changes.)
    doAssert false
    #TODO TODO TODO fix this
    #let ms = newMultiStream(handle.ostream, stream)
    #handle.ostream = ms

proc setBlocking*(handle: LoaderHandle, blocking: bool) =
  #TODO this is stupid
  if handle.sostream_suspend != nil and handle.sostream_suspend of SocketStream:
    SocketStream(handle.sostream_suspend).setBlocking(blocking)
  elif handle.sostream != nil and handle.sostream of SocketStream:
    SocketStream(handle.sostream).setBlocking(blocking)
  else:
    SocketStream(handle.ostream).setBlocking(blocking)

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
      let stream = newPosixStream(fd)
      handle.ostream = stream

proc sendData*(handle: LoaderHandle, p: pointer, nmemb: int): int =
  return handle.ostream.sendData(p, nmemb)

proc suspend*(handle: LoaderHandle) =
  #TODO TODO TODO fix suspend
  doAssert false
  handle.sostream_suspend = handle.ostream
  #handle.ostream = newStringStream()

proc resume*(handle: LoaderHandle) =
  #TODO TODO TODO fix resume
  doAssert false
  #[
  let ss = handle.ostream
  handle.ostream = handle.sostream_suspend
  handle.sostream_suspend = nil
  handle.sendData(ss.readAll())
  ss.close()
  ]#

proc close*(handle: LoaderHandle) =
  if handle.sostream != nil:
    try:
      handle.sostream.swrite(true)
    except IOError:
      # ignore error, that just means the buffer has already closed the stream
      discard
    handle.sostream.close()
  if handle.ostream != nil:
    handle.ostream.close()
    handle.ostream = nil
  if handle.istream != nil:
    handle.istream.close()
    handle.istream = nil
