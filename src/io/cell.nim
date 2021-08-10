import unicode

import types/color

type
  Cell* = object of RootObj
    fgcolor*: CellColor
    bgcolor*: CellColor
    italic*: bool
    bold*: bool
    underline*: bool

  FlexibleCell* = object of Cell
    rune*: Rune

  FlexibleGrid* = seq[seq[FlexibleCell]]

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

