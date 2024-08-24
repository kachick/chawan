import std/options
import std/os
import std/posix
import std/strutils
import std/tables
import std/termios
import std/unicode

import bindings/termcap
import chagashi/charset
import chagashi/decoder
import chagashi/encoder
import config/config
import img/bitmap
import io/dynstream
import js/base64
import types/blob
import types/cell
import types/color
import types/opt
import types/winattrs
import utils/strwidth
import utils/twtstr

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

  CanvasImage* = ref object
    pid: int
    imageId: int
    x: int
    y: int
    offx: int
    offy: int
    dispw: int
    disph: int
    damaged: bool
    marked*: bool
    kittyId: int
    bmp: Bitmap
    # 0 if kitty
    erry: int
    # absolute x, y in container
    rx: int
    ry: int
    data: Blob

  Terminal* = ref object
    cs*: Charset
    config: Config
    istream*: PosixStream
    outfile: File
    cleared: bool
    canvas: seq[FixedCell]
    canvasImages*: seq[CanvasImage]
    imagesToClear*: seq[CanvasImage]
    lineDamage: seq[int]
    attrs*: WindowAttributes
    colorMode: ColorMode
    formatMode: set[FormatFlag]
    imageMode*: ImageMode
    smcup: bool
    tc: Termcap
    setTitle: bool
    stdinUnblocked: bool
    stdinWasUnblocked: bool
    origTermios: Termios
    defaultBackground*: RGBColor
    defaultForeground: RGBColor
    ibuf*: string # buffer for chars when we can't process them
    sixelRegisterNum*: int
    sixelMaxWidth: int
    sixelMaxHeight: int
    kittyId: int # counter for kitty image (*not* placement) ids.
    cursorx: int
    cursory: int
    colorMap: array[16, RGBColor]

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

# report cell size
const CELLSIZE = CSI(16, "t")

# report window size in chars
const GEOMCELL = CSI(18, "t")

# allow shift-key to override mouse protocol
const XTSHIFTESCAPE = CSI(">0s")

# query sixel register number
template XTSMGRAPHICS(pi, pa, pv: untyped): string =
  CSI("?" & $pi, $pa, $pv & "S")

# number of color registers
const XTNUMREGS = XTSMGRAPHICS(1, 1, 0)

# image dimensions
const XTIMGDIMS = XTSMGRAPHICS(2, 1, 0)

# horizontal & vertical position
template HVP(s: varargs[string, `$`]): string =
  CSI(s) & "f"

# erase line
template EL(): string =
  CSI() & "K"

# erase display
template ED(): string =
  CSI() & "J"

# select graphic rendition
template SGR*(s: varargs[string, `$`]): string =
  CSI(s) & "m"

# device control string
const DCSSTART = "\eP"

template DCS(a, b: char; s: varargs[string]): string =
  DCSSTART & a & b & s.join(';') & "\e\\"

template XTGETTCAP(s: varargs[string, `$`]): string =
  DCS('+', 'q', s)

const XTGETRGB = XTGETTCAP("524742")

# OS command
template OSC(s: varargs[string, `$`]): string =
  "\e]" & s.join(';') & '\a'

template XTSETTITLE(s: string): string =
  OSC(0, s)

const XTGETFG = OSC(10, "?") # get foreground color
const XTGETBG = OSC(11, "?") # get background color
const XTGETANSI = block: # get ansi colors
  var s = ""
  for n in 0 ..< 16:
    s &= OSC(4, n, "?")
  s

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

# show/hide cursor
const CNORM = DECSET(25)
const CIVIS = DECRST(25)

# application program command

# This is only used in kitty images, and join()'ing kilobytes of base64
# is rather inefficient so we don't use a template.
const APC = "\e_"
const ST = "\e\\"

const KITTYQUERY = APC & "Gi=1,a=q;" & ST

when TermcapFound:
  func hascap(term: Terminal; c: TermcapCap): bool = term.tc.caps[c] != nil
  func cap(term: Terminal; c: TermcapCap): string = $term.tc.caps[c]
  func ccap(term: Terminal; c: TermcapCap): cstring = term.tc.caps[c]

proc write(term: Terminal; s: openArray[char]) =
  # write() calls $ on s, so we must writeBuffer
  if s.len > 0:
    discard term.outfile.writeBuffer(unsafeAddr s[0], s.len)

