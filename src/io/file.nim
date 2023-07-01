import algorithm
import os
import streams
import tables

import io/headers
import ips/serialize
import types/url

proc loadDir(url: URL, path: string, ostream: Stream) =
  ostream.swrite(0)
  ostream.swrite(200) # ok
  ostream.swrite(newHeaders({"Content-Type": "text/html"}.toTable()))
  ostream.write("""
<HTML>
<HEAD>
<BASE HREF="""" & $url & """">
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
      ostream.write("[DIR]&nbsp; ")
    of pcFile:
      ostream.write("[FILE] ")
    of pcLinkToDir, pcLinkToFile:
      ostream.write("[LINK] ")
    var fn = file
    if pc == pcDir:
      fn &= '/'
    ostream.write("<A HREF=\"" & fn & "\">" & fn & "</A>")
    if pc in {pcLinkToDir, pcLinkToFile}:
      ostream.write(" -> " & expandSymlink(path / file))
    ostream.write("<br>")
  ostream.write("""
</BODY>
</HTML>""")
  ostream.flush()

proc loadSymlink(path: string, ostream: Stream) =
  ostream.swrite(0)
  ostream.swrite(200) # ok
  ostream.swrite(newHeaders({"Content-Type": "text/html"}.toTable()))
  let sl = expandSymlink(path)
  ostream.write("""
<HTML>
<HEAD>
<TITLE>Symlink view<TITLE>
</HEAD>
<BODY>
Symbolic link to <A HREF="""" & sl & """">""" & sl & """</A></br>
</BODY>
</HTML>""")
  ostream.flush()


proc loadFile*(url: URL, ostream: Stream) =
  when defined(windows) or defined(OS2) or defined(DOS):
    let path = url.path.serialize_unicode_dos()
  else:
    let path = url.path.serialize_unicode()
  let istream = newFileStream(path, fmRead)
  if istream == nil:
    if dirExists(path):
      loadDir(url, path, ostream)
    elif symlinkExists(path):
      loadSymlink(path, ostream)
    else:
      ostream.swrite(-1) # error
      ostream.flush()
  else:
    ostream.swrite(0)
    ostream.swrite(200) # ok
    ostream.swrite(newHeaders())
    while not istream.atEnd:
      const bufferSize = 4096
      var buffer {.noinit.}: array[bufferSize, char]
      while true:
        let n = readData(istream, addr buffer[0], bufferSize)
        if n == 0:
          break
        ostream.writeData(addr buffer[0], n)
        ostream.flush()
        if n < bufferSize:
          break
