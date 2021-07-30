import httpClient
import uri
import os
import streams

import css/style

import utils/termattrs

import html/dom
import html/htmlparser

import io/display
import io/twtio

import buffer
import config

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
  if not readConfig("res/config"):
    eprint "Failed to read keymap, fallback to default"
  let attrs = getTermAttributes()
  let buffer = newBuffer(attrs)
  let uri = parseUri(paramStr(1))
  buffers.add(buffer)
  buffer.document = parseHtml(getPageUri(uri))
  let s = buffer.document.querySelector(":not(:first-child)")
  eprint s.len
  for q in s:
    eprint q
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
