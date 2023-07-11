import options
import os
import streams
import tables
import terminal
import unicode

import bindings/termcap
import buffer/cell
import config/config
import data/charset
import encoding/encoderstream
import io/runestream
import io/window
import types/color
import utils/opt
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
    LE # cursor left %1 characters
    RI # cursor right %1 characters

  Termcap = ref object
    bp: array[1024, uint8]
    funcstr: array[256, uint8]
    caps: array[TermcapCap, cstring]

  Terminal* = ref TerminalObj
  TerminalObj = object
    cs*: Charset
    config: Config
    infile: File
    outfile: File
    cleared: bool
    canvas*: FixedGrid
    pcanvas: FixedGrid
    attrs*: WindowAttributes
    mincontrast: int
    colormode: ColorMode
    formatmode: FormatMode
    smcup: bool
    tc: Termcap
    tname: string
    set_title: bool

func hascap(term: Terminal, c: TermcapCap): bool = term.tc.caps[c] != nil
func cap(term: Terminal, c: TermcapCap): string = $term.tc.caps[c]
func ccap(term: Terminal, c: TermcapCap): cstring = term.tc.caps[c]

# control sequence introducer
template CSI(s: varargs[string, `$`]): string =
  "\e[" & s.join(';')

# OS command
template OSC(s: varargs[string, `$`]): string =
  "\e]" & s.join(';') & '\a'

template XTERM_TITLE(s: string): string =
  OSC(0, s)

when not termcap_found:
  # DEC set
  template DECSET(s: varargs[string, `$`]): string =
    "\e[?" & s.join(';') & 'h'
  # DEC reset
  template DECRST(s: varargs[string, `$`]): string =
    "\e[?" & s.join(';') & 'l'
  template SMCUP(): string = DECSET(1049)
  template RMCUP(): string = DECRST(1049)
  template HVP(s: varargs[string, `$`]): string =
    CSI(s) & "f"
  template EL(): string =
    CSI() & "K"
  template ED(): string =
    CSI() & "J"

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
    return HVP(y + 1, x + 1)

proc clearEnd(term: Terminal): string =
  when termcap_found:
    return term.cap ce
  else:
    return EL()

proc clearDisplay(term: Terminal): string =
  when termcap_found:
    return term.cap cd
  else:
    return ED()

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
  elif a.color >= 16:
    return eightBitToRGB(EightBitColor(a.color))
  return ANSIColorMap[a.color mod 10]

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(rgb: RGBColor): ANSIColor =
  var a = 0i32
  var n = -1
  for i in 0 .. ANSIColorMap.high:
    let color = ANSIColorMap[i]
    if color == rgb:
      return ANSIColor(i)
    let x = int32(color.r) - int32(rgb.r)
    let y = int32(color.g) - int32(rgb.g)
    let z = int32(color.b) - int32(rgb.b)
    let xx = x * x
    let yy = y * y
    let zz = z * z
    let b = xx + yy + zz
    if n == -1 or b < a:
      n = i
      a = b
  return ANSIColor(n)

# Return a fgcolor contrasted to the background by contrast.
proc correctContrast(bgcolor, fgcolor: CellColor, contrast: int,
    colormode: ColorMode): CellColor =
  let cfgcolor = fgcolor
  let bgcolor = getRGB(bgcolor, true)
  let fgcolor = getRGB(fgcolor, false)
  let bgY = int(bgcolor.Y)
  var fgY = int(fgcolor.Y)
  let diff = abs(bgY - fgY)
  if diff < contrast:
    if bgY > fgY:
      fgY = bgY - contrast
      if fgY < 0:
        fgY = bgY + contrast
        if fgY > 255:
          fgY = 0
    else:
      fgY = bgY + contrast
      if fgY > 255:
        fgY = bgY - contrast
        if fgY < 0:
          fgY = 255
    let newrgb = YUV(cast[uint8](fgY), fgcolor.U, fgcolor.V)
    case colormode
    of TRUECOLOR:
      return cellColor(newrgb)
    of ANSI:
      return cellColor(approximateANSIColor(newrgb))
    of EIGHT_BIT:
      return cellColor(rgbToEightBit(newrgb))
    of MONOCHROME:
      doAssert false
  return cfgcolor

