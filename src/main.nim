import version

import server/forkserver
let forks = newForkServer()

import std/options
import std/os

import config/chapath
import config/config
import display/term
import io/serversocket
import local/client
import types/opt
import utils/strwidth
import utils/twtstr

import chagashi/charset

proc main() =
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
    -c, --css <stylesheet>      Pass stylesheet (e.g. -c 'a{color: blue}')
    -d, --dump                  Print page to stdout
    -h, --help                  Print this usage message
    -o, --opt <config>          Pass config options (e.g. -o 'page.q="quit()"')
    -r, --run <script/file>     Run passed script or file
    -v, --version               Print version information
    -C, --config <file>         Override config path
    -I, --input-charset <enc>   Specify document charset
    -M, --monochrome            Set color-mode to 'monochrome'
    -O, --display-charset <enc> Specify display charset
    -T, --type <type>           Specify content mime type
    -V, --visual                Visual startup mode"""

    if i == 0:
      stdout.write(s & '\n')
    else:
      stderr.write(s & '\n')
    quit(i)

  var ctype = none(string)
  var cs = CHARSET_UNKNOWN
  var pages: seq[string]
  var dump = false
  var visual = false
  var escape_all = false
  var opts: seq[string]
  var stylesheet = ""
  var configPath = none(string)

  var i = 0
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

    proc pconfig() =
      configPath = some(getnext())

    proc pversion() =
      echo version(true)
      quit(0)

    proc pmonochrome() =
      opts.add("display.color-mode = monochrome")

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
      opts.add("encoding.display-charset = '" & $pgetCharset() & "'")

    proc pdump() =
      dump = true

    proc pcss() =
      stylesheet &= getnext()

    proc popt() =
      opts.add(getnext())

    proc phelp() =
      help(0)

    proc prun() =
      let script = dqEscape(getnext())
      opts.add("start.startup-script = \"\"\"" & script & "\"\"\"")
      opts.add("start.headless = true")
      dump = true

    if param.len == 0:
      inc i
      continue

    const NeedsNextParam = {'C', 'I', 'O', 'T', 'c', 'o', 'r'}

    if param[0] == '-':
      if param.len == 1:
        # If param == "-", i.e. it is a single dash, then ignore it.
        # (Some programs use single-dash to read from stdin, but we do that
        # automatically when stdin is not a tty. So ignoring it entirely
        # is probably for the best.)
        inc i
        continue
      if param[1] != '-':
        for j in 1 ..< param.len:
          if j != param.high and param[j] in NeedsNextParam:
            # expecting next parameter, but not the last char...
            help(1)
          case param[j]
          of 'C': pconfig()
          of 'I': pinput_charset()
          of 'M': pmonochrome()
          of 'O': poutput_charset()
          of 'T': ptype()
          of 'V': pvisual()
          of 'c': pcss()
          of 'd': pdump()
          of 'h': phelp()
          of 'o': popt()
          of 'r': prun()
          of 'v': pversion()
          else: help(1)
      else:
        case param
        of "--config": pconfig()
        of "--input-charset": pinput_charset()
        of "--monochrome": pmonochrome()
        of "--output-charset": poutput_charset()
        of "--type": ptype()
        of "--visual": pvisual()
        of "--css": pcss()
        of "--dump": pdump()
        of "--help": phelp()
        of "--opt": popt()
        of "--run": prun()
        of "--version": pversion()
        of "--": escape_all = true
        else: help(1)
    else:
      pages.add(param)
    inc i

  let config = readConfig(configPath)
  for opt in opts:
    config.parseConfig(getCurrentDir(), opt, laxnames = true)
  config.css.stylesheet &= stylesheet

  set_cjk_ambiguous(config.display.double_width_ambiguous)

  if pages.len == 0 and stdin.isatty():
    if visual:
      pages.add(config.start.visual_home)
    else:
      let http = getEnv("HTTP_HOME")
      if http != "": pages.add(http)
      else:
        let www = getEnv("WWW_HOME")
        if www != "": pages.add(www)

  if pages.len == 0 and not config.start.headless:
    if stdin.isatty:
      help(1)

  forks.loadForkServerConfig(config)
  let tmpdir0 = config.external.tmpdir.unquote()
  if tmpdir0.isErr:
    stderr.write("Error unquoting external.tmpdir: " & tmpdir0.error)
    stderr.write("Exiting...")
    quit(1)
  SocketDirectory = tmpdir0.get

  let c = newClient(config, forks)
  try:
    c.launchClient(pages, ctype, cs, dump)
  except CatchableError:
    c.flushConsole()
    raise

main()
