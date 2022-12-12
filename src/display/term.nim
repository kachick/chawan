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
    LE # cursor left %1 characters
    RI # cursor right %1 characters

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
    canvas: FixedGrid
    pcanvas: FixedGrid
    attrs*: WindowAttributes
    mincontrast: int
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

when not termcap_found:
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
  template HVP(s: varargs[string, `$`]): string =
    CSI(s) & "f"
  template EL(s: varargs[string, `$`]): string =
    CSI(s) & "K"

template SGR*(s: varargs[string, `$`]): string =
  CSI(s) & "m"

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

proc write*(term: Terminal, s: string) =
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

proc isatty(term: Terminal): bool =
  term.infile != nil and term.infile.isatty() and term.outfile.isatty()

proc resetFormat(term: Terminal): string =
  when termcap_found:
    if term.isatty():
      return term.cap me
    return SGR()
  else:
    return SGR()

proc startFormat(term: Terminal, flag: FormatFlags): string =
  when termcap_found:
    if term.isatty():
      case flag
      of FLAG_BOLD: return term.cap md
      of FLAG_UNDERLINE: return term.cap us
      of FLAG_REVERSE: return term.cap mr
      of FLAG_BLINK: return term.cap mb
      else: discard
  return SGR(FormatCodes[flag].s)

proc endFormat(term: Terminal, flag: FormatFlags): string =
  when termcap_found:
    if flag == FLAG_UNDERLINE and term.isatty():
      return term.cap ue
  return SGR(FormatCodes[flag].e)

#TODO get rid of these
proc setCursor*(term: Terminal, x, y: int) =
  term.write(term.cursorGoto(x, y))

proc cursorBackward*(term: Terminal, i: int) =
  if i > 0:
    if i == 1:
      term.write("\b")
    else:
      when termcap_found:
        term.write($tgoto(term.ccap LE, 0, cint(i)))
      else:
        term.outfile.cursorBackward(i)

proc cursorForward*(term: Terminal, i: int) =
  if i > 0:
    when termcap_found:
      term.write($tgoto(term.ccap RI, 0, cint(i)))
    else:
      term.outfile.cursorForward(i)

proc cursorBegin*(term: Terminal) =
  term.write("\r")

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

proc getRGB(a: CellColor, bg: bool): RGBColor =
  if a.rgb:
    return a.rgbcolor
  elif a == defaultColor:
    if bg:
      return ColorsRGB["black"]
    else:
      return ColorsRGB["white"]
  return ANSIColorMap[a.color mod 10]

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

# Return a fgcolor contrasted to the background by contrast.
proc correctContrast(bgcolor, fgcolor: CellColor, contrast: int): CellColor =
  let cfgcolor = fgcolor
  let bgcolor = getRGB(bgcolor, true)
  let fgcolor = getRGB(fgcolor, false)
  let bgY = bgcolor.Y
  let fgY = fgcolor.Y
  let diff = abs(bgY - fgY)
  if diff < contrast:
    let newrgb = if bgY > contrast:
      YUV(bgY - contrast, fgcolor.U, fgcolor.V)
    else:
      YUV(bgY + contrast, fgcolor.U, fgcolor.V)
    if cfgcolor.rgb:
      return newrgb.cellColor()
    return ColorsANSIFg[approximateANSIColor(newrgb)]
  return cfgcolor

proc processFormat*(term: Terminal, format: var Format, cellf: Format): string =
  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag in format.flags and flag notin cellf.flags:
        result &= term.endFormat(flag)

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

  cellf.fgcolor = correctContrast(cellf.bgcolor, cellf.fgcolor, term.mincontrast)

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
      result &= term.resetFormat()
      format = newFormat()
    else:
      result &= SGR(color.color)

  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag notin format.flags and flag in cellf.flags:
        result &= term.startFormat(flag)

  format = cellf

proc windowChange*(term: Terminal, attrs: WindowAttributes) =
  term.attrs = attrs
  term.canvas = newFixedGrid(attrs.width, attrs.height)
  term.cleared = false

func generateFullOutput(term: Terminal, grid: FixedGrid): string =
  var format = newFormat()
  result &= term.cursorGoto(0, 0)
  result &= term.resetFormat()
  for y in 0 ..< grid.height:
    var w = 0
    for x in 0 ..< grid.width:
      while w < x:
        result &= " "
        inc w
      let cell = grid[y * grid.width + x]
      result &= term.processFormat(format, cell.format)
      result &= cell.str
      w += cell.width()
    result &= term.clearEnd()
    if y != grid.height - 1:
      result &= "\r\n"

