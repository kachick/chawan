import httpclient
import uri
import os
import streams
import terminal
when defined(profile):
  import nimprof

import html/parser
import io/buffer
import io/term
import config/config
import utils/twtstr

let clientInstance = newHttpClient()
proc loadRemotePage*(url: string): string =
  return clientInstance.getContent(url)

proc loadLocalPage*(url: string): string =
  return readFile(url)

proc getRemotePage*(url: string): Stream =
  return clientInstance.get(url).bodyStream

proc getLocalPage*(url: string): Stream =
  return newFileStream(url, fmRead)

proc getPageUri(uri: Uri): Stream =
  var moduri = uri
  moduri.anchor = ""
  if uri.scheme == "" or uri.scheme == "file":
    return getLocalPage($moduri)
  else:
    return getRemotePage($moduri)

var buffers: seq[Buffer]

proc die() =
  eprint "Invalid parameters. Usage:\ntwt <url>"
  quit(1)

proc main*() =
  let attrs = getTermAttributes()
  let buffer = newBuffer(attrs)
  buffers.add(buffer)

  var lastUri: Uri
  if paramCount() < 1:
    if not isatty(stdin):
      try:
        while true:
          buffer.source &= stdin.readChar()
      except EOFError:
        #TODO handle failure (also, is this even portable at all?)
        discard reopen(stdin, "/dev/tty", fmReadWrite);
    else:
      die()
    buffer.setLocation(lastUri)
  else: 
    lastUri = parseUri(paramStr(1))
    buffer.source = getPageUri(lastUri).readAll() #TODO get rid of this

  buffer.setLocation(lastUri)
  buffer.document = parseHtml(newStringStream(buffer.source))
  buffer.renderDocument()
  while displayPage(attrs, buffer):
    buffer.setStatusMessage("Loading...")
    var newUri = buffer.location
    lastUri.anchor = ""
    newUri.anchor = ""
    if $lastUri != $newUri:
      buffer.clearBuffer()
      if lastUri.scheme == "" and lastUri.path == "" and lastUri.anchor != "":
        discard
      else:
        buffer.document = parseHtml(getPageUri(buffer.location))
      buffer.renderPlainText(getPageUri(lastUri).readAll())
    lastUri = newUri

readConfig()
width_table = makewidthtable(gconfig.ambiguous_double)
main()
