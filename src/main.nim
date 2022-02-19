import os
import terminal

when defined(profile):
  import nimprof

import client
import config/config
import utils/twtstr

readConfig()
let params = commandLineParams()

proc help(i: int) =
  let s =  """
Usage: cha [options] [URL(s) or file(s)...]
Options:
    -d, --dump                  Print page to stdout
    -c, --css <stylesheet>      Pass stylesheet (e.g. -c 'a{color: blue}')
    -o, --opt <config>          Pass config options (e.g. -o 'page.q="QUIT"')
    -T, --type <type>           Specify content mime type
    -v, --version               Print version information
    -h, --help                  Print this page
    --                          Interpret all following arguments as URLs/files"""
  if i == 0:
    echo s
  else:
    eprint s
  quit(i)

var i = 0
var ctype = ""
var pages: seq[string]
var dump = false
var escape_all = false
while i < params.len:
  let param = params[i]
  if escape_all: # after --
    pages.add(param)
    inc i
    continue
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
    discard # emulate programs that accept - as stdin
  of "-d", "--dump":
    dump = true
  of "-c", "--css":
    inc i
    if i < params.len:
      gconfig.stylesheet &= params[i]
    else:
      help(1)
  of "-o", "--opt":
    inc i
    if i < params.len:
      gconfig.parseConfig(getCurrentDir(), params[i])
    else:
      help(1)
  of "--":
    escape_all = true
  elif param.len > 0:
    if param[0] == '-':
      help(1)
    else:
      pages.add(param)
  inc i

if pages.len == 0:
  if stdin.isatty:
    help(1)

gconfig.nmap = constructActionTable(gconfig.nmap)
gconfig.lemap = constructActionTable(gconfig.lemap)

width_table = makewidthtable(gconfig.ambiguous_double)

newClient().launchClient(pages, ctype, dump)
