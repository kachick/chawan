# Percent-encode input received on stdin with a specified percent-encoding set.
#TODO a streaming implementation of this could be useful

import std/os

import utils/twtstr

proc usage() =
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

proc main() =
  if paramCount() != 1:
    usage()
    quit(1)
  let s = stdin.readAll()
  let enc = case paramStr(1)
  of "control": percentEncode(s, ControlPercentEncodeSet)
  of "fragment": percentEncode(s, FragmentPercentEncodeSet)
  of "query": percentEncode(s, QueryPercentEncodeSet)
  of "path": percentEncode(s, PathPercentEncodeSet)
  of "userinfo": percentEncode(s, UserInfoPercentEncodeSet)
  of "component": percentEncode(s, ComponentPercentEncodeSet)
  of "application-x-www-form-urlencoded":
    percentEncode(s, ApplicationXWWWFormUrlEncodedSet)
  else:
    usage()
    quit(1)
  stdout.write(enc)

main()
