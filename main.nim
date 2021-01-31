import httpClient
import uri
import os
import streams

import fusion/htmlparser
import fusion/htmlparser/xmltree

import display
import termattrs
import buffer
import twtio
import config
import twtstr
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
    #return nparseHtml(getRemotePage($moduri))
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
  buffer.document = nparseHtml(getPageUri(uri))
  buffer.setLocation(uri)
  buffer.nrenderHtml()
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
        buffer.document = nparseHtml(getPageUri(buffer.document.location))
      buffer.nrenderHtml()
    lastUri = newUri

#waitFor loadPage("https://lite.duckduckgo.com/lite/?q=hello%20world")
#eprint mk_wcswidth_cjk("abc•de")
main()
