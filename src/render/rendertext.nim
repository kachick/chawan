import io/cell
import utils/twtstr

proc renderPlainText*(text: string): FlexibleGrid =
  var format = newFormatting()
  template add_format() =
    if af:
      af = false
      result.addFormat(y, result[y].str.len, format)

  var i = 0
  var x = 0
  var y = 0
  var af = false
  while i < text.len:
    if text[i] == '\n':
      if i != text.len - 1:
        add_format
        result.addLine()
        inc y
        x = 0
      inc i
    elif text[i] == '\r':
      inc i
    elif text[i] == '\t':
      add_format
      for i in 0..8:
        result[^1].str &= ' '
      inc i
    elif text[i] == '\e':
      i = format.parseAnsiCode(text, i)
      af = true
    elif text[i].isControlChar():
      add_format
      result[y].str &= '^' & text[i].getControlLetter()
      inc i
    else:
      add_format
      result[y].str &= text[i]
      inc i
