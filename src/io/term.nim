import os
import streams
import strutils
import terminal

import bindings/notcurses
import buffer/cell
import io/window
import types/color
import utils/twtstr

type
  ColorMode = enum
    MONOCHROME, ANSI, EIGHT_BIT, TRUE_COLOR

  FormatMode = set[FormatFlags]

  Terminal* = ref TerminalObj
  TerminalObj = object
    infile: File
    outfile: File
    nc*: ncdirect
    cleared: bool
    prevgrid: FixedGrid
    attrs*: WindowAttributes
    colormode: ColorMode
    formatmode: FormatMode
    smcup: bool

  TermInfo = ref object

proc `=destroy`(term: var TerminalObj) =
  if term.nc != nil:
    #discard ncdirect_stop(term.nc)
    term.nc = nil

template CSI*(s: varargs[string, `$`]): string =
  var r = "\e["
  var first = true
  for x in s:
    if not first:
      r &= ";"
    first = false
    r &= x
  r

template DECSET(s: varargs[string, `$`]): string =
  var r = "\e[?"
  var first = true
  for x in s:
    if not first:
      r &= ";"
    first = false
    r &= x
  r & "h"

template DECRST(s: varargs[string, `$`]): string =
  var r = "\e[?"
  var first = true
  for x in s:
    if not first:
      r &= ";"
    first = false
    r &= x
  r & "l"

template SMCUP(): string = DECSET(1049)
template RMCUP(): string = DECRST(1049)

template SGR*(s: varargs[string, `$`]): string =
  CSI(s) & "m"

template HVP*(s: varargs[string, `$`]): string =
  CSI(s) & "f"

template EL*(s: varargs[string, `$`]): string =
  CSI(s) & "K"

