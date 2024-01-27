import std/streams
import std/tables

import utils/twtstr

# extension -> type
type MimeTypes* = Table[string, string]

# Add mime types found in stream to mimeTypes.
# No error handling for now.
proc parseMimeTypes*(mimeTypes: var MimeTypes, stream: Stream) =
  var line: string
  while stream.readLine(line):
    if line.len == 0:
      continue
    if line[0] == '#':
      continue
    let t = line.untilLower(AsciiWhitespace)
    if t == "": continue
    var i = t.len
    while i < line.len:
      i = line.skipBlanks(i)
      let ext = line.untilLower(AsciiWhitespace, i)
      i += ext.len
      if ext != "":
        discard mimeTypes.hasKeyOrPut(ext, t)
  stream.close()

proc parseMimeTypes*(stream: Stream): MimeTypes =
  var mimeTypes: MimeTypes
  mimeTypes.parseMimeTypes(stream)
  return mimeTypes
