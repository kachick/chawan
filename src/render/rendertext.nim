import streams

import buffer/cell
import utils/twtstr

proc renderPlainText*(text: string): FlexibleGrid =
  var format = newFormat()
  template add_format() =
    if af:
      af = false
      result[result.high].addFormat(result[^1].str.len, format)

  result.addLine()
  const tabwidth = 8
  var spaces = 0
  var i = 0
  var af = false
  while i < text.len:
    case text[i]
    of '\n':
      add_format
      result.addLine()
    of '\r': discard
    of '\t':
      add_format
      for i in 0 ..< tabwidth:
        result[^1].str &= ' '
        spaces = 0
    of ' ':
      add_format
      result[^1].str &= ' '
      inc spaces
      if spaces == 8:
        spaces = 0
    of '\e':
      i = format.parseAnsiCode(text, i)
      af = true
    elif text[i].isControlChar():
      add_format
      result[^1].str &= '^' & text[i].getControlLetter()
    else:
      add_format
      result[^1].str &= text[i]
    inc i

  if result.len > 1 and result[^1].str.len == 0 and result[^1].formats.len == 0:
    discard result.pop()

proc renderStream*(grid: var FlexibleGrid, stream: Stream, len: int) =
  var format = newFormat()
  template add_format() =
    if af:
      af = false
      grid[grid.high].addFormat(grid[^1].str.len, format)

  if grid.len == 0: grid.addLine()
  const tabwidth = 8
  var spaces = 0
  var af = false
  var i = 0
  while i < len:
    let c = stream.readChar()
    case c
    of '\n':
      add_format
      grid.addLine()
    of '\r': discard
    of '\t':
      add_format
      for i in 0 ..< tabwidth - spaces:
        grid[^1].str &= ' '
        spaces = 0
    of ' ':
      add_format
      grid[^1].str &= c
      inc spaces
      if spaces == 8:
        spaces = 0
    of '\e':
      format.parseAnsiCode(stream)
      af = true
    elif c.isControlChar():
      add_format
      grid[^1].str &= '^' & c.getControlLetter()
    else:
      add_format
      grid[^1].str &= c
    inc i

  #if grid.len > 1 and grid[^1].str.len == 0 and grid[^1].formats.len == 0:
  #  discard grid.pop()
