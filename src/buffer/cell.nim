import sequtils
import streams
import strutils
import sugar

import css/stylednode
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
    flags*: set[FormatFlags]

  # A FormatCell *starts* a new terminal formatting context.
  # If no FormatCell exists before a given cell, the default formatting is used.
  FormatCell* = object
    format*: Format
    pos*: int
    computed*: ComputedFormat
    node*: StyledNode

  SimpleFormatCell* = object
    format*: Format
    pos*: int

  FlexibleLine* = object
    str*: string
    formats*: seq[FormatCell]

  SimpleFlexibleLine* = object
    str*: string
    formats*: seq[SimpleFormatCell]

  FlexibleGrid* = seq[FlexibleLine]

  SimpleFlexibleGrid* = seq[SimpleFlexibleLine]

  FixedCell* = object
    str*: string
    format*: Format

  FixedGrid* = object
    width*, height*: int
    cells*: seq[FixedCell]

proc `[]=`*(grid: var FixedGrid, i: int, cell: FixedCell) = grid.cells[i] = cell
proc `[]=`*(grid: var FixedGrid, i: BackwardsIndex, cell: FixedCell) = grid.cells[i] = cell
proc `[]`*(grid: var FixedGrid, i: int): var FixedCell = grid.cells[i]
proc `[]`*(grid: var FixedGrid, i: BackwardsIndex): var FixedCell = grid.cells[i]
proc `[]`*(grid: FixedGrid, i: int): FixedCell = grid.cells[i]
proc `[]`*(grid: FixedGrid, i: BackwardsIndex): FixedCell = grid.cells[i]
iterator items*(grid: FixedGrid): FixedCell {.inline.} =
  for cell in grid.cells: yield cell
proc len*(grid: FixedGrid): int = grid.cells.len

const FormatCodes*: array[FormatFlags, tuple[s: int, e: int]] = [
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

func `==`*(a: FixedCell, b: FixedCell): bool =
  return a.format == b.format and
    a.str == b.str

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return FixedGrid(width: w, height: h, cells: newSeq[FixedCell](w * h))

func width*(line: FlexibleLine): int =
  return line.str.width()

func width*(cell: FixedCell): int =
  return cell.str.width()

func newFormat*(): Format =
  return Format(fgcolor: defaultColor, bgcolor: defaultColor)

# Get the first format cell after pos, if any.
func findFormatN*(line: FlexibleLine|SimpleFlexibleLine, pos: int): int =
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

func findFormat*(line: SimpleFlexibleLine, pos: int): SimpleFormatCell =
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

func findNextFormat*(line: SimpleFlexibleLine, pos: int): SimpleFormatCell =
  let i = line.findFormatN(pos)
  if i < line.formats.len:
    result = line.formats[i]
  else:
    result.pos = -1

proc addLine*(grid: var FlexibleGrid) =
  grid.add(FlexibleLine())

proc insertFormat*(line: var FlexibleLine, pos, i: int, format: Format, computed: ComputedFormat = nil) =
  if computed == nil:
    line.formats.insert(FormatCell(format: format, pos: pos), i)
  else:
    line.formats.insert(FormatCell(format: format, computed: computed, node: computed.node, pos: pos), i)

proc addFormat*(line: var FlexibleLine, pos: int, format: Format) =
  line.formats.add(FormatCell(format: format, pos: pos))

proc addFormat*(line: var FlexibleLine, pos: int, format: Format, computed: ComputedFormat) =
  #if computed != nil and line.formats.len > 0 and line.formats[^1].computed == computed and line.formats[^1].format.bgcolor != format.bgcolor:
  #  return
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
