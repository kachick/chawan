import math
import options
import os
import tables
import terminal

import bindings/termcap
import buffer/cell
import config/config
import io/window
import types/color
import utils/twtstr

#TODO switch from termcap...

type
  TermcapCap = enum
    ce # clear till end of line
    cd # clear display
    cm # cursor move
    ti # terminal init (=smcup)
    te # terminal end (=rmcup)
    so # start standout mode
    md # start bold mode
    us # start underline mode
    mr # start reverse mode
    mb # start blink mode
    ue # end underline mode
    se # end standout mode
    me # end all formatting modes

  Termcap = ref object
    bp: array[1024, uint8]
    funcstr: array[256, uint8]
    caps: array[TermcapCap, cstring]

  Terminal* = ref TerminalObj
  TerminalObj = object
    config: Config
    infile: File
    outfile: File
    cleared: bool
    prevgrid: FixedGrid
    attrs*: WindowAttributes
    colormode: ColorMode
    formatmode: FormatMode
    smcup: bool
    tc: Termcap
    tname: string

func hascap(term: Terminal, c: TermcapCap): bool = term.tc.caps[c] != nil
func cap(term: Terminal, c: TermcapCap): string = $term.tc.caps[c]
func ccap(term: Terminal, c: TermcapCap): cstring = term.tc.caps[c]

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

template HVP(s: varargs[string, `$`]): string =
  CSI(s) & "f"

template EL*(s: varargs[string, `$`]): string =
  CSI(s) & "K"

const ANSIColorMap = [
  ColorsRGB["black"],
  ColorsRGB["red"],
  ColorsRGB["green"],
  ColorsRGB["yellow"],
  ColorsRGB["blue"],
  ColorsRGB["magenta"],
  ColorsRGB["cyan"],
  ColorsRGB["white"],
]

var goutfile: File
proc putc(c: char): cint {.cdecl.} =
  goutfile.write(c)

proc write(term: Terminal, s: string) =
  when termcap_found:
    discard tputs(cstring(s), cint(s.len), putc)
  else:
    term.outfile.write(s)

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc cursorGoto(term: Terminal, x, y: int): string =
  when termcap_found:
    return $tgoto(term.ccap cm, cint(x), cint(y))
  else:
    return HVP(y, x)

proc clearEnd(term: Terminal): string =
  when termcap_found:
    return term.cap ce
  else:
    return EL()

proc resetFormat(term: Terminal): string =
  when termcap_found:
    return term.cap me
  else:
    return SGR()

#TODO get rid of this
proc eraseLine*(term: Terminal) =
  term.write(term.clearEnd())

#TODO ditto
proc resetFormat2*(term: Terminal) =
  term.write(term.resetFormat())

#TODO ditto
proc setCursor*(term: Terminal, x, y: int) =
  term.write(term.cursorGoto(x, y))

proc enableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap ti:
      term.write($term.cap ti)
  else:
    return SMCUP()

proc disableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap te:
      term.write($term.cap te)
  else:
    return RMCUP()

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(rgb: RGBColor, exclude = -1): int =
  var a = 0
  var n = -1
  for i in 0 .. ANSIColorMap.high:
    if i == exclude: continue
    let color = ANSIColorMap[i]
    if color == rgb: return i
    let b = (color.r - rgb.r) ^  2 + (color.g - rgb.b) ^ 2 + (color.g - rgb.g) ^ 2
    if n == -1 or b < a:
      n = i
      a = b
  return n

