import types/color
import utils/strwidth

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

  SimpleFormatCell* = object
    format*: Format
    pos*: int

  SimpleFlexibleLine* = object
    str*: string
    formats*: seq[SimpleFormatCell]

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

func width*(cell: FixedCell): int =
  return cell.str.width()

# Get the first format cell after pos, if any.
func findFormatN*(line: SimpleFlexibleLine, pos: int): int =
  var i = 0
  while i < line.formats.len:
    if line.formats[i].pos > pos:
      break
    inc i
  return i

func findFormat*(line: SimpleFlexibleLine, pos: int): SimpleFormatCell =
  let i = line.findFormatN(pos) - 1
  if i != -1:
    result = line.formats[i]
  else:
    result.pos = -1

func findNextFormat*(line: SimpleFlexibleLine, pos: int): SimpleFormatCell =
  let i = line.findFormatN(pos)
  if i < line.formats.len:
    result = line.formats[i]
  else:
    result.pos = -1
