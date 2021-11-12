import unicode

import types/color
import utils/twtstr

type
  Cell* = object of RootObj
    fgcolor*: CellColor
    bgcolor*: CellColor
    italic*: bool
    bold*: bool
    underline*: bool
    strike*: bool
    overline*: bool

  FlexibleCell* = object of Cell
    rune*: Rune

  FlexibleLine* = seq[FlexibleCell]

  FlexibleGrid* = seq[FlexibleLine]

  FixedCell* = object of Cell
    runes*: seq[Rune]

  FixedGrid* = seq[FixedCell]

proc setText*(grid: var FlexibleGrid, x: int, y: int, text: seq[Rune]) =
  while grid.len <= y:
    grid.add(newSeq[FlexibleCell]())

  while grid[y].len < x + text.len:
    grid[y].add(FlexibleCell())
  
  var i = 0
  while i < text.len:
    grid[y][i].rune = text[i]
    inc i

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return newSeq[FixedCell](w * h)

func width*(line: FlexibleLine): int =
  for c in line:
    result += c.rune.width()
