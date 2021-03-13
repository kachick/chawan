import httpClient
import uri
import os
import streams

import display
import termattrs
import buffer
import twtio
import config
import parser

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

proc main*() =
  if paramCount() != 1:
    eprint "Invalid parameters. Usage:\ntwt <url>"
    quit(1)
  if not readConfig("config"):
    eprint "Failed to read keymap, falling back to default"
  let attrs = getTermAttributes()
  let buffer = newBuffer(attrs)
  let uri = parseUri(paramStr(1))
  buffers.add(buffer)
  buffer.document = parseHtml(getPageUri(uri))
  buffer.setLocation(uri)
  buffer.renderHtml()
  var lastUri = uri
  while displayPage(attrs, buffer):
    statusMsg("Loading...", buffer.height)
    var newUri = buffer.document.location
    lastUri.anchor = ""
    newUri.anchor = ""
    if $lastUri != $newUri:
      buffer.clearBuffer()
      if uri.scheme == "" and uri.path == "" and uri.anchor != "":
        discard
      else:
        buffer.document = parseHtml(getPageUri(buffer.document.location))
      buffer.renderHtml()
    lastUri = newUri

main()
#parseCSS(newFileStream("default.css", fmRead))
