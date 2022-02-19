import sequtils
import streams
import strutils
import sugar
import unicode

import html/dom
import layout/box
import types/color
import utils/twtstr

type
  FormatFlags* = enum
    FLAG_BOLD
    FLAG_ITALIC
    FLAG_UNDERLINE
    FLAG_REVERSE
    FLAG_STRIKE
    FLAG_OVERLINE
    FLAG_BLINK

  Format* = object
    fgcolor*: CellColor
    bgcolor*: CellColor
    flags: set[FormatFlags]

  Cell* = object of RootObj
    format*: Format
    node*: Node

  FormatCell* = object of Cell
    pos*: int
    computed*: ComputedFormat

  FlexibleLine* = object
    str*: string
    formats*: seq[FormatCell]

  FlexibleGrid* = seq[FlexibleLine]

  FixedCell* = object of Cell
    runes*: seq[Rune]

  FixedGrid* = seq[FixedCell]

const FormatCodes: array[FormatFlags, tuple[s: int, e: int]] = [
  FLAG_BOLD: (1, 22),
  FLAG_ITALIC: (3, 23),
  FLAG_UNDERLINE: (4, 24),
  FLAG_REVERSE: (7, 27),
  FLAG_STRIKE: (9, 29),
  FLAG_OVERLINE: (53, 55),
  FLAG_BLINK: (5, 25),
]

template flag_template(format: Format, val: bool, flag: FormatFlags) =
  if val: format.flags.incl(flag)
  else: format.flags.excl(flag)

template `italic=`*(f: var Format, b: bool) = flag_template f, b, FLAG_ITALIC
template `bold=`*(f: var Format, b: bool) = flag_template f, b, FLAG_BOLD
template `underline=`*(f: var Format, b: bool) = flag_template f, b, FLAG_UNDERLINE
template `reverse=`*(f: var Format, b: bool) = flag_template f, b, FLAG_REVERSE
template `strike=`*(f: var Format, b: bool) = flag_template f, b, FLAG_STRIKE
template `overline=`*(f: var Format, b: bool) = flag_template f, b, FLAG_OVERLINE
template `blink=`*(f: var Format, b: bool) = flag_template f, b, FLAG_BLINK

#TODO ?????
func `==`*(a: FixedCell, b: FixedCell): bool =
  return a.format == b.format and
    a.runes == b.runes and
    a.node == b.node

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return newSeq[FixedCell](w * h)

func width*(line: FlexibleLine): int =
  return line.str.width()

func width*(cell: FixedCell): int =
  return cell.runes.width()

func newFormat*(): Format =
  return Format(fgcolor: defaultColor, bgcolor: defaultColor)

func findFormatN*(line: FlexibleLine, pos: int): int =
  var i = 0
  while i < line.formats.len:
    if line.formats[i].pos > pos:
      break
    inc i 
  return i

func findFormat*(line: FlexibleLine, pos: int): FormatCell =
  let i = line.findFormatN(pos) - 1
  if i != -1:
    result = line.formats[i]
  else:
    result.pos = -1

func findNextFormat*(line: FlexibleLine, pos: int): FormatCell =
  let i = line.findFormatN(pos)
  if i < line.formats.len:
    result = line.formats[i]
  else:
    result.pos = -1

func subformats*(formats: seq[FormatCell], pos: int): seq[FormatCell] =
  var i = 0
  while i < formats.len:
    if formats[i].pos >= pos:
      if result.len == 0 and i > 0:
        var f = formats[i - 1]
        f.pos = 0
        result.add(f)
      var f = formats[i]
      f.pos -= pos
      result.add(f)
    inc i

  if result.len == 0 and i > 0:
    var f = formats[i - 1]
    f.pos = 0
    result.add(f)

proc setLen*(line: var FlexibleLine, len: int) =
  for i in 0 ..< line.formats.len:
    if line.formats[i].pos >= len:
      line.formats.setLen(i)
      break
  line.str.setLen(len)
  #line.formats = line.formats.filter((x) => x.pos < len)

proc add*(a: var FlexibleLine, b: FlexibleLine) =
  let l = a.str.len
  a.formats.add(b.formats.map((x) => FormatCell(format: x.format, node: x.node, pos: l + x.pos)))
  a.str &= b.str

proc addLine*(grid: var FlexibleGrid) =
  grid.add(FlexibleLine())

