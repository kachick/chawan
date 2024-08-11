# Percent-encode or decode input received on stdin with a specified
# percent-encoding set.
#TODO a streaming implementation of this could be useful

import std/os

import utils/twtstr

proc usage() {.noreturn.} =
  stderr.write("""
Usage: urlenc [set]
The input to be decoded is read from stdin.
[set] decides which characters are encoded. It can be:
    control
    fragment
    query
    path
    userinfo
    component
    application-x-www-form-urlencoded
""")
  quit(1)

proc main() =
  let isdec = paramStr(0).afterLast('/') == "urldec"
  if not isdec and paramCount() != 1:
    usage()
  let s = stdin.readAll()
  if isdec:
    stdout.write(s.percentDecode())
  else:
    let set = case paramStr(1)
    of "control": ControlPercentEncodeSet
    of "fragment": FragmentPercentEncodeSet
    of "query": QueryPercentEncodeSet
    of "path": PathPercentEncodeSet
    of "userinfo": UserInfoPercentEncodeSet
    of "component": ComponentPercentEncodeSet
    of "application-x-www-form-urlencoded": ApplicationXWWWFormUrlEncodedSet
    else: usage()
    stdout.write(s.percentEncode(set))

main()