proc processFormat*(term: Terminal, format: var Format, cellf: Format): string =
  for flag in FormatFlags:
    if flag in format.flags and flag notin cellf.flags:
      result &= SGR(FormatCodes[flag].e)

  if cellf.fgcolor != format.fgcolor:
    var color = cellf.fgcolor
    if color.rgb:
      let rgb = color.rgbcolor
      result &= SGR(38, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      result &= SGR()
      format = newFormat()
    else:
      result &= SGR(color.color)

  if cellf.bgcolor != format.bgcolor:
    var color = cellf.bgcolor
    if color.rgb:
      let rgb = color.rgbcolor
      result &= SGR(48, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      result &= SGR()
      format = newFormat()
    else:
      result &= SGR(color.color)

  for flag in FormatFlags:
    if flag notin format.flags and flag in cellf.flags:
      result &= SGR(FormatCodes[flag].s)

  format = cellf

proc updateWindow*(term: Terminal) =
  term.attrs = getWindowAttributes(term.outfile)

proc findTermInfoDirs(termenv: string): seq[string] =
  let tienv = getEnv("TERMINFO")
  if tienv != "":
    if dirExists(tienv):
      return @[tienv]
  else:
    let home = getEnv("HOME")
    if home != "":
      result.add(home & '/' & ".terminfo")
  let tidirsenv = getEnv("TERMINFO_DIRS")
  if tidirsenv != "":
    for s in tidirsenv.split({':'}):
      if s == "":
        result.add("/usr/share/terminfo")
      else:
        result.add(s)
    return result
  result.add("/usr/share/terminfo")

proc findFile(dir: string, file: string): string =
  var stack = dir
  for f in walkDirRec(dir, followFilter = {pcDir, pcLinkToDir}):
    if f == file:
      return f

proc parseTermInfo(s: Stream): TermInfo =
  let magic = s.readInt16()
  #TODO do we really want this?
  s.close()

proc getTermInfo(termenv: string): TermInfo =
  let tipaths = findTermInfoDirs(termenv)
  for tipath in tipaths:
    let f = findFile(tipath, termenv)
    if f != "":
      return parseTermInfo(newFileStream(f))

proc getCursorPos(term: Terminal): (int, int) =
  term.outfile.write(CSI("6n"))
  term.outfile.flushFile()
  var c = term.infile.readChar()
  while true:
    while c != '\e':
      c = term.infile.readChar()
    c = term.infile.readChar()
    if c == '[': break
  var tmp = ""
  while (let c = term.infile.readChar(); c != ';'):
    tmp &= c
  result[1] = parseInt32(tmp)
  tmp = ""
  while (let c = term.infile.readChar(); c != 'R'):
    tmp &= c
  result[0] = parseInt32(tmp)

proc detectTermAttributes*(term: Terminal) =
  term.colormode = ANSI
  let colorterm = getEnv("COLORTERM")
  case colorterm
  of "24bit", "truecolor": term.colormode = TRUE_COLOR
  #TODO terminfo/termcap?

func generateFullOutput(term: Terminal, grid: FixedGrid): string =
  var x = 0
  var format = newFormat()
  result &= HVP(1, 1)
  for cell in grid.cells:
    if x >= grid.width - 1:
      result &= EL()
      result &= "\r\n"
      x = 0
    result &= term.processFormat(format, cell.format)
    result &= cell.str
    inc x
  result &= EL()

func generateSwapOutput(term: Terminal, grid: FixedGrid): string =
  var format = newFormat()
  let curr = grid.cells
  let prev = term.prevgrid.cells
  var i = 0
  var x = 0
  var y = 0
  var line = ""
  var lr = false
  while i < curr.len:
    if x >= grid.width - 1:
      if lr:
        result &= HVP(y + 1, 1)
        result &= EL()
        result &= line
        lr = false
      x = 0
      inc y
      line = ""
    lr = lr or (curr[i] != prev[i])
    line &= term.processFormat(format, curr[i].format)
    line &= curr[i].str
    inc i
    inc x
  if lr:
    result &= HVP(y + 1, 1)
    result &= EL()
    result &= line
    lr = false

proc hideCursor*(term: Terminal) =
  term.outfile.hideCursor()

proc showCursor*(term: Terminal) =
  term.outfile.showCursor()

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc outputGrid*(term: Terminal, grid: FixedGrid) =
  term.outfile.write(SGR())
  if not term.cleared:
    term.outfile.write(term.generateFullOutput(grid))
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput(grid))
  term.prevgrid = grid

proc setCursor*(term: Terminal, x, y: int) =
  term.outfile.write(HVP(y + 1, x + 1))

when defined(posix):
  import posix
  import termios

  # see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
  var orig_termios: Termios
  var stdin_fileno: FileHandle
  proc disableRawMode*() {.noconv.} =
    discard tcSetAttr(stdin_fileno, TCSAFLUSH, addr orig_termios)

  proc enableRawMode*(fileno: FileHandle) =
    stdin_fileno = fileno
    discard tcGetAttr(fileno, addr orig_termios)
    var raw = orig_termios
    raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    raw.c_oflag = raw.c_oflag and not (OPOST)
    raw.c_cflag = raw.c_cflag or CS8
    raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
    discard tcSetAttr(fileno, TCSAFLUSH, addr raw)

  var orig_flags: cint
  var stdin_unblocked = false
  proc unblockStdin*(fileno: FileHandle) =
    orig_flags = fcntl(fileno, F_GETFL, 0)
    let flags = orig_flags or O_NONBLOCK
    discard fcntl(fileno, F_SETFL, flags)
    stdin_unblocked = true

  proc restoreStdin*(fileno: FileHandle) =
    if stdin_unblocked:
      discard fcntl(fileno, F_SETFL, orig_flags)
      stdin_unblocked = false
else:
  proc unblockStdin*(): cint =
    discard

  proc restoreStdin*(flags: cint) =
    discard

proc isatty*(term: Terminal): bool =
  term.infile.isatty() and term.outfile.isatty()

proc quit*(term: Terminal) =
  if term.isatty():
    when defined(posix):
      disableRawMode()
    if term.smcup:
      term.outfile.write(RMCUP())
    else:
      term.outfile.write(HVP(term.attrs.height, 1) & '\n')
    term.outfile.showCursor()
  term.outfile.flushFile()

proc newTerminal*(infile, outfile: File, force_minimal = false): Terminal =
  let term = new Terminal
  term.infile = infile
  term.outfile = outfile
  when defined(posix):
    if term.isatty():
      enableRawMode(infile.getFileHandle())
  if not force_minimal:
    term.detectTermAttributes()
    term.smcup = true
    term.outfile.write(SMCUP())
  return term
