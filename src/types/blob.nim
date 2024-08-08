import std/options
import std/posix
import std/strutils

import monoucha/fromjs
import monoucha/javascript
import monoucha/jstypes
import utils/mimeguess

type
  DeallocFun = proc(blob: Blob) {.closure, raises: [].}

  Blob* = ref object of RootObj
    size* {.jsget.}: uint64
    ctype* {.jsget: "type".}: string
    buffer*: pointer
    deallocFun*: DeallocFun
    fd*: Option[FileHandle]

  WebFile* = ref object of Blob
    webkitRelativePath {.jsget.}: string
    name* {.jsget.}: string

jsDestructor(Blob)
jsDestructor(WebFile)

proc newBlob*(buffer: pointer; size: int; ctype: string;
    deallocFun: DeallocFun): Blob =
  return Blob(
    buffer: buffer,
    size: uint64(size),
    ctype: ctype,
    deallocFun: deallocFun
  )

proc finalize(blob: Blob) {.jsfin.} =
  if blob.fd.isSome:
    discard close(blob.fd.get)
  if blob.deallocFun != nil and blob.buffer != nil:
    blob.deallocFun(blob)
    blob.buffer = nil

proc finalize(file: WebFile) {.jsfin.} =
  Blob(file).finalize()

proc newWebFile*(name: string; fd: FileHandle): WebFile =
  return WebFile(
    name: name,
    fd: some(fd),
    ctype: DefaultGuess.guessContentType(name)
  )

type
  BlobPropertyBag = object of JSDict
    `type` {.jsdefault.}: string
    #TODO endings

  FilePropertyBag = object of BlobPropertyBag
    #TODO lastModified: int64

proc deallocBlob*(blob: Blob) =
  if blob.buffer != nil:
    dealloc(blob.buffer)
    blob.buffer = nil

proc newWebFile(ctx: JSContext; fileBits: seq[string]; fileName: string;
    options = FilePropertyBag()): WebFile {.jsctor.} =
  let file = WebFile(
    name: fileName
  )
  var len = 0
  for blobPart in fileBits:
    len += blobPart.len
  let buffer = alloc(len)
  file.buffer = buffer
  file.deallocFun = deallocBlob
  var buf = cast[ptr UncheckedArray[uint8]](file.buffer)
  var i = 0
  for blobPart in fileBits:
    if blobPart.len > 0:
      copyMem(addr buf[i], unsafeAddr blobPart[0], blobPart.len)
      i += blobPart.len
  file.size = uint64(len)
  block ctype:
    for c in options.`type`:
      if c notin char(0x20)..char(0x7E):
        break ctype
      file.ctype &= c.toLowerAscii()
  return file

#TODO File, Blob constructors

proc getSize*(this: Blob): uint64 =
  if this.fd.isSome:
    var statbuf: Stat
    if fstat(this.fd.get, statbuf) < 0:
      return 0
    return uint64(statbuf.st_size)
  return this.size

proc size*(this: WebFile): uint64 {.jsfget.} =
  return this.getSize()

#TODO lastModified

proc addBlobModule*(ctx: JSContext) =
  let blobCID = ctx.registerType(Blob)
  ctx.registerType(WebFile, parent = blobCID, name = "File")
