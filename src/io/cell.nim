import unicode

import types/color
import utils/twtstr

type
  Formatting* = object
    fgcolor*: CellColor
    bgcolor*: CellColor
    italic*: bool
    bold*: bool
    underline*: bool
    strike*: bool
    overline*: bool

  Cell* = object of RootObj
    formatting*: Formatting

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

func newFormatting*(): Formatting =
  return Formatting(fgcolor: defaultColor, bgcolor: defaultColor)

proc processFormatting*(formatting: var Formatting, cellf: Formatting): string =
    if formatting.bold and not cellf.bold:
      result &= SGR(22)
    if formatting.italic and not cellf.italic:
      result &= SGR(23)
    if formatting.underline and not cellf.underline:
      result &= SGR(24)
    if formatting.strike and not cellf.strike:
      result &= SGR(29)
    if formatting.overline and not cellf.overline:
      result &= SGR(55)

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

    if not formatting.bold and cellf.bold:
      result &= SGR(1)
    if not formatting.italic and cellf.italic:
      result &= SGR(3)
    if not formatting.underline and cellf.underline:
      result &= SGR(4)
    if not formatting.strike and cellf.strike:
      result &= SGR(9)
    if not formatting.overline and cellf.overline:
      result &= SGR(53)

    formatting = cellf
    if formatting.bold and not cellf.bold:
      result &= SGR(22)
    if formatting.italic and not cellf.italic:
      result &= SGR(23)
    if formatting.underline and not cellf.underline:
      result &= SGR(24)
    if formatting.strike and not cellf.strike:
      result &= SGR(29)
    if formatting.overline and not cellf.overline:
      result &= SGR(55)

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

    if not formatting.bold and cellf.bold:
      result &= SGR(1)
    if not formatting.italic and cellf.italic:
      result &= SGR(3)
    if not formatting.underline and cellf.underline:
      result &= SGR(4)
    if not formatting.strike and cellf.strike:
      result &= SGR(9)
    if not formatting.overline and cellf.overline:
      result &= SGR(53)

    formatting = cellf
