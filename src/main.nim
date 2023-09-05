import version

import ips/forkserver
let forks = newForkServer()

import options
import os
import posix
import terminal

when defined(profile):
  import nimprof

import config/config
import display/client
import utils/opt
import utils/twtstr

import chakasu/charset

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
    -o, --opt <config>          Pass config options (e.g. -o 'page.q="quit()"')
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
var cs = CHARSET_UNKNOWN
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

  proc getnext(): string =
    inc i
    if i < params.len:
      return params[i]
    help(1)

  proc pversion() =
    echo version(true)
    quit(0)

  proc pmonochrome() =
    conf.display.colormode.ok(MONOCHROME)

  proc pvisual() =
    visual = true

  proc ptype() =
    ctype = some(getnext())

  proc pgetCharset(): Charset =
    let s = getnext()
    let cs = getCharset(s)
    if cs == CHARSET_UNKNOWN:
      stderr.write("Unknown charset " & s & "\n")
      quit(1)
    return cs

  proc pinput_charset() =
    cs = pgetCharset()

  proc poutput_charset() =
    conf.encoding.display_charset.ok(pgetCharset())

  proc pdump() =
    dump = true

  proc pcss() =
    conf.css.stylesheet &= getnext()

  proc popt() =
    conf.parseConfig(getCurrentDir(), getnext())

  proc phelp() =
    help(0)

  proc prun() =
    conf.start.startup_script = getnext()
    conf.start.headless = true
    dump = true

  if param.len == 0:
    inc i
    continue

  const NeedsNextParam = {'T', 'I', 'O', 'c', 'o', 'r'}

  if param[0] == '-':
    if param[1] != '-':
      # If param.len is 0, we just interpret param as a single dash `-',
      # which is ignored.
      # (Some programs use single-dash to read from stdin, but we do that
      # automatically when stdin is not a tty. So ignoring it entirely
      # is probably for the best.)
      for j in 1 ..< param.len:
        if j != param.high and param[j] in NeedsNextParam:
          # expecting next parameter, but not the last char...
          help(1)
        case param[j]
        of 'v': pversion()
        of 'M': pmonochrome()
        of 'V': pvisual()
        of 'T': ptype()
        of 'I': pinput_charset()
        of 'O': poutput_charset()
        of 'd': pdump()
        of 'c': pcss()
        of 'o': popt()
        of 'h': phelp()
        of 'r': prun()
        else: help(1)
    else:
      case param
      of "--version": pversion()
      of "--monochrome": pmonochrome()
      of "--visual": pvisual()
      of "--type": ptype()
      of "--input-charset": pinput_charset()
      of "--output-charset": poutput_charset()
      of "--dump": pdump()
      of "--css": pcss()
      of "--opt": popt()
      of "--help": phelp()
      of "--run": prun()
      of "--": escape_all = true
      else: help(1)
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

forks.loadForkServerConfig(conf)

let c = newClient(conf, forks, getpid())
try:
  c.launchClient(pages, ctype, cs, dump)
except CatchableError:
  c.flushConsole()
  raise
