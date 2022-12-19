import streams
import unicode

import buffer/cell
import data/charset
import encoding/decoderstream
import utils/twtstr

const tabwidth = 8
type StreamRenderer* = object
  spaces: int
  ansiparser: AnsiCodeParser
  format: Format
  af: bool
  decoder: DecoderStream
  newline: bool

proc newStreamRenderer*(stream: Stream): StreamRenderer =
  result.format = newFormat()
  result.ansiparser.state = PARSE_DONE
  result.decoder = newDecoderStream(stream, CHARSET_UTF_8)

proc renderStream*(grid: var FlexibleGrid, renderer: var StreamRenderer, len: int) =
  if len == 0: return
  template add_format() =
    if renderer.af:
      renderer.af = false
      grid[grid.high].addFormat(grid[^1].str.len, renderer.format)

  if grid.len == 0: grid.addLine()
  var i = 0
  var buf = newSeq[Rune](len * 4)
  let n = renderer.decoder.readData(addr buf[0], buf.len * sizeof(buf[0]))
  while i < n div sizeof(buf[0]):
    if renderer.newline:
      # avoid newline at end of stream
      grid.addLine()
      renderer.newline = false
    let r = buf[i]
    if r.isAscii():
      let c = cast[char](r)
      if renderer.ansiparser.state != PARSE_DONE:
        let cancel = renderer.ansiparser.parseAnsiCode(renderer.format, c)
        if not cancel:
          if renderer.ansiparser.state == PARSE_DONE:
            renderer.af = true
          inc i
          continue
      case c
      of '\n':
        add_format
        renderer.newline = true
      of '\r': discard
      of '\t':
        add_format
        for i in 0 ..< tabwidth - renderer.spaces:
          grid[^1].str &= ' '
          renderer.spaces = 0
      of ' ':
        add_format
        grid[^1].str &= c
        inc renderer.spaces
        if renderer.spaces == 8:
          renderer.spaces = 0
      of '\e':
        renderer.ansiparser.reset()
      else:
        add_format
        grid[^1].str &= c
    else:
      add_format
      grid[^1].str &= r
    inc i
