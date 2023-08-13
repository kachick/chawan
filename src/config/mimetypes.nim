import streams
import tables

import utils/twtstr

# extension -> type
type MimeTypes* = Table[string, string]

# Add mime types found in stream to mimeTypes.
# No error handling for now.
proc parseMimeTypes*(mimeTypes: var MimeTypes, stream: Stream) =
  while not stream.atEnd():
    let line = stream.readLine()
    if line.len == 0:
      continue
    if line[0] == '#':
      continue
    var t = ""
    var i = 0
    while i < line.len and line[i] notin AsciiWhitespace:
      t &= line[i].tolower()
      inc i
    if t == "": continue
    while i < line.len:
      while i < line.len and line[i] in AsciiWhitespace:
        inc i
      var ext = ""
      while i < line.len and line[i] notin AsciiWhitespace:
        ext &= line[i].tolower()
        inc i
      if ext == "": continue
      discard mimeTypes.hasKeyOrPut(ext, t)
  stream.close()

proc parseMimeTypes*(stream: Stream): MimeTypes =
  var mimeTypes: MimeTypes
  mimeTypes.parseMimeTypes(stream)
  return mimeTypes
