import std/streams
import std/strutils

import js/javascript
import types/blob
import utils/twtstr

type
  FormDataEntry* = object
    name*: string
    filename*: string
    case isstr*: bool
    of true:
      svalue*: string
    of false:
      value*: Blob

  FormData* = ref object
    entries*: seq[FormDataEntry]
    boundary*: string

jsDestructor(FormData)

iterator items*(this: FormData): FormDataEntry {.inline.} =
  for entry in this.entries:
    yield entry

proc calcLength*(this: FormData): int =
  result = 0
  for entry in this.entries:
    result += "--\r\n".len + this.boundary.len # always have boundary
    #TODO maybe make CRLF for name first?
    result += entry.name.len # always have name
    # these must be percent-encoded, with 2 char overhead:
    result += entry.name.count({'\r', '\n', '"'}) * 2
    if entry.isstr:
      result += "Content-Disposition: form-data; name=\"\"\r\n".len
      result += entry.svalue.len
    else:
      result += "Content-Disposition: form-data; name=\"\";".len
      # file name
      result += " filename=\"\"\r\n".len
      result += entry.filename.len
      # dquot must be quoted with 2 char overhead
      result += entry.filename.count('"') * 2
      # content type
      result += "Content-Type: \r\n".len
      result += entry.value.ctype.len
      if entry.value.isfile:
        result += int(WebFile(entry.value).getSize())
      else:
        result += int(entry.value.size)
    result += "\r\n".len # header is always followed by \r\n
    result += "\r\n".len # value is always followed by \r\n

proc getContentType*(this: FormData): string =
  return "multipart/form-data; boundary=" & this.boundary

proc writeEntry*(stream: Stream, entry: FormDataEntry, boundary: string) =
  stream.write("--" & boundary & "\r\n")
  let name = percentEncode(entry.name, {'"', '\r', '\n'})
  if entry.isstr:
    stream.write("Content-Disposition: form-data; name=\"" & name & "\"\r\n")
    stream.write("\r\n")
    stream.write(entry.svalue)
  else:
    stream.write("Content-Disposition: form-data; name=\"" & name & "\";")
    let filename = percentEncode(entry.filename, {'"', '\r', '\n'})
    stream.write(" filename=\"" & filename & "\"\r\n")
    let blob = entry.value
    let ctype = if blob.ctype == "":
      "application/octet-stream"
    else:
      blob.ctype
    stream.write("Content-Type: " & ctype & "\r\n")
    if blob.isfile:
      let fs = newFileStream(WebFile(blob).path)
      if fs != nil:
        var buf {.noinit.}: array[4096, uint8]
        while true:
          let n = fs.readData(addr buf[0], 4096)
          stream.writeData(addr buf[0], n)
          if n != 4096: break
    else:
      stream.writeData(blob.buffer, int(blob.size))
    stream.write("\r\n")
  stream.write("\r\n")
