import std/options
import std/os
import std/posix
import std/strutils
import std/tables
import std/termios
import std/unicode

import bindings/termcap
import config/config
import img/bitmap
import io/posixstream
import js/base64
import types/cell
import types/color
import types/opt
import types/winattrs
import utils/strwidth
import utils/twtstr

import chagashi/charset
import chagashi/encoder
import chagashi/validator

#TODO switch away from termcap...

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
    ZH # start italic mode
    se # end standout mode
    ue # end underline mode
    ZR # end italic mode
    me # end all formatting modes
    vs # enhance cursor
    vi # make cursor invisible
    ve # reset cursor to normal

  TermcapCapNumeric = enum
    Co # color?

  Termcap = ref object
    bp: array[1024, uint8]
    funcstr: array[256, uint8]
    caps: array[TermcapCap, cstring]
    numCaps: array[TermcapCapNumeric, cint]

  Terminal* = ref TerminalObj
  TerminalObj = object
    cs*: Charset
    config: Config
    istream*: PosixStream
    outfile: File
    cleared: bool
    canvas: FixedGrid
    pcanvas: FixedGrid
    attrs*: WindowAttributes
    colorMode: ColorMode
    formatMode: FormatMode
    imageMode: ImageMode
    smcup: bool
    tc: Termcap
    tname: string
    set_title: bool
    stdinUnblocked: bool
    stdinWasUnblocked: bool
    orig_termios: Termios
    defaultBackground: RGBColor
    defaultForeground: RGBColor
    ibuf*: string # buffer for chars when we can't process them
    hasSixel: bool
    sixelRegisterNum: int

# control sequence introducer
template CSI(s: varargs[string, `$`]): string =
  "\e[" & s.join(';')

# primary device attributes
const DA1 = CSI("c")

# push/pop current title to/from the terminal's title stack
const XTPUSHTITLE = CSI(22, "t")
const XTPOPTITLE = CSI(23, "t")

# report xterm text area size in pixels
const GEOMPIXEL = CSI(14, "t")

# report window size in chars
const GEOMCELL = CSI(18, "t")

# allow shift-key to override mouse protocol
const XTSHIFTESCAPE = CSI(">0s")

# query sixel register number
template XTSMGRAPHICS(pi, pa, pv: untyped): string =
  CSI("?" & $pi, $pa, $pv & "S")

# device control string
const DCSSTART = "\eP"

template DCS(a, b: char; s: varargs[string]): string =
  DCSSTART & a & b & s.join(';') & "\e\\"

template XTGETTCAP(s: varargs[string, `$`]): string =
  DCS('+', 'q', s)

# OS command
template OSC(s: varargs[string, `$`]): string =
  "\e]" & s.join(';') & '\a'

template XTSETTITLE(s: string): string =
  OSC(0, s)

const XTGETFG = OSC(10, "?") # get foreground color
const XTGETBG = OSC(11, "?") # get background color

