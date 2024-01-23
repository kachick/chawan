import std/options
import std/tables

import css/stylednode
import types/color
import utils/strwidth
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
    node*: StyledNode

  SimpleFormatCell* = object
    format*: Format
    pos*: int

  # Following properties should hold for `formats':
  # * Position should be >= 0, <= str.width().
  # * The position of every FormatCell should be greater than the position
  #   of the previous FormatCell.
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
proc high*(grid: FixedGrid): int = grid.cells.high

const FormatCodes*: array[FormatFlags, tuple[s, e: uint8]] = [
  FLAG_BOLD: (1u8, 22u8),
  FLAG_ITALIC: (3u8, 23u8),
  FLAG_UNDERLINE: (4u8, 24u8),
  FLAG_REVERSE: (7u8, 27u8),
  FLAG_STRIKE: (9u8, 29u8),
  FLAG_OVERLINE: (53u8, 55u8),
  FLAG_BLINK: (5u8, 25u8),
]

const FormatCodeMap = block:
  var res: Table[uint8, tuple[flag: FormatFlags, reverse: bool]]
  for x in FormatFlags:
    res[FormatCodes[x][0]] = (x, false)
    res[FormatCodes[x][1]] = (x, true)
  res

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

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return FixedGrid(width: w, height: h, cells: newSeq[FixedCell](w * h))

func width*(line: FlexibleLine): int =
  return line.str.width()

func width*(cell: FixedCell): int =
  return cell.str.width()

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

proc addLines*(grid: var FlexibleGrid, n: int) =
  grid.setLen(grid.len + n)

proc insertFormat*(line: var FlexibleLine, i: int, cell: FormatCell) =
  line.formats.insert(cell, i)

proc insertFormat*(line: var FlexibleLine, pos, i: int, format: Format,
    node: StyledNode = nil) =
  line.insertFormat(i, FormatCell(format: format, node: node, pos: pos))

proc addFormat*(line: var FlexibleLine, pos: int, format: Format,
    node: StyledNode = nil) =
  line.formats.add(FormatCell(format: format, node: node, pos: pos))

# https://www.ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf
type
  AnsiCodeParseState* = enum
    PARSE_START, PARSE_PARAMS, PARSE_INTERM, PARSE_FINAL, PARSE_DONE

  AnsiCodeParser* = object
    state*: AnsiCodeParseState
    params: string

proc getParam(parser: AnsiCodeParser, i: var int, colon = false): string =
  while i < parser.params.len and
      not (parser.params[i] == ';' or colon and parser.params[i] == ':'):
    result &= parser.params[i]
    inc i
  if i < parser.params.len:
    inc i

template getParamU8(parser: AnsiCodeParser, i: var int,
    colon = false): uint8 =
  if i >= parser.params.len:
    return false
  let u = parseUInt8(parser.getParam(i))
  if u.isNone:
    return false
  u.get

proc parseSGRDefColor(parser: AnsiCodeParser, format: var Format,
    i: var int, isfg: bool): bool =
  let u = parser.getParamU8(i, colon = true)
  template set_color(c: CellColor) =
    if isfg:
      format.fgcolor = c
    else:
      format.bgcolor = c
  if u == 2:
    let param0 = parser.getParamU8(i, colon = true)
    if i < parser.params.len:
      let r = param0
      let g = parser.getParamU8(i, colon = true)
      let b = parser.getParamU8(i, colon = true)
      set_color cellColor(rgb(r, g, b))
    else:
      set_color cellColor(gray(param0))
  elif u == 5:
    let param0 = parser.getParamU8(i, colon = true)
    if param0 in 0u8..7u8:
      set_color cellColor(ANSIColor(param0))
    elif param0 in 8u8..15u8:
      format.bold = true
      set_color cellColor(ANSIColor(param0 - 8))
    elif param0 in 16u8..255u8:
      set_color cellColor(EightBitColor(param0))
  else:
    return false

proc parseSGRColor(parser: AnsiCodeParser, format: var Format,
    i: var int, u: uint8): bool =
  if u in 30u8..37u8:
    format.fgcolor = cellColor(ANSIColor(u - 30))
  elif u == 38:
    return parser.parseSGRDefColor(format, i, isfg = true)
  elif u == 39:
    format.fgcolor = defaultColor
  elif u in 40u8..47u8:
    format.bgcolor = cellColor(ANSIColor(u - 40))
  elif u == 48:
    return parser.parseSGRDefColor(format, i, isfg = false)
  elif u == 49:
    format.bgcolor = defaultColor
  elif u in 90u8..97u8:
    format.fgcolor = cellColor(ANSIColor(u - 90u8))
    format.bold = true
  elif u in 100u8..107u8:
    format.bgcolor = cellColor(ANSIColor(u - 90u8))
    format.bold = true
  else:
    return false
  return true

proc parseSGRAspect(parser: AnsiCodeParser, format: var Format,
    i: var int): bool =
  let u = parser.getParamU8(i)
  if u in FormatCodeMap:
    let entry = FormatCodeMap[u]
    if entry.reverse:
      format.flags.excl(entry.flag)
    else:
      format.flags.incl(entry.flag)
    return true
  elif u == 0:
    format = Format()
    return true
  else:
    return parser.parseSGRColor(format, i, u)

proc parseSGR(parser: AnsiCodeParser, format: var Format) =
  if parser.params.len == 0:
    format = Format()
  else:
    var i = 0
    while i < parser.params.len:
      if not parser.parseSGRAspect(format, i):
        break

proc parseControlFunction(parser: var AnsiCodeParser, format: var Format,
    f: char) =
  case f
  of 'm':
    parser.parseSGR(format)
  else: discard # unknown

proc reset*(parser: var AnsiCodeParser) =
  parser.state = PARSE_START
  parser.params = ""

proc parseAnsiCode*(parser: var AnsiCodeParser, format: var Format,
    c: char): bool =
  case parser.state
  of PARSE_START:
    if 0x40 <= int(c) and int(c) <= 0x5F:
      if c != '[':
        #C1, TODO?
        parser.state = PARSE_DONE
      else:
        parser.state = PARSE_PARAMS
    else:
      parser.state = PARSE_DONE
      return true
  of PARSE_PARAMS:
    if 0x30 <= int(c) and int(c) <= 0x3F:
      parser.params &= c
    else:
      parser.state = PARSE_INTERM
      return parser.parseAnsiCode(format, c)
  of PARSE_INTERM:
    if 0x20 <= int(c) and int(c) <= 0x2F:
      discard
    else:
      parser.state = PARSE_FINAL
      return parser.parseAnsiCode(format, c)
  of PARSE_FINAL:
    parser.state = PARSE_DONE
    if 0x40 <= int(c) and int(c) <= 0x7E:
      parser.parseControlFunction(format, c)
    else:
      return true
  of PARSE_DONE: discard
