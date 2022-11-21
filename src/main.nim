import options
import os
import terminal

when defined(profile):
  import nimprof

import config/config
import display/client
import utils/twtstr

let conf = readConfig()
let params = commandLineParams()

proc version(long: static bool = false): string =
  result = "Chawan browser v0.1 "
  when defined(debug):
    result &= "(debug)"
  else:
    result &= "(release)"

proc help(i: int) =
  let s = version() & """

Usage: cha [options] [URL(s) or file(s)...]
Options:
    -d, --dump                  Print page to stdout
    -c, --css <stylesheet>      Pass stylesheet (e.g. -c 'a{color: blue}')
    -o, --opt <config>          Pass config options (e.g. -o 'page.q="QUIT"')
    -T, --type <type>           Specify content mime type
    -v, --version               Print version information
    -h, --help                  Print this page
    --                          Interpret all following arguments as URLs"""
  if i == 0:
    echo s
  else:
    eprint s
  quit(i)

var i = 0
var ctype = none(string)
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
    echo version(true)
    quit(0)
  of "-T":
    inc i
    if i < params.len:
      ctype = some(params[i])
    else:
      help(1)
  of "-":
    discard # emulate programs that accept - as stdin
  of "-d", "--dump":
    dump = true
  of "-c", "--css":
    inc i
    if i < params.len:
      conf.stylesheet &= params[i]
    else:
      help(1)
  of "-o", "--opt":
    inc i
    if i < params.len:
      conf.parseConfig(getCurrentDir(), params[i])
    else:
      help(1)
  of "-h",  "--help":
    help(0)
  of "-r", "--run":
    inc i
    if i < params.len:
      conf.startup = params[i]
      dump = true
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

if pages.len == 0 and conf.startup == "":
  if stdin.isatty:
    help(1)

conf.nmap = constructActionTable(conf.nmap)
conf.lemap = constructActionTable(conf.lemap)

width_table = makewidthtable(conf.ambiguous_double)

newClient(conf).launchClient(pages, ctype, dump)