proc write(term: Terminal; s: string) =
  term.outfile.write(s)

proc write(term: Terminal; s: cstring) =
  term.outfile.write(s)

proc readChar*(term: Terminal): char =
  if term.ibuf.len == 0:
    result = term.istream.sreadChar()
  else:
    result = term.ibuf[0]
    term.ibuf.delete(0..0)

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc cursorGoto(term: Terminal; x, y: int): string =
  when TermcapFound:
    if term.tc != nil:
      return $tgoto(term.ccap cm, cint(x), cint(y))
  return HVP(y + 1, x + 1)

proc clearEnd(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil:
      return term.cap ce
  return EL()

proc clearDisplay(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil:
      return term.cap cd
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
  when TermcapFound:
    if term.tc != nil:
      return term.cap me
  return SGR()

proc startFormat(term: Terminal; flag: FormatFlag): string =
  when TermcapFound:
    if term.tc != nil:
      case flag
      of ffBold: return term.cap md
      of ffUnderline: return term.cap us
      of ffReverse: return term.cap mr
      of ffBlink: return term.cap mb
      of ffItalic: return term.cap ZH
      else: discard
  return SGR(FormatCodes[flag].s)

proc endFormat(term: Terminal; flag: FormatFlag): string =
  when TermcapFound:
    if term.tc != nil:
      case flag
      of ffUnderline: return term.cap ue
      of ffItalic: return term.cap ZR
      else: discard
  return SGR(FormatCodes[flag].e)

proc setCursor*(term: Terminal; x, y: int) =
  assert x >= 0 and y >= 0
  if x != term.cursorx or y != term.cursory:
    term.write(term.cursorGoto(x, y))
    term.cursorx = x
    term.cursory = y

proc enableAltScreen(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil and term.hascap ti:
      return term.cap ti
  return SMCUP

proc disableAltScreen(term: Terminal): string =
  when TermcapFound:
    if term.tc != nil and term.hascap te:
      return term.cap te
  return RMCUP

func mincontrast(term: Terminal): int32 =
  return term.config.display.minimum_contrast

proc getRGB(term: Terminal; a: CellColor; termDefault: RGBColor): RGBColor =
  case a.t
  of ctNone:
    return termDefault
  of ctANSI:
    if a.color >= 16:
      return EightBitColor(a.color).toRGB()
    return term.colorMap[a.color]
  of ctRGB:
    return a.rgbcolor

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(term: Terminal; rgb, termDefault: RGBColor):
    CellColor =
  var a = 0
  var n = -1
  if rgb == termDefault:
    return defaultColor
  for i in -1 .. term.colorMap.high:
    let color = if i >= 0:
      term.colorMap[i]
    else:
      termDefault
    if color == rgb:
      return ANSIColor(i).cellColor()
    {.push overflowChecks:off.}
    let x = int(color.r) - int(rgb.r)
    let y = int(color.g) - int(rgb.g)
    let z = int(color.b) - int(rgb.b)
    let xx = x * x
    let yy = y * y
    let zz = z * z
    let b = xx + yy + zz
    {.pop.}
    if i == -1 or b < a:
      n = i
      a = b
  return if n == -1: defaultColor else: ANSIColor(n).cellColor()

# Return a fgcolor contrasted to the background by term.mincontrast.
proc correctContrast(term: Terminal; bgcolor, fgcolor: CellColor): CellColor =
  let contrast = term.mincontrast
  let cfgcolor = fgcolor
  let bgcolor = term.getRGB(bgcolor, term.defaultBackground)
  let fgcolor = term.getRGB(fgcolor, term.defaultForeground)
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
      return term.approximateANSIColor(newrgb, term.defaultForeground)
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
  for flag in FormatFlag:
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
      cellf.bgcolor = term.approximateANSIColor(cellf.bgcolor.rgbcolor,
        term.defaultBackground)
    if cellf.fgcolor.t == ctANSI and cellf.fgcolor.color > 15:
      cellf.fgcolor = cellf.fgcolor.eightbit.toRGB().cellColor()
    if cellf.fgcolor.t == ctRGB:
      if cellf.bgcolor.t == ctNone:
        cellf.fgcolor = term.approximateANSIColor(cellf.fgcolor.rgbcolor,
          term.defaultForeground)
      else:
        # ANSI fgcolor + bgcolor at the same time is broken
        cellf.fgcolor = defaultColor
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    if cellf.fgcolor != format.fgcolor:
      # print
      case cellf.fgcolor.t
      of ctNone: result &= SGR(39)
      of ctANSI: result &= ansiSGR(cellf.fgcolor.color, 0)
      else: discard
    if cellf.bgcolor != format.bgcolor:
      case cellf.bgcolor.t
      of ctNone: result &= SGR(49)
      of ctANSI: result &= ansiSGR(cellf.bgcolor.color, 10)
      else: discard
  of cmEightBit:
    # quantize
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = cellf.bgcolor.rgbcolor.toEightBit().cellColor()
    if cellf.fgcolor.t == ctRGB:
      cellf.fgcolor = cellf.fgcolor.rgbcolor.toEightBit().cellColor()
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    if cellf.fgcolor != format.fgcolor:
      case cellf.fgcolor.t
      of ctNone: result &= SGR(39)
      of ctANSI: result &= eightBitSGR(cellf.fgcolor.color, 0)
      of ctRGB: discard
    if cellf.bgcolor != format.bgcolor:
      case cellf.bgcolor.t
      of ctNone: result &= SGR(49)
      of ctANSI: result &= eightBitSGR(cellf.bgcolor.color, 10)
      of ctRGB: discard
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
  if term.setTitle:
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
  # Output is not utf-8, so we must encode it first.
  var success = false
  return newTextEncoder(term.cs).encodeAll(str, success)

proc generateFullOutput(term: Terminal): string =
  var format = Format()
  result &= term.cursorGoto(0, 0)
  result &= term.resetFormat()
  result &= term.clearDisplay()
  for y in 0 ..< term.attrs.height:
    if y != 0:
      result &= "\r\n"
    var w = 0
    for x in 0 ..< term.attrs.width:
      while w < x:
        result &= " "
        inc w
      let cell = term.canvas[y * term.attrs.width + x]
      result &= term.processFormat(format, cell.format)
      result &= term.processOutputString(cell.str, w)
    term.lineDamage[y] = term.attrs.width

proc generateSwapOutput(term: Terminal): string =
  var vy = -1
  for y in 0 ..< term.attrs.height:
    # set cx to x of the first change
    let cx = term.lineDamage[y]
    # w will track the current position on screen
    var w = cx
    if cx < term.attrs.width:
      if cx == 0 and vy != -1:
        while vy < y:
          result &= "\r\n"
          inc vy
      else:
        result &= term.cursorGoto(cx, y)
        vy = y
      result &= term.resetFormat()
      var format = Format()
      for x in cx ..< term.attrs.width:
        while w < x: # if previous cell had no width, catch up with x
          result &= ' '
          inc w
        let cell = term.canvas[y * term.attrs.width + x]
        result &= term.processFormat(format, cell.format)
        result &= term.processOutputString(cell.str, w)
      if w < term.attrs.width:
        result &= term.clearEnd()
      # damage is gone
      term.lineDamage[y] = term.attrs.width

proc hideCursor*(term: Terminal) =
  when TermcapFound:
    if term.tc != nil:
      term.write(term.ccap vi)
      return
  term.write(CIVIS)

proc showCursor*(term: Terminal) =
  when TermcapFound:
    if term.tc != nil:
      term.write(term.ccap ve)
      return
  term.write(CNORM)

proc writeGrid*(term: Terminal; grid: FixedGrid; x = 0, y = 0) =
  for ly in y ..< y + grid.height:
    var lastx = 0
    for lx in x ..< x + grid.width:
      let i = ly * term.attrs.width + lx
      let cell = grid[(ly - y) * grid.width + (lx - x)]
      if term.canvas[i].str != "":
        # if there is a change, we have to start from the last x with
        # a string (otherwise we might overwrite half of a double-width char)
        lastx = lx
      if cell != term.canvas[i]:
        term.canvas[i] = cell
        term.lineDamage[ly] = min(term.lineDamage[ly], lastx)

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
  term.attrs.widthPx = term.attrs.ppc * term.attrs.width
  term.attrs.heightPx = term.attrs.ppl * term.attrs.height
  if term.imageMode == imSixel:
    if term.sixelMaxWidth == 0:
      term.sixelMaxWidth = term.attrs.widthPx
    if term.sixelMaxHeight == 0:
      term.sixelMaxHeight = term.attrs.heightPx

proc applyConfig(term: Terminal) =
  # colors, formatting
  if term.config.display.color_mode.isSome:
    term.colorMode = term.config.display.color_mode.get
  if term.config.display.format_mode.isSome:
    term.formatMode = term.config.display.format_mode.get
  for fm in FormatFlag:
    if fm in term.config.display.no_format_mode:
      term.formatMode.excl(fm)
  if term.config.display.image_mode.isSome:
    term.imageMode = term.config.display.image_mode.get
  if term.isatty():
    if term.config.display.alt_screen.isSome:
      term.smcup = term.config.display.alt_screen.get
    term.setTitle = term.config.display.set_title
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
  if term.config.display.force_clear or not term.cleared:
    term.outfile.write(term.generateFullOutput())
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput())
  term.cursorx = -1
  term.cursory = -1

func findImage(term: Terminal; pid, imageId: int; bmp: Bitmap;
    rx, ry, erry, offx, dispw: int): CanvasImage =
  for it in term.canvasImages:
    if it.pid == pid and it.imageId == imageId and
        it.bmp.width == bmp.width and it.bmp.height == bmp.height and
        it.rx == rx and it.ry == ry and
        (term.imageMode != imSixel or it.erry == erry and it.dispw == dispw and
          it.offx == offx):
      return it
  return nil

# x, y, maxw, maxh in cells
# x, y can be negative, then image starts outside the screen
proc positionImage(term: Terminal; image: CanvasImage; x, y, maxw, maxh: int):
    bool =
  image.x = x
  image.y = y
  let xpx = x * term.attrs.ppc
  let ypx = y * term.attrs.ppl
  # calculate offset inside image to start from
  image.offx = -min(xpx, 0)
  image.offy = -min(ypx, 0)
  # calculate maximum image size that fits on the screen relative to the image
  # origin (*not* offx/offy)
  let maxwpx = maxw * term.attrs.ppc
  let maxhpx = maxh * term.attrs.ppl
  var width = int(image.bmp.width)
  var height = int(image.bmp.height)
  if term.imageMode == imSixel:
    #TODO a better solution would be to split up the image here so that it
    # still gets fully displayed on the screen, or at least downscale it...
    width = min(width - image.offx, term.sixelMaxWidth) + image.offx
    height = min(height - image.offy, term.sixelMaxHeight) + image.offy
  image.dispw = min(width + xpx, maxwpx) - xpx
  image.disph = min(height + ypx, maxhpx) - ypx
  image.damaged = true
  return image.dispw > image.offx and image.disph > image.offy

proc clearImage*(term: Terminal; image: CanvasImage; maxh: int) =
  case term.imageMode
  of imNone: discard
  of imSixel:
    # we must clear sixels the same way as we clear text.
    let ey = min(image.y + int(image.bmp.height), maxh)
    let x = max(image.x, 0)
    for y in max(image.y, 0) ..< ey:
      term.lineDamage[y] = min(x, term.lineDamage[y])
  of imKitty:
    term.imagesToClear.add(image)

proc clearImages*(term: Terminal; maxh: int) =
  for image in term.canvasImages:
    if not image.marked:
      term.clearImage(image, maxh)
    image.marked = false

proc loadImage*(term: Terminal; bmp: Bitmap; data: Blob; pid, imageId,
    x, y, rx, ry, maxw, maxh, erry, offx, dispw: int): CanvasImage =
  if (let image = term.findImage(pid, imageId, bmp, rx, ry, erry, offx, dispw);
      image != nil):
    # reuse image on screen
    if image.x != x or image.y != y:
      # only clear sixels; with kitty we just move the existing image
      if term.imageMode == imSixel:
        term.clearImage(image, maxh)
      if not term.positionImage(image, x, y, maxw, maxh):
        # no longer on screen
        return nil
    elif term.imageMode == imSixel:
      # check if any line of our image is damaged
      let ey = min(image.y + int(image.bmp.height), maxh)
      let mx = (image.offx + image.dispw) div term.attrs.ppc
      for y in max(image.y, 0) ..< ey:
        if term.lineDamage[y] < mx:
          image.damaged = true
          break
    # only mark old images; new images will not be checked until the next
    # initImages call.
    image.marked = true
    return image
  # new image
  let image = CanvasImage(
    bmp: bmp,
    pid: pid,
    imageId: imageId,
    data: data,
    rx: rx,
    ry: ry,
    erry: erry
  )
  if term.positionImage(image, x, y, maxw, maxh):
    return image
  # no longer on screen
  return nil

func getOffYIdx(data: openArray[char]; y, starti: int): int32 =
  let i = starti + (y div 6) * 4
  return int32(data[i]) or
    (int32(data[i + 1]) shl 8) or
    (int32(data[i + 2]) shl 16) or
    (int32(data[i + 3]) shl 24)

proc outputSixelImage(term: Terminal; x, y: int; image: CanvasImage;
    data: openArray[char]) =
  let offx = image.offx
  let offy = image.offy
  let dispw = image.dispw
  let disph = image.disph
  let bmp = image.bmp
  var outs = term.cursorGoto(x, y)
  outs &= DCSSTART & 'q'
  # set raster attributes
  let realw = dispw - offx
  var realh = disph - offy
  #if disph < int(bmp.height):
  #  realh -= image.erry
  outs &= "\"1;1;" & $realw & ';' & $realh
  term.write(outs)
  let sraLen = uint32(data[0]) or
    (uint32(data[1]) shl 8) or
    (uint32(data[2]) shl 16) or
    (uint32(data[3]) shl 24)
  let preludeLen = int(sraLen + 4)
  term.write(data.toOpenArray(4, 4 + int(sraLen) - 1))
  let lookupTableLen = ((int(bmp.height) + 5) div 6 + 1) * 4
  let L = data.len - lookupTableLen
  # Note: we only crop images when it is possible to do so in near constant
  # time. Otherwise, the image is re-coded in a cropped form.
  if realh == int(bmp.height):
    term.write(data.toOpenArray(preludeLen, L - 1))
  else:
    let offyi = data.getOffYIdx(offy, L)
    var e = disph
    if disph < int(bmp.height):
      e -= image.erry
    let endyi = data.getOffYIdx(e, L)
    if endyi <= offyi:
      return
    let si = preludeLen + int(offyi)
    let ei = preludeLen + int(endyi) - 1
    assert offyi < endyi
    assert ei <= data.len - lookupTableLen
    term.write(data.toOpenArray(si, ei - 1))
    var ndash = 0
    for c in data.toOpenArray(si, ei - 1):
      if c == '-':
        inc ndash
    let herry = realh - (realh div 6) * 6
    if herry > 0 and disph < int(bmp.height):
      # can't write out the last row completely; mask off the bottom part.
      let mask = (1u8 shl herry) - 1
      var s = "-"
      var i = ei + 1
      inc ndash
      while i < L and (let c = data[i]; c notin {'-', '\e'}): # newline or ST
        let u = uint8(c) - 0x3F # may underflow, but that's no problem
        if u < 0x40:
          s &= char((u and mask) + 0x3F)
        else:
          s &= c
        inc i
      term.write(s)
    term.write(ST)

proc outputSixelImage(term: Terminal; x, y: int; image: CanvasImage) =
  var p = cast[ptr UncheckedArray[char]](image.data.buffer)
  let H = int(image.data.size - 1)
  term.outputSixelImage(x, y, image, p.toOpenArray(0, H))

proc outputKittyImage(term: Terminal; x, y: int; image: CanvasImage) =
  var outs = term.cursorGoto(x, y) &
    APC & "GC=1,s=" & $image.bmp.width & ",v=" & $image.bmp.height &
    ",x=" & $image.offx & ",y=" & $image.offy &
    ",w=" & $image.dispw & ",h=" & $image.disph &
    # for now, we always use placement id 1
    ",p=1,q=2"
  if image.kittyId != 0:
    outs &= ",i=" & $image.kittyId & ",a=p;" & ST
    term.write(outs)
    term.flush()
    return
  inc term.kittyId # skip i=0
  image.kittyId = term.kittyId
  outs &= ",i=" & $image.kittyId
  const MaxBytes = 4096 * 3 div 4
  var i = MaxBytes
  # transcode to RGB
  let p = cast[ptr UncheckedArray[uint8]](image.data.buffer)
  let L = int(image.data.size)
  let m = if i < L: '1' else: '0'
  outs &= ",a=T,f=100,m=" & m & ';'
  outs.btoa(p.toOpenArray(0, min(L, i) - 1))
  outs &= ST
  term.write(outs)
  while i < L:
    let j = i
    i += MaxBytes
    let m = if i < L: '1' else: '0'
    var outs = APC & "Gm=" & m & ';'
    outs.btoa(p.toOpenArray(j, min(L, i) - 1))
    outs &= ST
    term.write(outs)

proc outputImages*(term: Terminal) =
  if term.imageMode == imKitty:
    # clean up unused kitty images
    var s = ""
    for image in term.imagesToClear:
      if image.kittyId == 0:
        continue # maybe it was never displayed...
      s &= APC & "Ga=d,d=I,i=" & $image.kittyId & ",p=1,q=2;" & ST
    term.write(s)
    term.imagesToClear.setLen(0)
  for image in term.canvasImages:
    if image.damaged:
      assert image.dispw > 0 and image.disph > 0
      let x = max(image.x, 0)
      let y = max(image.y, 0)
      case term.imageMode
      of imNone: assert false
      of imSixel: term.outputSixelImage(x, y, image)
      of imKitty: term.outputKittyImage(x, y, image)
      image.damaged = false

proc clearCanvas*(term: Terminal) =
  term.cleared = false
  let maxw = term.attrs.width
  let maxh = term.attrs.height - 1
  var newImages: seq[CanvasImage] = @[]
  for image in term.canvasImages:
    if term.positionImage(image, image.x, image.y, maxw, maxh):
      image.damaged = true
      image.marked = true
      newImages.add(image)
  term.clearImages(maxh)
  term.canvasImages = newImages

# see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
proc disableRawMode(term: Terminal) =
  discard tcSetAttr(term.istream.fd, TCSAFLUSH, addr term.origTermios)

proc enableRawMode(term: Terminal) =
  discard tcGetAttr(term.istream.fd, addr term.origTermios)
  var raw = term.origTermios
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
    if term.setTitle:
      term.write(XTPOPTITLE)
    term.showCursor()
    term.clearCanvas()
    if term.stdinUnblocked:
      term.restoreStdin()
      term.stdinWasUnblocked = true
  term.flush()

when TermcapFound:
  proc loadTermcap(term: Terminal) =
    var tname = getEnv("TERM")
    if tname == "":
      tname = "dosansi"
    let tc = Termcap()
    var res = tgetent(cast[cstring](addr tc.bp), cstring(tname))
    if res == 0: # retry as dosansi
      res = tgetent(cast[cstring](addr tc.bp), "dosansi")
    if res > 0: # success
      term.tc = tc
      for id in TermcapCap:
        tc.caps[id] = tgetstr(cstring($id), cast[ptr cstring](addr tc.funcstr))
      for id in TermcapCapNumeric:
        tc.numCaps[id] = tgetnum(cstring($id))

type
  QueryAttrs = enum
    qaAnsiColor, qaRGB, qaSixel, qaKittyImage

  QueryResult = object
    success: bool
    attrs: set[QueryAttrs]
    fgcolor: Option[RGBColor]
    bgcolor: Option[RGBColor]
    colorMap: seq[tuple[n: int; rgb: RGBColor]]
    widthPx: int
    heightPx: int
    ppc: int
    ppl: int
    width: int
    height: int
    sixelMaxWidth: int
    sixelMaxHeight: int
    registers: int

proc consumeIntUntil(term: Terminal; sentinel: char): int =
  var n = 0
  while (let c = term.readChar(); c != sentinel):
    if (let x = decValue(c); x != -1):
      n *= 10
      n += x
    else:
      return -1
  return n

proc queryAttrs(term: Terminal; windowOnly: bool): QueryResult =
  const tcapRGB = 0x524742 # RGB supported?
  if not windowOnly:
    var outs = ""
    if term.config.display.default_background_color.isNone:
      outs &= XTGETBG
    if term.config.display.default_foreground_color.isNone:
      outs &= XTGETFG
    if term.config.display.image_mode.isNone:
      outs &= KITTYQUERY
      outs &= XTNUMREGS
      outs &= XTIMGDIMS
    elif term.config.display.image_mode.get == imSixel:
      outs &= XTNUMREGS
      outs &= XTIMGDIMS
    if term.config.display.color_mode.isNone:
      outs &= XTGETRGB
    outs &=
      XTGETANSI &
      GEOMPIXEL &
      CELLSIZE &
      GEOMCELL &
      DA1
    term.outfile.write(outs)
  else:
    const outs =
      GEOMPIXEL &
      CELLSIZE &
      GEOMCELL &
      XTIMGDIMS &
      DA1
    term.outfile.write(outs)
  term.flush()
  result = QueryResult(success: false, attrs: {})
  while true:
    template consume(term: Terminal): char =
      term.readChar()
    template fail =
      return
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
      let n = term.consumeIntUntil(sentinel)
      if n == -1:
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
          if params.len >= 4:
            if params[0] == 2 and params[1] == 0:
              result.sixelMaxWidth = params[2]
              result.sixelMaxHeight = params[3]
          if params.len >= 3:
            if params[0] == 1 and params[1] == 0:
              result.registers = params[2]
      of '4', '6', '8': # GEOMPIXEL, CELLSIZE, GEOMCELL
        term.expect ';'
        let height = term.consume_int_till ';'
        let width = term.consume_int_till 't'
        if c == '4': # GEOMSIZE
          result.widthPx = width
          result.heightPx = height
        elif c == '6': # CELLSIZE
          result.ppc = width
          result.ppl = height
        elif c == '8': # GEOMCELL
          result.width = width
          result.height = height
      else: fail
    of ']':
      # OSC
      let c = term.consumeIntUntil(';')
      var n: int
      if c == 4:
        n = term.consumeIntUntil(';')
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
            if i == 0: # 1st place - expand it for when we don't get a 2nd place
              val = (v shl 4) or v
            elif i == 1: # 2nd place - clear expanded placeholder from 1st place
              val = (val and not 0xFu8) or v
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
        let C = rgb(r, g, b)
        if c == 4:
          result.colorMap.add((n, C))
        elif c == 10:
          result.fgcolor = some(C)
        else: # 11
          result.bgcolor = some(C)
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
  var res = tsrSuccess
  if not term.isatty():
    return res
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
        if r.ppc != 0:
          term.attrs.ppc = r.ppc
        elif r.widthPx != 0:
          term.attrs.ppc = r.widthPx div r.width
      if r.height != 0:
        term.attrs.height = r.height
        if r.ppl != 0:
          term.attrs.ppl = r.ppl
        elif r.heightPx != 0:
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
        term.sixelMaxWidth = r.sixelMaxWidth
        term.sixelMaxHeight = r.sixelMaxHeight
      if qaKittyImage in r.attrs:
        term.imageMode = imKitty
      # just assume the terminal doesn't choke on these.
      term.formatMode = {ffStrike, ffOverline}
      if r.bgcolor.isSome:
        term.defaultBackground = r.bgcolor.get
      if r.fgcolor.isSome:
        term.defaultForeground = r.fgcolor.get
      for (n, rgb) in r.colorMap:
        term.colorMap[n] = rgb
    else:
      term.sixelRegisterNum = 256
      # something went horribly wrong. set result to DA1 fail, pager will
      # alert the user
      res = tsrDA1Fail
  if windowOnly:
    return res
  if term.colorMode != cmTrueColor:
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["24bit", "truecolor"]:
      term.colorMode = cmTrueColor
  when TermcapFound:
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
      return res
  term.smcup = true
  term.formatMode = {FormatFlag.low..FormatFlag.high}
  return res

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
  term.canvas = newSeq[FixedCell](term.attrs.width * term.attrs.height)
  term.lineDamage = newSeq[int](term.attrs.height)
  term.clearCanvas()

proc initScreen(term: Terminal) =
  # note: deinit happens in quit()
  if term.setTitle:
    term.write(XTPUSHTITLE)
  if term.smcup:
    term.write(term.enableAltScreen())
  if term.config.input.use_mouse:
    term.enableMouse()
  term.cursorx = -1
  term.cursory = -1

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
  term.canvas = newSeq[FixedCell](term.attrs.width * term.attrs.height)
  term.lineDamage = newSeq[int](term.attrs.height)

proc restart*(term: Terminal) =
  if term.isatty():
    term.enableRawMode()
    if term.stdinWasUnblocked:
      term.unblockStdin()
      term.stdinWasUnblocked = false
    term.initScreen()

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

proc newTerminal*(outfile: File; config: Config): Terminal =
  const DefaultBackground = namedRGBColor("black").get
  const DefaultForeground = namedRGBColor("white").get
  return Terminal(
    outfile: outfile,
    config: config,
    defaultBackground: DefaultBackground,
    defaultForeground: DefaultForeground,
    colorMap: ANSIColorMap
  )
