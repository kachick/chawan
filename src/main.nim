import types/dispatcher
let disp = newDispatcher()

import options
import os
import terminal

when defined(profile):
  import nimprof

import config/config
import data/charset
import display/client
import ips/forkserver
import utils/twtstr

let conf = readConfig()
set_cjk_ambiguous(conf.display.double_width_ambiguous)
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
    --                          Interpret all following arguments as URLs
    -d, --dump                  Print page to stdout
    -c, --css <stylesheet>      Pass stylesheet (e.g. -c 'a{color: blue}')
    -o, --opt <config>          Pass config options (e.g. -o 'page.q="QUIT"')
    -T, --type <type>           Specify content mime type
    -I, --input-charset <enc>   Specify document charset
    -O, --display-charset <enc> Specify display charset
    -M, --monochrome            Set color-mode to 'monochrome'
    -V, --visual                Visual startup mode
    -r, --run <script/file>     Run passed script or file
    -h, --help                  Print this usage message
    -v, --version               Print version information"""
  if i == 0:
    stdout.write(s & '\n')
  else:
    stderr.write(s & '\n')
  quit(i)

var i = 0
var ctype = none(string)
var cs = none(Charset)
var pages: seq[string]
var dump = false
var visual = false
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
  of "-M", "--monochrome":
    conf.display.colormode = some(MONOCHROME)
  of "-V", "--visual":
    visual = true
  of "-T", "--type":
    inc i
    if i < params.len:
      ctype = some(params[i])
    else:
      help(1)
  of "-I", "--input-charset":
    inc i
    if i < params.len:
      let c = getCharset(params[i])
      if c == CHARSET_UNKNOWN:
        stderr.write("Unknown charset " & params[i] & "\n")
        quit(1)
      cs = some(c)
    else:
      help(1)
  of "-O", "--output-charset":
    inc i
    if i < params.len:
      let c = getCharset(params[i])
      if c == CHARSET_UNKNOWN:
        stderr.write("Unknown charset " & params[i] & "\n")
        quit(1)
      conf.encoding.display_charset = some(c)
    else:
      help(1)
  of "-":
    discard # emulate programs that accept - as stdin
  of "-d", "-dump", "--dump":
    dump = true
  of "-c", "--css":
    inc i
    if i < params.len:
      conf.css.stylesheet &= params[i]
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
      conf.start.startup_script = params[i]
      conf.start.headless = true
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

if pages.len == 0 and stdin.isatty():
  if visual:
    pages.add(conf.start.visual_home)
  else:
    let http = getEnv("HTTP_HOME")
    if http != "": pages.add(http)
    else:
      let www = getEnv("WWW_HOME")
      if www != "": pages.add(www)

if pages.len == 0 and not conf.start.headless:
  if stdin.isatty:
    help(1)

conf.page = constructActionTable(conf.page)
conf.line = constructActionTable(conf.line)
disp.forkserver.loadForkServerConfig(conf)

let c = newClient(conf, disp)
try:
  c.launchClient(pages, ctype, cs, dump)
except CatchableError:
  c.flushConsole()
  raise