func generateSwapOutput(term: Terminal, grid: FixedGrid, prev: FixedGrid): string =
  var format = newFormat()
  var x = 0
  var w = 0
  var line = ""
  var lr = false
  for i in 0 ..< grid.cells.len:
    while w < x:
      line &= " "
      inc w
    if x >= grid.width:
      format = newFormat()
      if lr:
        result &= term.cursorGoto(0, i div grid.width - 1)
        result &= term.resetFormat()
        result &= term.clearEnd()
        result &= line
        lr = false
      x = 0
      w = 0
      line = ""
    lr = lr or (grid[i] != prev[i])
    line &= term.processFormat(format, grid.cells[i].format)
    line &= grid.cells[i].str
    w += grid.cells[i].width()
    inc x
  if lr:
    result &= term.cursorGoto(0, grid.height - 1)
    result &= term.resetFormat()
    result &= term.clearEnd()
    result &= line

proc hideCursor*(term: Terminal) =
  term.outfile.hideCursor()

proc showCursor*(term: Terminal) =
  term.outfile.showCursor()

func emulateOverline(term: Terminal): bool =
  term.config.emulateoverline and FLAG_OVERLINE notin term.formatmode and
  FLAG_UNDERLINE in term.formatmode

proc writeGrid*(term: Terminal, grid: FixedGrid, x = 0, y = 0) =
  for ly in y ..< y + grid.height:
    for lx in x ..< x + grid.width:
      let i = ly * term.canvas.width + lx
      term.canvas[i] = grid[(ly - y) * grid.width + (lx - x)]
      if i >= term.canvas.width and FLAG_OVERLINE in term.canvas[i].format.flags and term.emulateOverline:
        let w = grid[(ly - y) * grid.width + (lx - x)].width()
        let s = i - term.canvas.width
        var j = s
        while j < term.canvas.len and j < s + w:
          let cell = addr term.canvas[j]
          cell.format.flags.incl(FLAG_UNDERLINE)
          if cell.str == "":
            cell.str = " "
          if cell.str == " ":
            cell.format.fgcolor = grid[(ly - y) * grid.width + (lx - x)].format.fgcolor
          j += cell[].width()

proc applyConfig(term: Terminal) =
  if term.config.colormode.isSome:
    term.colormode = term.config.colormode.get
  elif term.isatty():
    term.colormode = ANSI
    let colorterm = getEnv("COLORTERM")
    case colorterm
    of "24bit", "truecolor": term.colormode = TRUE_COLOR
  if term.config.formatmode.isSome:
    term.formatmode = term.config.formatmode.get
  for fm in FormatFlags:
    if fm in term.config.noformatmode:
      term.formatmode.excl(fm)
  if term.isatty() and term.config.altscreen.isSome:
    term.smcup = term.config.altscreen.get
  term.mincontrast = term.config.mincontrast

proc outputGrid*(term: Terminal) =
  if term.config.termreload:
    term.applyConfig()
  term.outfile.write(term.resetFormat())
  if term.config.forceclear or not term.cleared:
    term.outfile.write(term.generateFullOutput(term.canvas))
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput(term.canvas, term.pcanvas))
  term.pcanvas = term.canvas

proc clearCanvas*(term: Terminal) =
  term.cleared = false

when defined(posix):
  import posix
  import termios

  # see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
  var orig_termios: Termios
  var stdin_fileno: FileHandle
  proc disableRawMode() {.noconv.} =
    discard tcSetAttr(stdin_fileno, TCSAFLUSH, addr orig_termios)

  proc enableRawMode(fileno: FileHandle) =
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
  proc disableRawMode() =
    discard

  proc enableRawMode(fileno: FileHandle) =
    discard

  proc unblockStdin*(): cint =
    discard

  proc restoreStdin*(flags: cint) =
    discard

proc quit*(term: Terminal) =
  if term.isatty():
    disableRawMode()
    if term.smcup:
      term.write(term.disableAltScreen())
    else:
      term.write(term.cursorGoto(0, term.attrs.height - 1))
    term.showCursor()
    term.cleared = false
  term.flush()

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
    if term.isatty():
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
    if term.isatty():
      term.smcup = true
      term.formatmode = {low(FormatFlags)..high(FormatFlags)}
  term.applyConfig()

proc start*(term: Terminal, infile: File) =
  term.infile = infile
  if term.isatty():
    enableRawMode(infile.getFileHandle())
  term.detectTermAttributes()
  if term.smcup:
    term.write(term.enableAltScreen())

proc restart*(term: Terminal) =
  if term.isatty():
    enableRawMode(term.infile.getFileHandle())
  if term.smcup:
    term.write(term.enableAltScreen())

proc newTerminal*(outfile: File, config: Config, attrs: WindowAttributes): Terminal =
  let term = new Terminal
  term.outfile = outfile
  term.config = config
  term.windowChange(attrs)
  return term
