when NimMajor >= 2:
  import std/envvars
else:
  import std/os
import std/base64
import std/strutils

import loader/connecterror
import utils/twtstr

proc main() =
  let str = getEnv("MAPPED_URI_PATH")
  const si = "data:".len # start index
  const iu = $int(ERROR_INVALID_URL)
  var ct = str.until(',', si)
  for c in ct:
    if c notin AsciiAlphaNumeric and c != '/':
      stdout.write("Cha-Control: ConnectionError " & iu  & " invalid data URL")
      return
  let sd = si + ct.len + 1 # data start
  let body = percentDecode(str, sd)
  if ct.endsWith(";base64"):
    try:
      let d = base64.decode(body) # decode from ct end + 1
      ct.setLen(ct.len - ";base64".len) # remove base64 indicator
      stdout.write("Content-Type: " & ct & "\n\n")
      stdout.write(d)
    except ValueError:
      stdout.write("Cha-Control: ConnectionError " & iu  & " invalid data URL")
  else:
    stdout.write("Content-Type: " & ct & "\n\n")
    stdout.write(body)

main()
