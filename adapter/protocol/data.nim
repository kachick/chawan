when NimMajor >= 2:
  import std/envvars
else:
  import std/os
import std/strutils

import loader/connecterror
import types/opt
import utils/twtstr

proc main() =
  let str = getEnv("MAPPED_URI_PATH")
  const iu = $int(ERROR_INVALID_URL)
  var ct = str.until(',')
  if AllChars - Ascii + Controls - {'\t', ' '} in ct:
    stdout.write("Cha-Control: ConnectionError " & iu  & " invalid data URL")
    return
  let sd = ct.len + 1 # data start
  let body = percentDecode(str, sd)
  if ct.endsWith(";base64"):
    let d = atob0(body) # decode from ct end + 1
    if d.isSome:
      ct.setLen(ct.len - ";base64".len) # remove base64 indicator
      stdout.write("Content-Type: " & ct & "\n\n")
      stdout.write(d.get)
    else:
      stdout.write("Cha-Control: ConnectionError " & iu  & " invalid data URL")
  else:
    stdout.write("Content-Type: " & ct & "\n\n")
    stdout.write(body)

main()
