import std/algorithm
import std/os
import std/streams
import std/times

import dirlist

import loader/connecterror
import utils/twtstr

proc loadDir(path, opath: string) =
  var path = path
  if path[^1] != '/': #TODO dos/windows
    path &= '/'
  var base = "file://" & opath
  if base[^1] != '/': #TODO dos/windows
    base &= '/'
  stdout.write("Content-Type: text/html\n\n")
  stdout.write("""
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
        nsize: int(info.size)
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
  stdout.write(makeDirlist(items))
  stdout.write("\n</PRE>\n</BODY>\n</HTML>\n")

proc loadSymlink(path: string) =
  stdout.write("Content-Type: text/html\n\n")
  let sl = expandSymlink(path)
  stdout.write("""
<HTML>
<HEAD>
<TITLE>Symlink view<TITLE>
</HEAD>
<BODY>
Symbolic link to <A HREF="""" & sl & """">""" & sl & """</A></br>
</BODY>
</HTML>""")

proc loadFile(istream: Stream) =
  # No headers, we'll let the browser figure out the file type.
  stdout.write("\n")
  let outs = newFileStream(stdout)
  while not istream.atEnd:
    const BufferSize = 16384
    var buffer {.noinit.}: array[BufferSize, char]
    while true:
      let n = readData(istream, addr buffer[0], BufferSize)
      if n == 0:
        break
      outs.writeData(addr buffer[0], n)
      if n < BufferSize:
        break

proc main() =
  if getEnv("MAPPED_URI_HOST") != "":
      let code = int(ERROR_INVALID_URL)
      stdout.write("Cha-Control: ConnectionError " & $code &
        " cannot use host in file")
      return
  let opath = getEnv("MAPPED_URI_PATH")
  let path = percentDecode(opath)
  let istream = newFileStream(path, fmRead)
  if istream == nil:
    if dirExists(path):
      loadDir(path, opath)
    elif symlinkExists(path):
      loadSymlink(path)
    else:
      let code = int(ERROR_FILE_NOT_FOUND)
      stdout.write("Cha-Control: ConnectionError " & $code)
  else:
    loadFile(istream)

main()
