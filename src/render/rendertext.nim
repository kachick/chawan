import streams
import unicode

import buffer/cell
import data/charset
import encoding/decoderstream
import utils/twtstr

type StreamRenderer* = object
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
  var buf = newSeq[Rune](len * 4)
  let n = renderer.decoder.readData(addr buf[0], buf.len * sizeof(buf[0]))
  for i in 0 ..< n div sizeof(buf[0]):
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
          continue
      case c
      of '\n':
        add_format
        renderer.newline = true
      of '\r': discard
      of '\e':
        renderer.ansiparser.reset()
      else:
        add_format
        grid[^1].str &= c
    else:
      add_format
      grid[^1].str &= r