# DEC set
template DECSET(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'h'

# DEC reset
template DECRST(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'l'

# alt screen
const SMCUP = DECSET(1049)
const RMCUP = DECRST(1049)

# mouse tracking
const SGRMOUSEBTNON = DECSET(1002, 1006)
const SGRMOUSEBTNOFF = DECRST(1002, 1006)

# application program command

# This is only used in kitty images, and join()'ing kilobytes of base64
# is rather inefficient so we don't use a template.
const APC = "\e_"
const ST = "\e\\"

const KITTYQUERY = APC & "Gi=1,a=q;" & ST

when not termcap_found:
  const CNORM = DECSET(25)
  const CIVIS = DECRST(25)
  template HVP(s: varargs[string, `$`]): string =
    CSI(s) & "f"
  template EL(): string =
    CSI() & "K"
  template ED(): string =
    CSI() & "J"

  proc write(term: Terminal; s: string) =
    term.outfile.write(s)
else:
  func hascap(term: Terminal; c: TermcapCap): bool = term.tc.caps[c] != nil
  func cap(term: Terminal; c: TermcapCap): string = $term.tc.caps[c]
  func ccap(term: Terminal; c: TermcapCap): cstring = term.tc.caps[c]

  var goutfile: File
  proc putc(c: char): cint {.cdecl.} =
    goutfile.write(c)

  proc write(term: Terminal; s: cstring) =
    discard tputs(s, 1, putc)

  proc write(term: Terminal; s: string) =
    term.write(cstring(s))

proc readChar*(term: Terminal): char =
  if term.ibuf.len == 0:
    result = term.istream.sreadChar()
  else:
    result = term.ibuf[0]
    term.ibuf.delete(0..0)

template SGR*(s: varargs[string, `$`]): string =
  CSI(s) & "m"

#TODO a) this should be customizable
const ANSIColorMap = [
  rgb(0, 0, 0),
  rgb(205, 0, 0),
  rgb(0, 205, 0),
  rgb(205, 205, 0),
  rgb(0, 0, 238),
  rgb(205, 0, 205),
  rgb(0, 205, 205),
  rgb(229, 229, 229),
  rgb(127, 127, 127),
  rgb(255, 0, 0),
  rgb(0, 255, 0),
  rgb(255, 255, 0),
  rgb(92, 92, 255),
  rgb(255, 0, 255),
  rgb(0, 255, 255),
  rgb(255, 255, 255)
]

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc cursorGoto(term: Terminal; x, y: int): string =
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

proc isatty*(file: File): bool =
  return file.getFileHandle().isatty() != 0

proc isatty*(term: Terminal): bool =
  return term.istream != nil and term.istream.fd.isatty() != 0 and
    term.outfile.isatty()

proc anyKey*(term: Terminal; msg = "[Hit any key]") =
  if term.isatty():
    term.outfile.write(term.clearEnd() & msg)
    term.outfile.flushFile()
    discard term.istream.sreadChar()

proc resetFormat(term: Terminal): string =
  when termcap_found:
    if term.isatty():
      return term.cap me
  return SGR()

proc startFormat(term: Terminal; flag: FormatFlags): string =
  when termcap_found:
    if term.isatty():
      case flag
      of ffBold: return term.cap md
      of ffUnderline: return term.cap us
      of ffReverse: return term.cap mr
      of ffBlink: return term.cap mb
      of ffItalic: return term.cap ZH
      else: discard
  return SGR(FormatCodes[flag].s)

proc endFormat(term: Terminal; flag: FormatFlags): string =
  when termcap_found:
    if term.isatty():
      case flag
      of ffUnderline: return term.cap ue
      of ffItalic: return term.cap ZR
      else: discard
  return SGR(FormatCodes[flag].e)

proc setCursor*(term: Terminal; x, y: int) =
  term.write(term.cursorGoto(x, y))

proc enableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap ti:
      return term.cap ti
  return SMCUP

proc disableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap te:
      return term.cap te
  return RMCUP

func mincontrast(term: Terminal): int32 =
  return term.config.display.minimum_contrast

proc getRGB(a: CellColor; termDefault: RGBColor): RGBColor =
  case a.t
  of ctNone:
    return termDefault
  of ctANSI:
    if a.color >= 16:
      return EightBitColor(a.color).toRGB()
    return ANSIColorMap[a.color]
  of ctRGB:
    return a.rgbcolor

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(rgb, termDefault: RGBColor): CellColor =
  var a = 0i32
  var n = -1
  for i in -1 .. ANSIColorMap.high:
    let color = if i >= 0:
      ANSIColorMap[i]
    else:
      termDefault
    if color == rgb:
      return if i == -1: defaultColor else: ANSIColor(i).cellColor()
    let x = int32(color.r) - int32(rgb.r)
    let y = int32(color.g) - int32(rgb.g)
    let z = int32(color.b) - int32(rgb.b)
    let xx = x * x
    let yy = y * y
    let zz = z * z
    let b = xx + yy + zz
    if i == -1 or b < a:
      n = i
      a = b
  return if n == -1: defaultColor else: ANSIColor(n).cellColor()

# Return a fgcolor contrasted to the background by term.mincontrast.
proc correctContrast(term: Terminal; bgcolor, fgcolor: CellColor): CellColor =
  let contrast = term.mincontrast
  let cfgcolor = fgcolor
  let bgcolor = getRGB(bgcolor, term.defaultBackground)
  let fgcolor = getRGB(fgcolor, term.defaultForeground)
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
    let newrgb = YUV(uint8(fgY), fgcolor.U, fgcolor.V)
    case term.colorMode
    of cmTrueColor:
      return cellColor(newrgb)
    of cmANSI:
      return approximateANSIColor(newrgb, term.defaultForeground)
    of cmEightBit:
      return cellColor(newrgb.toEightBit())
    of cmMonochrome:
      doAssert false
  return cfgcolor

template ansiSGR(n: uint8, bgmod: int): string =
  if n < 8:
    SGR(30 + bgmod + n)
  else:
    SGR(82 + bgmod + n)

template eightBitSGR(n: uint8, bgmod: int): string =
  if n < 16:
    ansiSGR(n, bgmod)
  else:
    SGR(38 + bgmod, 5, n)

template rgbSGR(rgb: RGBColor; bgmod: int): string =
  SGR(38 + bgmod, 2, rgb.r, rgb.g, rgb.b)

proc processFormat*(term: Terminal; format: var Format; cellf: Format): string =
  for flag in FormatFlags:
    if flag in term.formatMode:
      if flag in format.flags and flag notin cellf.flags:
        result &= term.endFormat(flag)
      if flag notin format.flags and flag in cellf.flags:
        result &= term.startFormat(flag)
  var cellf = cellf
  case term.colorMode
  of cmANSI:
    # quantize
    if cellf.bgcolor.t == ctANSI and cellf.bgcolor.color > 15:
      cellf.bgcolor = cellf.fgcolor.eightbit.toRGB().cellColor()
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = approximateANSIColor(cellf.bgcolor.rgbcolor,
        term.defaultBackground)
    if cellf.fgcolor.t == ctANSI and cellf.fgcolor.color > 15:
      cellf.fgcolor = cellf.fgcolor.eightbit.toRGB().cellColor()
    if cellf.fgcolor.t == ctRGB:
      if cellf.bgcolor.t == ctNone:
        cellf.fgcolor = approximateANSIColor(cellf.fgcolor.rgbcolor,
          term.defaultForeground)
      else:
        # ANSI fgcolor + bgcolor at the same time is broken
        cellf.fgcolor = defaultColor
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    case cellf.fgcolor.t
    of ctNone: result &= SGR(39)
    of ctANSI: result &= ansiSGR(cellf.fgcolor.color, 0)
    else: assert false
    case cellf.bgcolor.t
    of ctNone: result &= SGR(49)
    of ctANSI: result &= ansiSGR(cellf.bgcolor.color, 10)
    else: assert false
  of cmEightBit:
    # quantize
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = cellf.bgcolor.rgbcolor.toEightBit().cellColor()
    if cellf.fgcolor.t == ctRGB:
      cellf.fgcolor = cellf.fgcolor.rgbcolor.toEightBit().cellColor()
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    case cellf.fgcolor.t
    of ctNone: result &= SGR(39)
    of ctANSI: result &= eightBitSGR(cellf.fgcolor.color, 0)
    of ctRGB: assert false
    case cellf.bgcolor.t
    of ctNone: result &= SGR(49)
    of ctANSI: result &= eightBitSGR(cellf.bgcolor.color, 10)
    of ctRGB: assert false
  of cmTrueColor:
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    if cellf.fgcolor != format.fgcolor:
      case cellf.fgcolor.t
      of ctNone: result &= SGR(39)
      of ctANSI: result &= eightBitSGR(cellf.fgcolor.color, 0)
      of ctRGB: result &= rgbSGR(cellf.fgcolor.rgbcolor, 0)
    if cellf.bgcolor != format.bgcolor:
      case cellf.bgcolor.t
      of ctNone: result &= SGR(49)
      of ctANSI: result &= eightBitSGR(cellf.bgcolor.color, 10)
      of ctRGB: result &= rgbSGR(cellf.bgcolor.rgbcolor, 10)
  of cmMonochrome:
    discard # nothing to do
  format = cellf

proc setTitle*(term: Terminal; title: string) =
  if term.set_title:
    term.outfile.write(XTSETTITLE(title.replaceControls()))

proc enableMouse*(term: Terminal) =
  term.write(XTSHIFTESCAPE & SGRMOUSEBTNON)

proc disableMouse*(term: Terminal) =
  term.write(SGRMOUSEBTNOFF)

proc processOutputString*(term: Terminal; str: string; w: var int): string =
  if str.validateUTF8Surr() != -1:
    return "?"
  # twidth wouldn't work here, the view may start at the nth character.
  # pager must ensure tabs are converted beforehand.
  w += str.notwidth()
  let str = if Controls in str:
    str.replaceControls()
  else:
    str
  if term.cs == CHARSET_UTF_8:
    # The output encoding matches the internal representation.
    return str
  else:
    # Output is not utf-8, so we must encode it first.
    var success = false
    return newTextEncoder(term.cs).encodeAll(str, success)

proc generateFullOutput(term: Terminal; grid: FixedGrid): string =
  var format = Format()
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

proc generateSwapOutput(term: Terminal; grid, prev: FixedGrid): string =
  var vy = -1
  for y in 0 ..< grid.height:
    var w = 0
    var change = false
    # scan for changes, and set cx to x of the first change
    var cx = 0
    # if there is a change, we have to start from the last x with
    # a string (otherwise we might overwrite a double-width char)
    var lastx = 0
    for x in 0 ..< grid.width:
      let i = y * grid.width + x
      if grid[i].str != "":
        lastx = x
      if grid[i] != prev[i]:
        change = true
        cx = lastx
        w = lastx
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
      var format = Format()
      for x in cx ..< grid.width:
        while w < x: # if previous cell had no width, catch up with x
          result &= ' '
          inc w
        let cell = grid[y * grid.width + x]
        result &= term.processFormat(format, cell.format)
        result &= term.processOutputString(cell.str, w)
      if w < grid.width:
        result &= term.clearEnd()

proc hideCursor*(term: Terminal) =
  when termcap_found:
    term.write(term.ccap vi)
  else:
    term.write(CIVIS)

proc showCursor*(term: Terminal) =
  when termcap_found:
    term.write(term.ccap ve)
  else:
    term.write(CNORM)

func emulateOverline(term: Terminal): bool =
  term.config.display.emulate_overline and
    ffOverline notin term.formatMode and ffUnderline in term.formatMode

proc writeGrid*(term: Terminal; grid: FixedGrid; x = 0, y = 0) =
  for ly in y ..< y + grid.height:
    for lx in x ..< x + grid.width:
      let i = ly * term.canvas.width + lx
      term.canvas[i] = grid[(ly - y) * grid.width + (lx - x)]
      let isol = ffOverline in term.canvas[i].format.flags
      if i >= term.canvas.width and isol and term.emulateOverline:
        let w = grid[(ly - y) * grid.width + (lx - x)].width()
        let s = i - term.canvas.width
        var j = s
        while j < term.canvas.len and j < s + w:
          let cell = addr term.canvas[j]
          cell.format.flags.incl(ffUnderline)
          if cell.str == "":
            cell.str = " "
          if cell.str == " ":
            let i = (ly - y) * grid.width + (lx - x)
            cell.format.fgcolor = grid[i].format.fgcolor
          j += cell[].width()

proc applyConfigDimensions(term: Terminal) =
  # screen dimensions
  if term.attrs.width == 0 or term.config.display.force_columns:
    term.attrs.width = int(term.config.display.columns)
  if term.attrs.height == 0 or term.config.display.force_lines:
    term.attrs.height = int(term.config.display.lines)
  if term.attrs.ppc == 0 or term.config.display.force_pixels_per_column:
    term.attrs.ppc = int(term.config.display.pixels_per_column)
  if term.attrs.ppl == 0 or term.config.display.force_pixels_per_line:
    term.attrs.ppl = int(term.config.display.pixels_per_line)
  term.attrs.width_px = term.attrs.ppc * term.attrs.width
  term.attrs.height_px = term.attrs.ppl * term.attrs.height

proc applyConfig(term: Terminal) =
  # colors, formatting
  if term.config.display.color_mode.isSome:
    term.colorMode = term.config.display.color_mode.get
  if term.config.display.format_mode.isSome:
    term.formatMode = term.config.display.format_mode.get
  for fm in FormatFlags:
    if fm in term.config.display.no_format_mode:
      term.formatMode.excl(fm)
  if term.config.display.image_mode.isSome:
    term.imageMode = term.config.display.image_mode.get
  if term.isatty():
    if term.config.display.alt_screen.isSome:
      term.smcup = term.config.display.alt_screen.get
    term.set_title = term.config.display.set_title
  if term.config.display.default_background_color.isSome:
    term.defaultBackground = term.config.display.default_background_color.get
  if term.config.display.default_foreground_color.isSome:
    term.defaultForeground = term.config.display.default_foreground_color.get
  # charsets
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
  term.applyConfigDimensions()

proc outputGrid*(term: Terminal) =
  term.outfile.write(term.resetFormat())
  let samesize = term.canvas.width == term.pcanvas.width and
    term.canvas.height == term.pcanvas.height
  if term.config.display.force_clear or not term.cleared or not samesize:
    term.outfile.write(term.generateFullOutput(term.canvas))
    term.cleared = true
    term.hasSixel = false
  else:
    term.outfile.write(term.generateSwapOutput(term.canvas, term.pcanvas))
  if not samesize:
    term.pcanvas.width = term.canvas.width
    term.pcanvas.height = term.canvas.height
    term.pcanvas.cells.setLen(term.canvas.cells.len)
  for i in 0 ..< term.canvas.cells.len:
    term.pcanvas[i] = term.canvas[i]

proc clearImages*(term: Terminal) =
  #TODO this entire function is a hack:
  # * for kitty, we shouldn't destroy & re-write every image every frame
  # * for sixel, we shouldn't practically set force-clear when images are on
  #   the screen
  case term.imageMode
  of imNone: discard
  of imKitty: term.write(APC & "Ga=d" & ST)
  of imSixel:
    if term.hasSixel:
      term.cleared = false

# data is binary 0..63; the output is the final ASCII form.
proc compressSixel(data: openArray[uint8]): string =
  var outs = newStringOfCap(data.len div 4)
  var n = 0
  var c = char(0)
  for u in data:
    let cc = char(u + 0x3F)
    if c != cc:
      if n > 3:
        outs &= '!' & $n & c
      else: # for char(0) n is also 0, so it is ignored.
        outs &= c.repeat(n)
      c = cc
      n = 0
    inc n
  if n > 3:
    outs &= '!' & $n & c
  else:
    outs &= c.repeat(n)
  return outs

type SixelBand = object
 c: uint8
 data: seq[uint8]

func find(bands: seq[SixelBand]; c: uint8): int =
  for i, band in bands:
    if band.c == c:
      return i
  -1

proc outputSixelImage(term: Terminal; x, y, offx, offy, dispw, disph: int;
    bmp: Bitmap) =
  var outs = term.cursorGoto(x, y)
  #TODO hsize seems to work without rounding on XTerm, idk if it works
  # everywhere?
  let hsize = disph - offy
  let wsize = dispw - offx
  outs &= DCSSTART & 'q'
  # set raster attributes
  outs &= "\"1;1;" & $wsize & ';' & $hsize
  for b in 16 ..< 256:
    # laziest possible register allocation scheme
    #TODO obviously this produces sub-optimal results
    let rgb = EightBitColor(b).toRGB()
    let rgbq = RGBColor(uint32(rgb).fastmul(100))
    let n = b - 15
    # 2 is RGB
    outs &= '#' & $n & ";2;" & $rgbq.r & ';' & $rgbq.g & ';' & $rgbq.b
  let W = int(dispw) - offx
  var n = offy * int(bmp.width)
  let L = disph * int(bmp.width)
  let cx0 = offx div term.attrs.ppc
  let nd = int(bmp.width) * term.attrs.ppl
  let xd = term.attrs.ppc
  while n < L:
    var bands = newSeq[SixelBand]()
    for i in 0 ..< 6:
      if n >= L:
        break
      let cn = n * term.canvas.width div nd
      let mask = 1u8 shl i
      for x in 0 ..< W:
        let cx = cx0 + x div xd
        let bgcolor0 = term.canvas[cn + cx].format.bgcolor
        let bgcolor = bgcolor0.getRGB(term.defaultBackground)
        let c0 = bmp.px[n + x + offx]
        let c = uint8(RGBColor(bgcolor.blend(c0)).toEightBit())
        if (let j = bands.find(c); j != -1):
          bands[j].data[x] = bands[j].data[x] or mask
        else:
          bands.add(SixelBand(c: c, data: newSeq[uint8](W)))
          bands[^1].data[^1] = mask
      n += int(bmp.width)
    term.write(outs)
    outs = ""
    for i, band in bands:
      let t = if i != bands.high: '$' else: '-'
      let n = band.c - 15
      outs &= '#' & $n & band.data.compressSixel() & t
  if outs.len > 0 and outs[^1] == '-':
    outs.setLen(outs.len - 1)
  outs &= ST
  term.write(outs)
  term.hasSixel = true

proc outputKittyImage(term: Terminal; x, y, offx, offy, dispw, disph: int;
    bmp: Bitmap) =
  const MaxPixels = ((4096 div 4) * 3) div 3 # max 4096 bytes, base64 encoded
  var outs = term.cursorGoto(x, y)
  outs &= APC & "Gf=24,m=1,a=T,C=1,s=" & $bmp.width & ",v=" & $bmp.height &
    ",x=" & $offx & ",y=" & $offy & ",w=" & $dispw & ",h=" & $disph & ';'
  var buf = newStringOfCap(MaxPixels * 4)
  var i = 0
  # transcode to RGB
  while i < bmp.px.len:
    if i > 0 and i mod MaxPixels == 0:
      outs &= btoa(buf)
      outs &= ST
      term.write(outs)
      buf.setLen(0)
      outs = APC & "Gm=1;"
    buf &= char(bmp.px[i].r)
    buf &= char(bmp.px[i].g)
    buf &= char(bmp.px[i].b)
    inc i
  outs = APC & "Gm=0;"
  outs &= btoa(buf)
  outs &= ST
  term.write(outs)

proc outputImage*(term: Terminal; bmp: Bitmap; x, y, maxw, maxh: int) =
  if term.imageMode == imNone:
    return
  let xpx = x * term.attrs.ppc
  let ypx = y * term.attrs.ppl
  let maxwpx = maxw * term.attrs.ppc
  let maxhpx = maxh * term.attrs.ppl
  let offx = if x < 0: -xpx else: 0
  let offy = if y < 0: -ypx else: 0
  var dispw = int(bmp.width)
  if xpx + dispw > maxwpx:
    dispw = maxwpx - xpx
  var disph = int(bmp.height)
  if ypx + disph > maxhpx:
    disph = maxhpx - ypx
  if dispw <= offx or disph <= offy:
    return
  let x = max(x, 0)
  let y = max(y, 0)
  case term.imageMode
  of imNone: discard
  of imSixel: term.outputSixelImage(x, y, offx, offy, dispw, disph, bmp)
  of imKitty: term.outputKittyImage(x, y, offx, offy, dispw, disph, bmp)

proc clearCanvas*(term: Terminal) =
  term.cleared = false

# see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
proc disableRawMode(term: Terminal) =
  discard tcSetAttr(term.istream.fd, TCSAFLUSH, addr term.orig_termios)

proc enableRawMode(term: Terminal) =
  discard tcGetAttr(term.istream.fd, addr term.orig_termios)
  var raw = term.orig_termios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not (OPOST)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(term.istream.fd, TCSAFLUSH, addr raw)

proc unblockStdin*(term: Terminal) =
  if term.isatty():
    term.istream.setBlocking(false)
    term.stdinUnblocked = true

proc restoreStdin*(term: Terminal) =
  if term.stdinUnblocked:
    term.istream.setBlocking(true)
    term.stdinUnblocked = false

proc quit*(term: Terminal) =
  if term.isatty():
    term.disableRawMode()
    if term.config.input.use_mouse:
      term.disableMouse()
    if term.smcup:
      term.write(term.disableAltScreen())
    else:
      term.write(term.cursorGoto(0, term.attrs.height - 1) &
        term.resetFormat() & "\n")
    if term.set_title:
      term.write(XTPOPTITLE)
    term.showCursor()
    term.cleared = false
    if term.stdinUnblocked:
      term.restoreStdin()
      term.stdinWasUnblocked = true
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
      for id in TermcapCapNumeric:
        tc.numCaps[id] = tgetnum(cstring($id))
    else:
      raise newException(Defect,
        "Failed to load termcap description for terminal " & term.tname)

type
  QueryAttrs = enum
    qaAnsiColor, qaRGB, qaSixel, qaKittyImage

  QueryResult = object
    success: bool
    attrs: set[QueryAttrs]
    fgcolor: Option[RGBColor]
    bgcolor: Option[RGBColor]
    widthPx: int
    heightPx: int
    width: int
    height: int
    registers: int

proc queryAttrs(term: Terminal; windowOnly: bool): QueryResult =
  const tcapRGB = 0x524742 # RGB supported?
  if not windowOnly:
    const outs =
      XTGETFG &
      XTGETBG &
      KITTYQUERY &
      GEOMPIXEL &
      GEOMCELL &
      XTSMGRAPHICS(1, 1, 0) & # color registers
      XTGETTCAP("524742") &
      DA1
    term.outfile.write(outs)
  else:
    const outs =
      GEOMPIXEL &
      GEOMCELL &
      DA1
    term.outfile.write(outs)
  term.flush()
  result = QueryResult(success: false, attrs: {})
  while true:
    template consume(term: Terminal): char = term.readChar()
    template fail = return
    template expect(term: Terminal; c: char) =
      if term.consume != c:
        fail
    template expect(term: Terminal; s: string) =
      for c in s:
        term.expect c
    template skip_until(term: Terminal; c: char) =
      while (let cc = term.consume; cc != c):
        discard
    template consume_int_till(term: Terminal; sentinel: char): int =
      var n = 0
      while (let c = term.consume; c != sentinel):
        if (let x = decValue(c); x != -1):
          n *= 10
          n += x
        else:
          fail
      n
    template consume_int_greedy(term: Terminal; lastc: var char): int =
      var n = 0
      while true:
        let c = term.consume
        if (let x = decValue(c); x != -1):
          n *= 10
          n += x
        else:
          lastc = c
          break
      n
    term.expect '\e'
    case term.consume
    of '[':
      # CSI
      case (let c = term.consume; c)
      of '?': # DA1, XTSMGRAPHICS
        var lastc: char
        var params = newSeq[int]()
        while true:
          let n = term.consume_int_greedy lastc
          params.add(n)
          if lastc in {'c', 'S'}:
            break
          if lastc != ';':
            fail
        if lastc == 'c':
          for n in params:
            case n
            of 4: result.attrs.incl(qaSixel)
            of 22: result.attrs.incl(qaAnsiColor)
            else: discard
          result.success = true
          break # DA1 returned; done
        else: # 'S'
          if params.len >= 3 and params[0] == 1 and params[1] == 0:
            result.registers = params[2]
      of '4', '8': # GEOMPIXEL, GEOMCELL
        term.expect ';'
        let height = term.consume_int_till ';'
        let width = term.consume_int_till 't'
        if c == '4': # GEOMSIZE
          result.widthPx = width
          result.heightPx = height
        if c == '8': # GEOMCELL
          result.width = width
          result.height = height
      else: fail
    of ']':
      # OSC
      term.expect '1'
      let c = term.consume
      if c notin {'0', '1'}: fail
      term.expect ';'
      if term.consume == 'r' and term.consume == 'g' and term.consume == 'b':
        term.expect ':'
        var was_esc = false
        template eat_color(tc: set[char]): uint8 =
          var val = 0u8
          var i = 0
          var c = char(0)
          while (c = term.consume; c notin tc):
            let v0 = hexValue(c)
            if i > 4 or v0 == -1:
              fail # wat
            let v = uint8(v0)
            if i == 0: # 1st place
              val = (v shl 4) or v
            elif i == 1: # 2nd place
              val = (val xor 0xF) or v
            # all other places are irrelevant
            inc i
          was_esc = c == '\e'
          val
        let r = eat_color {'/'}
        let g = eat_color {'/'}
        let b = eat_color {'\a', '\e'}
        if was_esc:
          # we got ST, not BEL; at least kitty does this
          term.expect '\\'
        if c == '0':
          result.fgcolor = some(rgb(r, g, b))
        else:
          result.bgcolor = some(rgb(r, g, b))
      else:
        # not RGB, give up
        term.skip_until '\a'
    of 'P':
      # DCS
      let c = term.consume
      if c notin {'0', '1'}:
        fail
      term.expect "+r"
      if c == '1':
        var id = 0
        while (let c = term.consume; c != '='):
          if c notin AsciiHexDigit:
            fail
          id *= 0x10
          id += hexValue(c)
        term.skip_until '\e' # ST (1)
        if id == tcapRGB:
          result.attrs.incl(qaRGB)
      else: # 0
        # pure insanity: kitty returns P0, but also +r524742 after. please
        # make up your mind!
        term.skip_until '\e' # ST (1)
      term.expect '\\' # ST (2)
    of '_': # APC
      term.expect 'G'
      result.attrs.incl(qaKittyImage)
      term.skip_until '\e' # ST (1)
      term.expect '\\' # ST (2)
    else:
      fail

type TermStartResult* = enum
  tsrSuccess, tsrDA1Fail

# when windowOnly, only refresh window size.
proc detectTermAttributes(term: Terminal; windowOnly: bool): TermStartResult =
  result = tsrSuccess
  term.tname = getEnv("TERM")
  if term.tname == "":
    term.tname = "dosansi"
  if not term.isatty():
    return
  var win: IOctl_WinSize
  if ioctl(term.istream.fd, TIOCGWINSZ, addr win) != -1:
    term.attrs.width = int(win.ws_col)
    term.attrs.height = int(win.ws_row)
    term.attrs.ppc = int(win.ws_xpixel) div term.attrs.width
    term.attrs.ppl = int(win.ws_ypixel) div term.attrs.height
  if term.config.display.query_da1:
    let r = term.queryAttrs(windowOnly)
    if r.success: # DA1 success
      if r.width != 0:
        term.attrs.width = r.width
        if r.widthPx != 0:
          term.attrs.ppc = r.widthPx div r.width
      if r.height != 0:
        term.attrs.height = r.height
        if r.heightPx != 0:
          term.attrs.ppl = r.heightPx div r.height
      if windowOnly:
        return
      if qaAnsiColor in r.attrs:
        term.colorMode = cmANSI
      if qaRGB in r.attrs:
        term.colorMode = cmTrueColor
      if qaSixel in r.attrs:
        term.imageMode = imSixel
        term.sixelRegisterNum = clamp(r.registers, 16, 1024)
      if qaKittyImage in r.attrs:
        term.imageMode = imKitty
      # just assume the terminal doesn't choke on these.
      term.formatMode = {ffStrike, ffOverline}
      if r.bgcolor.isSome:
        term.defaultBackground = r.bgcolor.get
      if r.fgcolor.isSome:
        term.defaultForeground = r.fgcolor.get
    else:
      # something went horribly wrong. set result to DA1 fail, pager will
      # alert the user
      result = tsrDA1Fail
  if windowOnly:
    return
  if term.colorMode != cmTrueColor:
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["24bit", "truecolor"]:
      term.colorMode = cmTrueColor
  when termcap_found:
    term.loadTermcap()
    if term.tc != nil:
      term.smcup = term.hascap ti
      if term.colorMode < cmEightBit and term.tc.numCaps[Co] == 256:
        # due to termcap limitations, 256 is the highest possible number here
        term.colorMode = cmEightBit
      elif term.colorMode < cmANSI and term.tc.numCaps[Co] >= 8:
        term.colorMode = cmANSI
      if term.hascap ZH:
        term.formatMode.incl(ffItalic)
      if term.hascap us:
        term.formatMode.incl(ffUnderline)
      if term.hascap md:
        term.formatMode.incl(ffBold)
      if term.hascap mr:
        term.formatMode.incl(ffReverse)
      if term.hascap mb:
        term.formatMode.incl(ffBlink)
  else:
    term.smcup = true
    term.formatMode = {low(FormatFlags)..high(FormatFlags)}

type
  MouseInputType* = enum
    mitPress = "press", mitRelease = "release", mitMove = "move"

  MouseInputMod* = enum
    mimShift = "shift", mimCtrl = "ctrl", mimMeta = "meta"

  MouseInputButton* = enum
    mibLeft = (1, "left")
    mibMiddle = (2, "middle")
    mibRight = (3, "right")
    mibWheelUp = (4, "wheelUp")
    mibWheelDown = (5, "wheelDown")
    mibWheelLeft = (6, "wheelLeft")
    mibWheelRight = (7, "wheelRight")
    mibThumbInner = (8, "thumbInner")
    mibThumbTip = (9, "thumbTip")
    mibButton10 = (10, "button10")
    mibButton11 = (11, "button11")

  MouseInput* = object
    t*: MouseInputType
    button*: MouseInputButton
    mods*: set[MouseInputMod]
    col*: int
    row*: int

proc parseMouseInput*(term: Terminal): Opt[MouseInput] =
  template fail =
    return err()
  var btn = 0
  while (let c = term.readChar(); c != ';'):
    let n = decValue(c)
    if n == -1:
      fail
    btn *= 10
    btn += n
  var mods: set[MouseInputMod] = {}
  if (btn and 4) != 0:
    mods.incl(mimShift)
  if (btn and 8) != 0:
    mods.incl(mimCtrl)
  if (btn and 16) != 0:
    mods.incl(mimMeta)
  var px = 0
  while (let c = term.readChar(); c != ';'):
    let n = decValue(c)
    if n == -1:
      fail
    px *= 10
    px += n
  var py = 0
  var c: char
  while (c = term.readChar(); c notin {'m', 'M'}):
    let n = decValue(c)
    if n == -1:
      fail
    py *= 10
    py += n
  var t = if c == 'M': mitPress else: mitRelease
  if (btn and 32) != 0:
    t = mitMove
  var button = (btn and 3) + 1
  if (btn and 64) != 0:
    button += 3
  if (btn and 128) != 0:
    button += 7
  if button notin int(MouseInputButton.low)..int(MouseInputButton.high):
    return err()
  ok(MouseInput(
    t: t,
    mods: mods,
    button: MouseInputButton(button),
    col: px - 1,
    row: py - 1
  ))

proc windowChange*(term: Terminal) =
  discard term.detectTermAttributes(windowOnly = true)
  term.applyConfigDimensions()
  term.canvas = newFixedGrid(term.attrs.width, term.attrs.height)
  term.cleared = false

proc initScreen(term: Terminal) =
  # note: deinit happens in quit()
  if term.set_title:
    term.write(XTPUSHTITLE)
  if term.smcup:
    term.write(term.enableAltScreen())
  if term.config.input.use_mouse:
    term.enableMouse()

proc start*(term: Terminal; istream: PosixStream): TermStartResult =
  term.istream = istream
  if term.isatty():
    term.enableRawMode()
  result = term.detectTermAttributes(windowOnly = false)
  if result == tsrDA1Fail:
    term.config.display.query_da1 = false
  term.applyConfig()
  if term.isatty():
    term.initScreen()
  term.canvas = newFixedGrid(term.attrs.width, term.attrs.height)

proc restart*(term: Terminal) =
  if term.isatty():
    term.enableRawMode()
    if term.stdinWasUnblocked:
      term.unblockStdin()
      term.stdinWasUnblocked = false
    term.initScreen()

proc newTerminal*(outfile: File; config: Config): Terminal =
  return Terminal(
    outfile: outfile,
    config: config,
    defaultBackground: ColorsRGB["black"],
    defaultForeground: ColorsRGB["white"]
  )
