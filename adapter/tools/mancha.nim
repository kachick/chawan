import std/os
import std/osproc

proc help(i: int) =
    let s = """
Usage:
mancha [-M path] [[-s] section] -k keyword
mancha [-M path] [[-s] section] name
mancha -l file"""
    if i == 0:
      stdout.write(s & '\n')
    else:
      stderr.write(s & '\n')
    quit(i)

var i = 1
let n = paramCount()

proc getnext(): string =
  inc i
  if i <= n:
    return paramStr(i)
  help(1)
  ""

proc main() =
  let n = paramCount()
  var section = ""
  var local = ""
  var man = ""
  var keyword = ""
  var forceSection = false
  while i <= n:
    let s = paramStr(i)
    if s == "":
      inc i
      continue
    let c = s[0]
    let L = s.len
    if c == '-':
      if s.len != 2:
        help(1)
      case s[1]
      of 'h': help(0)
      of 'M': putEnv("MANPATH", getnext())
      of 's':
        section = getnext()
        forceSection = true
      of 'l': local = getnext()
      of 'k': keyword = getnext()
      else: help(1)
    elif section == "" and (c in {'0'..'9'} or L == 1 and c in {'n', 'l', 'x'}):
      section = s
    elif man == "":
      man = s
    else:
      help(1)
    inc i
  if not forceSection and section != "" and man == "" and keyword == "" and
      local == "":
    man = section
    section = ""
  if not ((local != "") != (man != "") != (keyword != "")):
    help(1)
  if local != "" and section != "":
    help(1)
  let qsec = if section != "": '(' & section & ')' else: ""
  let query = if local != "":
    if local[0] == '~':
      local = expandTilde(local)
    elif local[0] != '/':
      local = (getCurrentDir() / local)
    "man-l:" & local
  elif keyword != "":
    "man-k:" & keyword & qsec
  else:
    "man:" & man & qsec
  var cha = getEnv("MANCHA_CHA")
  if cha == "":
    cha = "cha"
  quit(execCmd(cha & " " & quoteShellPosix(query)))

main()
