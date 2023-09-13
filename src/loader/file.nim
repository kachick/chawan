import algorithm
import os
import streams
import tables

import loader/connecterror
import loader/headers
import loader/loaderhandle
import types/url

proc loadDir(handle: LoaderHandle, url: URL, path: string) =
  template t(body: untyped) =
    if not body:
      return
  var path = path
  if path[^1] != '/': #TODO dos/windows
    path &= '/'
  var base = $url
  if base[^1] != '/': #TODO dos/windows
    base &= '/'
  t handle.sendResult(0)
  t handle.sendStatus(200) # ok
  t handle.sendHeaders(newHeaders({"Content-Type": "text/html"}.toTable()))
  t handle.sendData("""
<HTML>
<HEAD>
<BASE HREF="""" & base & """">
<TITLE>Directory list of """ & path & """</TITLE>
</HEAD>
<BODY>
<H1>Directory list of """ & path & """</H1>
[DIR]&nbsp; <A HREF="../">../</A></br>
""")
  var fs: seq[(PathComponent, string)]
  for pc, file in walkDir(path, relative = true):
    fs.add((pc, file))
  fs.sort(cmp = proc(a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
  for (pc, file) in fs:
    case pc
    of pcDir:
      t handle.sendData("[DIR]&nbsp; ")
    of pcFile:
      t handle.sendData("[FILE] ")
    of pcLinkToDir, pcLinkToFile:
      t handle.sendData("[LINK] ")
    var fn = file
    if pc == pcDir:
      fn &= '/'
    t handle.sendData("<A HREF=\"" & fn & "\">" & fn & "</A>")
    if pc in {pcLinkToDir, pcLinkToFile}:
      discard handle.sendData(" -> " & expandSymlink(path / file))
    t handle.sendData("<br>")
  t handle.sendData("""
</BODY>
</HTML>""")

proc loadSymlink(handle: LoaderHandle, path: string) =
  template t(body: untyped) =
    if not body:
      return
  t handle.sendResult(0)
  t handle.sendStatus(200) # ok
  t handle.sendHeaders(newHeaders({"Content-Type": "text/html"}.toTable()))
  let sl = expandSymlink(path)
  t handle.sendData("""
<HTML>
<HEAD>
<TITLE>Symlink view<TITLE>
</HEAD>
<BODY>
Symbolic link to <A HREF="""" & sl & """">""" & sl & """</A></br>
</BODY>
</HTML>""")

proc loadFile(handle: LoaderHandle, istream: Stream) =
  template t(body: untyped) =
    if not body:
      return
  t handle.sendResult(0)
  t handle.sendStatus(200) # ok
  t handle.sendHeaders(newHeaders())
  while not istream.atEnd:
    const bufferSize = 4096
    var buffer {.noinit.}: array[bufferSize, char]
    while true:
      let n = readData(istream, addr buffer[0], bufferSize)
      if n == 0:
        break
      t handle.sendData(addr buffer[0], n)
      if n < bufferSize:
        break

proc loadFilePath*(handle: LoaderHandle, url: URL) =
  when defined(windows) or defined(OS2) or defined(DOS):
    let path = url.path.serialize_unicode_dos()
  else:
    let path = url.path.serialize_unicode()
  let istream = newFileStream(path, fmRead)
  if istream == nil:
    if dirExists(path):
      handle.loadDir(url, path)
    elif symlinkExists(path):
      handle.loadSymlink(path)
    else:
      discard handle.sendResult(ERROR_FILE_NOT_FOUND)
  else:
    handle.loadFile(istream)
