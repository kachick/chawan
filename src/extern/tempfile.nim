import std/os

var tmpf_seq: int
proc getTempFile*(tmpdir: string, ext = ""): string =
  if not dirExists(tmpdir):
    createDir(tmpdir)
  var tmpf = tmpdir / "chatmp" & $tmpf_seq
  if ext != "":
    tmpf &= "."
    tmpf &= ext
  while fileExists(tmpf):
    inc tmpf_seq
    tmpf = tmpdir / "chatmp" & $tmpf_seq
    if ext != "":
      tmpf &= "."
      tmpf &= ext
  inc tmpf_seq
  return tmpf
