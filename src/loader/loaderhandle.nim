import std/net
import std/streams

import io/multistream
import io/posixstream
import io/serialize
import io/socketstream
import loader/headers

type LoaderHandle* = ref object
  ostream: Stream
  # Stream for taking input
  istream*: PosixStream
  # Only the first handle can be redirected, because a) mailcap can only
  # redirect the first handle and b) async redirects would result in race
  # conditions that would be difficult to untangle.
  canredir: bool
  sostream: Stream # saved ostream when redirected
  sostream_suspend: Stream # saved ostream when suspended
  fd: int

# Create a new loader handle, with the output stream ostream.
proc newLoaderHandle*(ostream: Stream, canredir: bool): LoaderHandle =
  return LoaderHandle(
    ostream: ostream,
    canredir: canredir,
    fd: int(SocketStream(ostream).source.getFd())
  )

proc getFd*(handle: LoaderHandle): int =
  return handle.fd

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
    let ms = newMultiStream(handle.ostream, stream)
    handle.ostream = ms

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

proc sendData*(handle: LoaderHandle, p: pointer, nmemb: int) =
  handle.ostream.writeData(p, nmemb)

proc sendData*(handle: LoaderHandle, s: string) =
  if s.len > 0:
    handle.sendData(unsafeAddr s[0], s.len)

proc suspend*(handle: LoaderHandle) =
  handle.sostream_suspend = handle.ostream
  handle.ostream = newStringStream()

proc resume*(handle: LoaderHandle) =
  let ss = handle.ostream
  handle.ostream = handle.sostream_suspend
  handle.sostream_suspend = nil
  handle.sendData(ss.readAll())
  ss.close()

proc close*(handle: LoaderHandle) =
  if handle.sostream != nil:
    try:
      handle.sostream.swrite(true)
    except IOError:
      # ignore error, that just means the buffer has already closed the stream
      discard
    handle.sostream.close()
  handle.ostream.close()
  if handle.istream != nil:
    handle.istream.close()
