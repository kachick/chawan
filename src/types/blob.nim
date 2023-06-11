import options

import js/javascript
import types/mime
import utils/twtstr

type
  DeallocFun = proc(buffer: pointer) {.noconv.}

  Blob* = ref object of RootObj
    isfile*: bool
    size* {.jsget.}: uint64
    ctype* {.jsget: "type".}: string
    buffer*: pointer
    deallocFun*: DeallocFun

  WebFile* = ref object of Blob
    webkitRelativePath {.jsget.}: string
    path*: string
    file: File #TODO maybe use fd?

proc newBlob*(buffer: pointer, size: int, ctype: string,
    deallocFun: DeallocFun): Blob =
  return Blob(
    buffer: buffer,
    size: uint64(size),
    ctype: ctype,
    deallocFun: deallocFun
  )

proc finalize(blob: Blob) {.jsfin.} =
  if blob.deallocFun != nil and blob.buffer != nil:
    blob.deallocFun(blob.buffer)

proc newWebFile*(path: string, webkitRelativePath = ""): WebFile =
  var file: File
  if not open(file, path, fmRead):
    raise newException(IOError, "Failed to open file")
  return WebFile(
    isfile: true,
    path: path,
    file: file,
    ctype: guessContentType(path),
    webkitRelativePath: webkitRelativePath
  )

proc newWebFile(ctx: JSContext, fileBits: seq[string], fileName: string,
    options = none(JSValue)): WebFile {.jsctor.} =
  let file = WebFile(
    isfile: false,
    path: fileName,
    deallocFun: dealloc
  )
  var len = 0
  for blobPart in fileBits:
    len += blobPart.len
  file.buffer = alloc(len)
  var buf = cast[ptr UncheckedArray[uint8]](file.buffer)
  var i = 0
  for blobPart in fileBits:
    if blobPart.len > 0:
      copyMem(addr buf[i], unsafeAddr blobPart[0], blobPart.len)
      i += blobPart.len
  file.size = uint64(len)
  if options.isSome:
    block ctype:
      let t = fromJS[string](ctx, JS_GetPropertyStr(ctx, options.get, "type"))
      if t.isNone:
        break ctype
      for c in t.get:
        if c notin char(0x20)..char(0x7E):
          break ctype
        file.ctype &= c.tolower()
    #TODO lastmodified
  return file

#TODO File, Blob constructors

func size*(this: WebFile): uint64 {.jsfget.} =
  #TODO use stat instead
  if this.isfile:
    return uint64(this.file.getFileSize())
  return this.size

func name*(this: WebFile): string {.jsfget.} =
  if this.path.len > 0 and this.path[^1] != '/':
    return this.path.afterLast('/')
  return this.path.afterLast('/', 2)

#TODO lastModified

proc addBlobModule*(ctx: JSContext) =
  let blobCID = ctx.registerType(Blob)
  ctx.registerType(WebFile, parent = blobCID, name = "File")
