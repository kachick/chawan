import httpClient
import uri
import os

import fusion/htmlparser
import fusion/htmlparser/xmltree

import display
import termattrs
import buffer
import twtio
import config

proc loadRemotePage*(url: string): string =
  return newHttpClient().getContent(url)

proc loadLocalPage*(url: string): string =
  return readFile(url)

proc loadPageUri(uri: Uri, currentcontent: XmlNode): XmlNode =
  var moduri = uri
  moduri.anchor = ""
  if uri.scheme == "" and uri.path == "" and uri.anchor != "" and currentcontent != nil:
    return currentcontent
  elif uri.scheme == "" or uri.scheme == "file":
    return parseHtml(loadLocalPage($moduri))
  else:
    return parseHtml(loadRemotePage($moduri))

var buffers: seq[Buffer]

proc main*() =
  if paramCount() != 1:
    eprint "Invalid parameters. Usage:\ntwt <url>"
    quit(1)
  if not readKeymap("keymap"):
    eprint "Failed to read keymap, falling back to default"
  let attrs = getTermAttributes()
  let buffer = newBuffer(attrs)
  let uri = parseUri(paramStr(1))
  buffers.add(buffer)
  buffer.setLocation(uri)
  buffer.htmlSource = loadPageUri(uri, buffer.htmlSource)
  buffer.renderHtml()
  var lastUri = uri
  while displayPage(attrs, buffer):
    statusMsg("Loading...", buffer.height)
    var newUri = buffer.document.location
    lastUri.anchor = ""
    newUri.anchor = ""
    if $lastUri != $newUri:
      buffer.clearBuffer()
      buffer.htmlSource = loadPageUri(buffer.document.location, buffer.htmlSource)
      buffer.renderHtml()
    lastUri = newUri

#waitFor loadPage("https://lite.duckduckgo.com/lite/?q=hello%20world")
main()