proc addFormat*(line: var FlexibleLine, pos: int, format: Format) =
  line.formats.add(FormatCell(format: format, pos: line.str.len))

proc addFormat*(line: var FlexibleLine, pos: int, format: Format, computed: ComputedFormat) =
  if computed != nil and line.formats.len > 0 and line.formats[^1].computed == computed and line.formats[^1].format.bgcolor != format.bgcolor:
    return
  if computed == nil:
    line.formats.add(FormatCell(format: format, pos: pos))
  else:
    line.formats.add(FormatCell(format: format, computed: computed, node: computed.node, pos: pos))

template inc_check(i: int) =
  inc i
  if i >= buf.len:
    return i

proc handleAnsiCode(format: var Format, final: char, params: string) =
  case final
  of 'm':
    if params.len == 0:
      format = newFormat()
    else:
      let sparams = params.split(';')
      try:
        let ip = sparams.map((x) => parseInt(x))
        var pi = 0
        while pi < ip.len:
          case ip[pi]
          of 0:
            format = newFormat()
          of 1: format.bold = true
          of 3: format.italic = true
          of 4: format.underline = true
          of 5: format.blink = true
          of 7: format.reverse = true
          of 9: format.strike = true
          of 22: format.bold = false
          of 23: format.italic = false
          of 25: format.blink = false
          of 27: format.reverse = false
          of 29: format.strike = false
          of 30..37: format.fgcolor = CellColor(rgb: false, color: uint8(ip[pi]))
          of 38:
            inc pi
            if pi < ip.len:
              if ip[pi] == 2:
                inc pi
                if pi + 2 < ip.len:
                  let r = ip[pi]
                  inc pi
                  let g = ip[pi]
                  inc pi
                  let b = ip[pi]
                  format.fgcolor = CellColor(rgb: true, rgbcolor: rgb(r, g, b))
              else:
                #TODO
                inc pi
                continue
            else:
              break
          of 39:
            format.fgcolor = defaultColor
          of 40..47:
            format.bgcolor = CellColor(rgb: false, color: uint8(ip[0]))
          of 48:
            inc pi
            if pi < ip.len:
              if ip[pi] == 2:
                inc pi
                if pi + 2 < ip.len:
                  let r = ip[pi]
                  inc pi
                  let g = ip[pi]
                  inc pi
                  let b = ip[pi]
                  format.bgcolor = CellColor(rgb: true, rgbcolor: rgb(r, g, b))
              else:
                #TODO
                inc pi
                continue
            else:
              break
          of 49: format.bgcolor = defaultColor
          of 53: format.overline = true
          of 55: format.overline = false
          else: discard
          inc pi
      except ValueError: discard
  else: discard

proc parseAnsiCode*(format: var Format, buf: string, fi: int): int =
  var i = fi
  if buf[i] != '\e':
    return i

  inc_check i
  if 0x40 <= int(buf[i]) and int(buf[i]) <= 0x5F:
    if buf[i] != '[':
      #C1, TODO?
      return
    inc_check i

  let sp = i
  #parameter bytes
  while 0x30 <= int(buf[i]) and int(buf[i]) <= 0x3F:
    inc_check i
  let params = buf.substr(sp, i - 1)

  #let si = i
  #intermediate bytes
  while 0x20 <= int(buf[i]) and int(buf[i]) <= 0x2F:
    inc_check i
  #let interm = buf.substr(si, i)

  let final = buf[i]
  #final byte
  if 0x40 <= int(buf[i]) and int(buf[i]) <= 0x7E:
    format.handleAnsiCode(final, params)

  return i

proc parseAnsiCode*(format: var Format, stream: Stream) =
  if stream.atEnd(): return
  var c = stream.readChar()
  if 0x40 <= int(c) and int(c) <= 0x5F:
    if c != '[':
      #C1, TODO?
      return
    if stream.atEnd(): return
    c = stream.readChar()

  var params = $c
  #parameter bytes
  while 0x30 <= int(c) and int(c) <= 0x3F:
    params &= c
    if stream.atEnd(): return
    c = stream.readChar()

  #intermediate bytes
  #var interm = $c
  while 0x20 <= int(c) and int(c) <= 0x2F:
    #interm &= c
    if stream.atEnd(): return
    c = stream.readChar()

  #final byte
  if 0x40 <= int(c) and int(c) <= 0x7E:
    let final = c
    format.handleAnsiCode(final, params)

proc processFormat*(format: var Format, cellf: Format): string =
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
