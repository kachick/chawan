import algorithm
import os
import streams
import tables
import times

import loader/connecterror
import loader/dirlist
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
<PRE>
""")
  var fs: seq[(PathComponent, string)]
  for pc, file in walkDir(path, relative = true):
    fs.add((pc, file))
  fs.sort(cmp = proc(a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
  var items: seq[DirlistItem]
  for (pc, file) in fs:
    let fullpath = path / file
    var info: FileInfo
    try:
      info = getFileInfo(fullpath, followSymlink = false)
    except OSError:
      continue
    let modified = $info.lastWriteTime.local().format("MMM/dd/yyyy HH:MM")
    case pc
    of pcDir:
      items.add(DirlistItem(
        t: ITEM_DIR,
        name: file,
        modified: modified
      ))
    of pcFile:
      items.add(DirlistItem(
        t: ITEM_FILE,
        name: file,
        modified: modified,
        nsize: info.size
      ))
    of pcLinkToDir, pcLinkToFile:
      var target = expandSymlink(fullpath)
      if pc == pcLinkToDir:
        target &= '/'
      items.add(DirlistItem(
        t: ITEM_LINK,
        name: file,
        modified: modified,
        linkto: target
      ))
  t handle.sendData(makeDirlist(items))
  t handle.sendData("\n</PRE>\n</BODY>\n</HTML>\n")

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