proc processFormat*(term: Terminal, format: var Format, cellf: Format): string =
  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag in format.flags and flag notin cellf.flags:
        result &= term.endFormat(flag)

  var cellf = cellf
  case term.colormode
  of ANSI:
    if not cellf.bgcolor.rgb and cellf.bgcolor.color > 15:
      let color = cellf.bgcolor.eightbit
      cellf.bgcolor = cellColor(eightBitToRGB(color))
    if not cellf.fgcolor.rgb and cellf.fgcolor.color > 15:
      let color = cellf.fgcolor.eightbit
      cellf.fgcolor = cellColor(eightBitToRGB(color))
    if cellf.bgcolor.rgb:
      let color = approximateANSIColor(cellf.bgcolor.rgbcolor)
      if color == ANSI_BLACK:
        cellf.bgcolor = defaultColor
      else:
        cellf.bgcolor = cellColor(color)
    if cellf.fgcolor.rgb:
      if cellf.bgcolor == defaultColor:
        var color = approximateANSIColor(cellf.fgcolor.rgbcolor)
        if color == ANSI_BLACK:
          color = ANSI_WHITE
        if color == ANSI_WHITE:
          cellf.fgcolor = defaultColor
        else:
          cellf.fgcolor = cellColor(color)
      else:
        cellf.fgcolor = if cellf.bgcolor.color < 4:
          defaultColor
        else:
          cellColor(ANSI_WHITE) # white
  of EIGHT_BIT:
    if cellf.bgcolor.rgb:
      cellf.bgcolor = cellColor(rgbToEightBit(cellf.bgcolor.rgbcolor))
    if cellf.fgcolor.rgb:
      cellf.fgcolor = cellColor(rgbToEightBit(cellf.fgcolor.rgbcolor))
  of MONOCHROME:
    cellf.fgcolor = defaultColor
    cellf.bgcolor = defaultColor
  of TRUE_COLOR: discard

  if term.colormode != MONOCHROME:
    cellf.fgcolor = correctContrast(cellf.bgcolor, cellf.fgcolor,
      term.mincontrast, term.colormode)
  if cellf.fgcolor != format.fgcolor and cellf.fgcolor == defaultColor or
      cellf.bgcolor != format.bgcolor and cellf.bgcolor == defaultColor:
    result &= term.resetFormat()
    format = newFormat()

  if cellf.fgcolor != format.fgcolor:
    var color = cellf.fgcolor
    if color.rgb:
      assert term.colormode == TRUECOLOR
      let rgb = color.rgbcolor
      result &= SGR(38, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      discard
    else:
      let n = color.color
      if n < 8:
        result &= SGR(30 + n)
      else:
        assert term.colormode in {TRUECOLOR, EIGHT_BIT}
        result &= SGR(38, 5, n)

  if cellf.bgcolor != format.bgcolor:
    var color = cellf.bgcolor
    if color.rgb:
      assert term.colormode == TRUECOLOR
      let rgb = color.rgbcolor
      result &= SGR(48, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      discard
    else:
      let n = color.color
      if n < 8:
        result &= SGR(40 + n)
      else:
        assert term.colormode in {TRUECOLOR, EIGHT_BIT}
        result &= SGR(48, 5, n)

  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag notin format.flags and flag in cellf.flags:
        result &= term.startFormat(flag)

  format = cellf

proc windowChange*(term: Terminal, attrs: WindowAttributes) =
  term.attrs = attrs
  term.canvas = newFixedGrid(attrs.width, attrs.height)
  term.cleared = false

proc setTitle*(term: Terminal, title: string) =
  if term.set_title:
    term.outfile.write(XTERM_TITLE(title))

const colorFormat = block:
  var format = newFormat()
  format.fgcolor = cellColor(ANSI_BLUE)
  format

const defaultFormat = newFormat()

template processOutputString0*(term: Terminal, str: iterable[Rune],
    colorctrl: static bool, w: var int): string =
  var rs0: seq[Rune]
  var ctrl = false
  var format = newFormat()
  discard ctrl
  discard format
  for r in str:
    if r.isControlChar():
      when colorctrl:
        if not ctrl:
          rs0 &= term.processFormat(format, colorFormat).toRunes()
      rs0 &= Rune('^')
      rs0 &= Rune(cast[char](r).getControlLetter())
    else:
      when colorctrl:
        if ctrl:
          rs0 &= term.processFormat(format, defaultFormat).toRunes()
      rs0 &= r
    ctrl = r.isControlChar()
    # twidth wouldn't work here, the view may start at the nth character.
    # pager must ensure tabs are converted beforehand.
    w += r.width()
  let ss = newRuneStream(toOpenArray(cast[seq[uint32]](rs0), 0, rs0.high))
  let es = newEncoderStream(ss, term.cs, errormode = ENCODER_ERROR_MODE_FATAL)
  es.readAll()

proc processOutputString*(term: Terminal, str: string, w: var int): string =
  if str.validateUtf8() != -1:
    return "?"
  if term.cs == CHARSET_UTF_8:
    # optimized common case
    block notfound:
      for c in str:
        if c in Controls:
          break notfound
      # No control characters, and the output encoding matches the internal
      # representation.
      w += str.width()
      return str
    var s = ""
    for c in str:
      if c in Controls:
        s &= '^'
        s &= c.getControlLetter()
      else:
        s &= c
      # no twidth, see above
      w += Rune(c).width()
    return s
  # Output is not utf-8, so we must convert back to utf-32 and then encode.
  return term.processOutputString0(str.runes, false, w)

proc generateFullOutput(term: Terminal, grid: FixedGrid): string =
  var format = newFormat()
  result &= term.cursorGoto(0, 0)
  result &= term.resetFormat()
  result &= term.clearDisplay()
  for y in 0 ..< grid.height:
    if y != 0:
      result &= "\r\n"
    var w = 0
    for x in 0 ..< grid.width:
      while w < x:
        result &= " "
        inc w
      let cell = grid[y * grid.width + x]
      result &= term.processFormat(format, cell.format)
      result &= term.processOutputString(cell.str, w)

proc generateSwapOutput(term: Terminal, grid, prev: FixedGrid): string =
  var vy = -1
  for y in 0 ..< grid.height:
    var w = 0
    var change = false
    # scan for changes, and set cx to x of the first change
    var cx = 0
    for x in 0 ..< grid.width:
      if grid[y * grid.width + x] != prev[y * grid.width + x]:
        change = true
        cx = x
        w = x
        break
    if change:
      if cx == 0 and vy != -1:
        while vy < y:
          result &= "\r\n"
          inc vy
      else:
        result &= term.cursorGoto(cx, y)
        vy = y
      result &= term.resetFormat()
      var format = newFormat()
      for x in cx ..< grid.width:
        let cell = grid[y * grid.width + x]
        result &= term.processFormat(format, cell.format)
        result &= term.processOutputString(cell.str, w)
      if w < grid.width:
        result &= term.clearEnd()

proc hideCursor*(term: Terminal) =
  term.outfile.hideCursor()

proc showCursor*(term: Terminal) =
  term.outfile.showCursor()

func emulateOverline(term: Terminal): bool =
  term.config.display.emulate_overline and
    FLAG_OVERLINE notin term.formatmode and FLAG_UNDERLINE in term.formatmode

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
  if term.config.display.color_mode.isSome:
    term.colormode = term.config.display.color_mode.get
  elif term.isatty():
    term.colormode = ANSI
    let colorterm = getEnv("COLORTERM")
    case colorterm
    of "24bit", "truecolor": term.colormode = TRUE_COLOR
  if term.config.display.format_mode.isSome:
    term.formatmode = term.config.display.format_mode.get
  for fm in FormatFlags:
    if fm in term.config.display.no_format_mode:
      term.formatmode.excl(fm)
  if term.isatty():
    if term.config.display.alt_screen.isSome:
      term.smcup = term.config.display.alt_screen.get
    term.set_title = term.config.display.set_title
  term.mincontrast = term.config.display.minimum_contrast
  if term.config.encoding.display_charset.isSome:
    term.cs = term.config.encoding.display_charset.get
  else:
    term.cs = DefaultCharset
    for s in ["LC_ALL", "LC_CTYPE", "LANG"]:
      let env = getEnv(s)
      if env == "":
        continue
      let cs = getLocaleCharset(env)
      if cs != CHARSET_UNKNOWN:
        term.cs = cs
        break

proc outputGrid*(term: Terminal) =
  if term.config.display.force_clear:
    term.applyConfig()
  term.outfile.write(term.resetFormat())
  let samesize = term.canvas.width == term.pcanvas.width and term.canvas.height == term.pcanvas.height
  if term.config.display.force_clear or not term.cleared or not samesize:
    term.outfile.write(term.generateFullOutput(term.canvas))
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput(term.canvas, term.pcanvas))
  if not samesize:
    term.pcanvas.width = term.canvas.width
    term.pcanvas.height = term.canvas.height
    term.pcanvas.cells.setLen(term.canvas.cells.len)
  for i in 0 ..< term.canvas.cells.len:
    term.pcanvas[i] = term.canvas[i]

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
