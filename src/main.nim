import os
import terminal

when defined(profile):
  import nimprof

import client
import config/config
import utils/twtstr

readConfig()
width_table = makewidthtable(gconfig.ambiguous_double)
let params = commandLineParams()

proc help(i: int) =
  let s =  """
Usage: cha [options] [URL(s) or file(s)...]
Options:
    -T, --type <type>           Specify content mime type
    -v, --version               Print version information
    -h, --help                  Print this page"""
  if i == 0:
    echo s
  else:
    eprint s
  quit(i)

var i = 0
var ctype = ""
var pages: seq[string]
var dump = false
while i < params.len:
  let param = params[i]
  case param
  of "-v", "--version":
    echo "Chawan browser v0.1 ",
         when defined(debug): "(debug)" else: "(release)"
    quit(0)
  of "-T":
    inc i
    if i < params.len:
      ctype = params[i]
    else:
      help(1)
  of "-":
    discard
  of "-dump":
    dump = true
  elif param[0] == '-':
    help(1)
  else:
    pages.add(param)
  inc i

if params.len == 0:
  if stdin.isatty:
    help(1)

newClient().launchClient(pages, ctype, dump)
