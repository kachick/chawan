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
  stream: Stream
  decoder: DecoderStream
  charsets: seq[Charset]
  newline: bool
  w: int

proc newStreamRenderer*(stream: Stream, charsets: seq[Charset]): StreamRenderer =
  result.format = newFormat()
  result.ansiparser.state = PARSE_DONE
  for i in countdown(charsets.high, 0):
    result.charsets.add(charsets[i])
  let cs = result.charsets.pop()
  let em = if charsets.len > 0:
    DECODER_ERROR_MODE_FATAL
  else:
    DECODER_ERROR_MODE_REPLACEMENT
  result.stream = stream
  result.decoder = newDecoderStream(stream, cs, errormode = em)

proc rewind(renderer: var StreamRenderer) =
  renderer.stream.setPosition(0)
  let cs = renderer.charsets.pop()
  let em = if renderer.charsets.len > 0:
    DECODER_ERROR_MODE_FATAL
  else:
    DECODER_ERROR_MODE_REPLACEMENT
  renderer.decoder = newDecoderStream(renderer.stream, cs, errormode = em)
  renderer.format = newFormat()
  renderer.ansiparser.state = PARSE_DONE

proc renderStream*(grid: var FlexibleGrid, renderer: var StreamRenderer, len: int) =
  if len == 0: return
  template add_format() =
    if renderer.af:
      renderer.af = false
      grid[grid.high].addFormat(renderer.w, renderer.format)

  if grid.len == 0: grid.addLine()
  var buf = newSeq[Rune](len * 4)
  var n: int
  while true:
    n = renderer.decoder.readData(addr buf[0], buf.len * sizeof(buf[0]))
    if renderer.decoder.failed:
      renderer.rewind()
      continue
    break
  for i in 0 ..< n div sizeof(buf[0]):
    if renderer.newline:
      # avoid newline at end of stream
      grid.addLine()
      renderer.newline = false
      renderer.w = 0
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
        continue
      else:
        add_format
        grid[^1].str &= c
    else:
      add_format
      grid[^1].str &= r
    renderer.w += r.twidth(renderer.w)
