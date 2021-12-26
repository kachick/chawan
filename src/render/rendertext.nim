import streams

import io/cell
import utils/twtstr

proc renderPlainText*(text: string): FlexibleGrid =
  var format = newFormatting()
  template add_format() =
    if af:
      af = false
      result.addFormat(result.high, result[^1].str.len, format)

  result.addLine()
  var i = 0
  var af = false
  while i < text.len:
    case text[i]
    of '\n':
      if i != text.len - 1:
        add_format
        result.addLine()
    of '\r': discard
    of '\t':
      add_format
      for i in 0..8:
        result[^1].str &= ' '
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

proc renderStream*(stream: Stream): FlexibleGrid =
  var format = newFormatting()
  template add_format() =
    if af:
      af = false
      result.addFormat(result.high, result[^1].str.len, format)

  result.addLine()
  var af = false
  while not stream.atEnd():
    let c = stream.readChar()
    case c
    of '\n':
      add_format
      result.addLine()
    of '\r': discard
    of '\t':
      add_format
      for i in 0..8:
        result[^1].str &= ' '
    of '\e':
      format.parseAnsiCode(stream)
      af = true
    elif c.isControlChar():
      add_format
      result[^1].str &= '^' & c.getControlLetter()
    else:
      add_format
      result[^1].str &= c
