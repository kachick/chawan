import unicode
import strutils
import sequtils
import sugar

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

func newFixedGrid*(w: int, h: int = 1): FixedGrid =
  return newSeq[FixedCell](w * h)

func width*(line: FlexibleLine): int =
  for c in line:
    result += c.rune.width()

func newFormatting*(): Formatting =
  return Formatting(fgcolor: defaultColor, bgcolor: defaultColor)

proc setText*(grid: var FlexibleGrid, x: int, y: int, text: seq[Rune]) =
  while grid.len <= y:
    grid.add(newSeq[FlexibleCell]())

  while grid[y].len < x + text.len:
    grid[y].add(FlexibleCell())
  
  var i = 0
  while i < text.len:
    grid[y][i].rune = text[i]
    inc i

template inc_check(i: int) =
  inc i
  if i >= buf.len:
    return i

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

  let si = i
  #intermediate bytes
  while 0x20 <= int(buf[i]) and int(buf[i]) <= 0x2F:
    inc_check i
  let interm = buf.substr(si, i)

  let final = buf[i]
  #final byte
  if 0x40 <= int(buf[i]) and int(buf[i]) <= 0x7E:
    inc_check i

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
          of 1:
            formatting.bold = true
          of 3:
            formatting.italic = true
          of 4:
            formatting.underline = true
          of 9:
            formatting.strike = true
          of 22:
            formatting.bold = false
          of 23:
            formatting.italic = false
          of 29:
            formatting.strike = false
          of 30..37:
            formatting.fgcolor = CellColor(rgb: false, color: uint8(ip[pi]))
          of 38:
            inc pi
            if pi < ip.len:
              if ip[pi] == 2:
                inc pi
                if pi + 2 < ip.len:
                  let r = uint8(ip[pi])
                  inc pi
                  let g = uint8(ip[pi])
                  inc pi
                  let b = uint8(ip[pi])
                  formatting.fgcolor = CellColor(rgb: true, rgbcolor: (r: r, g: g, b: b))
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
                  let r = uint8(ip[pi])
                  inc pi
                  let g = uint8(ip[pi])
                  inc pi
                  let b = uint8(ip[pi])
                  formatting.bgcolor = CellColor(rgb: true, rgbcolor: (r: r, g: g, b: b))
              else:
                #TODO
                inc pi
                continue
            else:
              break
          of 49:
            formatting.bgcolor = defaultColor
          of 53:
            formatting.overline = true
          of 55:
            formatting.overline = false
          else: discard
          inc pi
      except ValueError: discard
  else: discard

  return i

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
