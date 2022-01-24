import sequtils
import streams
import strutils
import sugar
import unicode

import html/dom
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

  Formatting* = object
    fgcolor*: CellColor
    bgcolor*: CellColor
    flags: set[FormatFlags]

  Cell* = object of RootObj
    formatting*: Formatting
    node*: Node

  FormattingCell* = object of Cell
    pos*: int

  FlexibleLine* = object
    str*: string
    formats*: seq[FormattingCell]

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
]

template flag_template(formatting: Formatting, val: bool, flag: FormatFlags) =
  if val: formatting.flags.incl(flag)
  else: formatting.flags.excl(flag)

template `italic=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_ITALIC
template `bold=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_BOLD
template `underline=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_UNDERLINE
template `reverse=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_REVERSE
template `strike=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_STRIKE
template `overline=`*(f: var Formatting, b: bool) = flag_template f, b, FLAG_OVERLINE

#TODO ?????
func `==`*(a: FixedCell, b: FixedCell): bool =
  return a.formatting == b.formatting and
    a.runes == b.runes and
    a.node == b.node

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return newSeq[FixedCell](w * h)

func width*(line: FlexibleLine): int =
  return line.str.width()

func width*(cell: FixedCell): int =
  return cell.runes.width()

func newFormatting*(): Formatting =
  return Formatting(fgcolor: defaultColor, bgcolor: defaultColor)

func findFormatN*(line: FlexibleLine, pos: int): int =
  var i = 0
  while i < line.formats.len:
    if line.formats[i].pos > pos:
      break
    inc i 
  return i

func findFormat*(line: FlexibleLine, pos: int): FormattingCell =
  let i = line.findFormatN(pos) - 1
  if i != -1:
    result = line.formats[i]
  else:
    result.pos = -1

func findNextFormat*(line: FlexibleLine, pos: int): FormattingCell =
  let i = line.findFormatN(pos)
  if i < line.formats.len:
    result = line.formats[i]
  else:
    result.pos = -1

func subformats*(formats: seq[FormattingCell], pos: int): seq[FormattingCell] =
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
  a.formats.add(b.formats.map((x) => FormattingCell(formatting: x.formatting, node: x.node, pos: l + x.pos)))
  a.str &= b.str

proc addLine*(grid: var FlexibleGrid) =
  grid.add(FlexibleLine())

proc addFormat*(line: var FlexibleLine, pos: int, format: Formatting) =
  line.formats.add(FormattingCell(formatting: format, pos: line.str.len))

proc addFormat*(grid: var FlexibleGrid, y, pos: int, format: Formatting) =
  grid[y].formats.add(FormattingCell(formatting: format, pos: grid[y].str.len))

proc addFormat*(grid: var FlexibleGrid, y, pos: int, format: Formatting, node: Node) =
  grid[y].formats.add(FormattingCell(formatting: format, node: node, pos: pos))

proc addCell*(grid: var FlexibleGrid, y: int, r: Rune) =
  grid[y].str &= $r

proc addCell*(grid: var FlexibleGrid, r: Rune) =
  grid.addCell(grid.len - 1, r)

template inc_check(i: int) =
  inc i
  if i >= buf.len:
    return i

proc handleAnsiCode(formatting: var Formatting, final: char, params: string) =
  case final
  of 'm':
    if params.len == 0:
      formatting = newFormatting()
    else:
      let sparams = params.split(';')
      try:
        let ip = sparams.map((x) => parseInt(x))
        var pi = 0
        while pi < ip.len:
          case ip[pi]
          of 0:
            formatting = newFormatting()
          of 1: formatting.bold = true
          of 3: formatting.italic = true
          of 4: formatting.underline = true
          of 7: formatting.reverse = true
          of 9: formatting.strike = true
          of 22: formatting.bold = false
          of 23: formatting.italic = false
          of 27: formatting.reverse = false
          of 29: formatting.strike = false
          of 30..37: formatting.fgcolor = CellColor(rgb: false, color: uint8(ip[pi]))
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
                  formatting.fgcolor = CellColor(rgb: true, rgbcolor: rgb(r, g, b))
              else:
                #TODO
                inc pi
                continue
            else:
              break
          of 39:
            formatting.fgcolor = defaultColor
          of 40..47:
            formatting.bgcolor = CellColor(rgb: false, color: uint8(ip[0]))
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
                  formatting.bgcolor = CellColor(rgb: true, rgbcolor: rgb(r, g, b))
              else:
                #TODO
                inc pi
                continue
            else:
              break
          of 49: formatting.bgcolor = defaultColor
          of 53: formatting.overline = true
          of 55: formatting.overline = false
          else: discard
          inc pi
      except ValueError: discard
  else: discard

proc parseAnsiCode*(formatting: var Formatting, buf: string, fi: int): int =
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
    formatting.handleAnsiCode(final, params)

  return i

proc parseAnsiCode*(formatting: var Formatting, stream: Stream) =
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
    formatting.handleAnsiCode(final, params)

proc processFormatting*(formatting: var Formatting, cellf: Formatting): string =
  for flag in FormatFlags:
    if flag in formatting.flags and flag notin cellf.flags:
      result &= SGR(FormatCodes[flag].e)

  if cellf.fgcolor != formatting.fgcolor:
    var color = cellf.fgcolor
    if color.rgb:
      let rgb = color.rgbcolor
      result &= SGR(38, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      result &= SGR()
      formatting = newFormatting()
    else:
      result &= SGR(color.color)

  if cellf.bgcolor != formatting.bgcolor:
    var color = cellf.bgcolor
    if color.rgb:
      let rgb = color.rgbcolor
      result &= SGR(48, 2, rgb.r, rgb.g, rgb.b)
    elif color == defaultColor:
      result &= SGR()
      formatting = newFormatting()
    else:
      result &= SGR(color.color)

  for flag in FormatFlags:
    if flag notin formatting.flags and flag in cellf.flags:
      result &= SGR(FormatCodes[flag].s)

  formatting = cellf
