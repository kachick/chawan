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
  doAssert open(file, path, fmRead) #TODO bleh
  return WebFile(
    isfile: true,
    path: path,
    file: file,
    webkitRelativePath: webkitRelativePath
  )

#TODO File, Blob constructors

func size*(this: WebFile): uint64 {.jsfget.} =
  #TODO use stat instead
  return uint64(this.file.getFileSize())

func ctype*(this: WebFile): string {.jsfget: "type".} =
  return guessContentType(this.path)

func name*(this: WebFile): string {.jsfget.} =
  if this.path.len > 0 and this.path[^1] != '/':
    return this.path.afterLast('/')
  return this.path.afterLast('/', 2)

#TODO lastModified

proc addBlobModule*(ctx: JSContext) =
  ctx.registerType(Blob)
  ctx.registerType(WebFile, name = "File")