proc processFormat*(term: Terminal, format: var Format, cellf: Format): string =
  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag in format.flags and flag notin cellf.flags:
        result &= SGR(FormatCodes[flag].e)

  var cellf = cellf
  case term.colormode
  of ANSI, EIGHT_BIT:
    if cellf.bgcolor.rgb:
      let color = approximateANSIColor(cellf.bgcolor.rgbcolor)
      if color == 0: # black
        cellf.bgcolor = defaultColor
      else:
        cellf.bgcolor = ColorsANSIBg[color]
    if cellf.fgcolor.rgb:
      if cellf.bgcolor == defaultColor:
        var color = approximateANSIColor(cellf.fgcolor.rgbcolor)
        if color == 0:
          color = 7
        if color == 7: # white
          cellf.fgcolor = defaultColor
        else:
          cellf.fgcolor = ColorsANSIFg[color]
      else:
        cellf.fgcolor = if int(cellf.bgcolor.color) - 40 < 4:
          defaultColor
        else:
          ColorsANSIFg[7]
  of MONOCHROME:
    cellf.fgcolor = defaultColor
    cellf.bgcolor = defaultColor
  of TRUE_COLOR: discard

  if cellf.fgcolor != format.fgcolor:
    var color = cellf.fgcolor
    if color.rgb:
      let rgb = color.rgbcolor
      result &= SGR(38, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      result &= term.resetFormat()
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
    if flag in term.formatmode:
      if flag notin format.flags and flag in cellf.flags:
        result &= SGR(FormatCodes[flag].s)

  format = cellf

proc updateWindow*(term: Terminal) =
  term.attrs = getWindowAttributes(term.outfile)

proc getCursorPos(term: Terminal): (int, int) =
  term.write(CSI("6n"))
  term.flush()
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

func generateFullOutput(term: Terminal, grid: FixedGrid): string =
  var format = newFormat()
  result &= term.cursorGoto(0, 0)
  result &= SGR()
  for y in 0 ..< grid.height:
    for x in 0 ..< grid.width:
      let cell = grid[y * grid.width + x]
      result &= term.processFormat(format, cell.format)
      result &= cell.str
    result &= SGR()
    result &= term.clearEnd()
    result &= "\r\n"

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
    if x >= grid.width:
      if lr:
        result &= SGR()
        result &= term.cursorGoto(0, y)
        result &= term.clearEnd()
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
    result &= term.cursorGoto(0, y)
    result &= EL()
    result &= line
    lr = false

proc hideCursor*(term: Terminal) =
  term.outfile.hideCursor()

proc showCursor*(term: Terminal) =
  term.outfile.showCursor()

proc outputGrid*(term: Terminal, grid: FixedGrid) =
  term.outfile.write(SGR())
  if not term.cleared:
    term.outfile.write(term.generateFullOutput(grid))
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput(grid))
  term.prevgrid = grid

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
  if term.infile != nil and term.isatty():
    when defined(posix):
      disableRawMode()
    if term.smcup:
      term.write(term.disableAltScreen())
    else:
      term.write(term.cursorGoto(0, term.attrs.height - 1))
    term.outfile.showCursor()
  term.outfile.flushFile()

when termcap_found:
  proc loadTermcap(term: Terminal) =
    assert goutfile == nil
    goutfile = term.outfile
    let tc = new Termcap
    if tgetent(cast[cstring](addr tc.bp), cstring(term.tname)) == 1:
      term.tc = tc
      for id in TermcapCap:
        tc.caps[id] = tgetstr(cstring($id), cast[ptr cstring](addr tc.funcstr))
    else:
      raise newException(Defect, "Failed to load termcap description for terminal " & term.tname)

proc detectTermAttributes(term: Terminal) =
  term.tname = getEnv("TERM")
  if term.tname == "":
    term.tname = "dosansi"
  when termcap_found:
    term.loadTermcap()
    if term.tc != nil:
      term.smcup = term.hascap(ti)
    term.formatmode = {FLAG_ITALIC, FLAG_OVERLINE, FLAG_STRIKE}
    if term.hascap(us):
      term.formatmode.incl(FLAG_UNDERLINE)
    if term.hascap(md):
      term.formatmode.incl(FLAG_BOLD)
    if term.hascap(mr):
      term.formatmode.incl(FLAG_REVERSE)
    if term.hascap(mb):
      term.formatmode.incl(FLAG_BLINK)
  else:
    term.smcup = true
    term.formatmode = {low(FormatFlags)..high(FormatFlags)}
  if term.config.colormode.isSome:
    term.colormode = term.config.colormode.get
  else:
    term.colormode = ANSI
    let colorterm = getEnv("COLORTERM")
    case colorterm
    of "24bit", "truecolor": term.colormode = TRUE_COLOR
  if term.config.formatmode.isSome:
    term.formatmode = term.config.formatmode.get
  if term.config.altscreen.isSome:
    term.smcup = term.config.altscreen.get

proc start*(term: Terminal, infile: File) =
  term.infile = infile
  assert term.outfile.getFileHandle().setInheritable(false)
  assert term.infile.getFileHandle().setInheritable(false)
  when defined(posix):
    if term.isatty():
      enableRawMode(infile.getFileHandle())
  term.detectTermAttributes()
  if term.smcup:
    term.write(term.enableAltScreen())

proc newTerminal*(outfile: File, config: Config): Terminal =
  let term = new Terminal
  term.outfile = outfile
  term.config = config
  return term
