import std/streams
import std/strutils
import std/unicode

import types/cell
import utils/strwidth

import chakasu/charset
import chakasu/decoderstream
import chakasu/encoderstream

type StreamRenderer* = object
  ansiparser: AnsiCodeParser
  format: Format
  af: bool
  stream: Stream
  decoder: DecoderStream
  encoder: EncoderStream
  charsets: seq[Charset]
  newline: bool
  w: int
  j: int # byte in line

proc newStreamRenderer*(stream: Stream, charsets0: openArray[Charset]):
    StreamRenderer =
  var charsets = newSeq[Charset](charsets0.len)
  for i in 0 ..< charsets.len:
    charsets[i] = charsets0[charsets.high - i]
  if charsets.len == 0:
    charsets.add(DefaultCharset)
  let cs = charsets.pop()
  let em = if charsets.len > 0:
    DECODER_ERROR_MODE_FATAL
  else:
    DECODER_ERROR_MODE_REPLACEMENT
  let decoder = newDecoderStream(stream, cs, errormode = em)
  decoder.setInhibitCheckEnd(true)
  let encoder = newEncoderStream(decoder)
  return StreamRenderer(
    stream: stream,
    decoder: decoder,
    encoder: encoder,
    format: Format(),
    charsets: charsets,
    ansiparser: AnsiCodeParser(
      state: PARSE_DONE
    )
  )

proc rewind(renderer: var StreamRenderer) =
  renderer.stream.setPosition(0)
  let cs = renderer.charsets.pop()
  let em = if renderer.charsets.len > 0:
    DECODER_ERROR_MODE_FATAL
  else:
    DECODER_ERROR_MODE_REPLACEMENT
  let decoder = newDecoderStream(renderer.stream, cs, errormode = em)
  decoder.setInhibitCheckEnd(true)
  renderer.decoder = decoder
  renderer.encoder = newEncoderStream(decoder)
  renderer.format = Format()
  renderer.ansiparser.state = PARSE_DONE

proc addFormat(grid: var FlexibleGrid, renderer: var StreamRenderer) =
  if renderer.af:
    renderer.af = false
    if renderer.j == grid[^1].str.len:
      grid[^1].addFormat(renderer.w, renderer.format)

proc processBackspace(grid: var FlexibleGrid, renderer: var StreamRenderer,
    r: Rune): bool =
  let pj = renderer.j
  var cr: Rune
  fastRuneAt(grid[^1].str, renderer.j, cr)
  if r == Rune('_') or cr == Rune('_') or r == cr:
    let flag = if r == cr: FLAG_BOLD else: FLAG_UNDERLINE
    if r != cr and cr == Rune('_'):
      # original is _, we must replace :(
      # like less, we assume no double _ for double width characters.
      grid[^1].str.delete(pj..<renderer.j)
      let s = $r
      grid[^1].str.insert(s, pj)
      renderer.j = pj + s.len
    let n = grid[^1].findFormatN(renderer.w) - 1
    if n != -1 and grid[^1].formats[n].pos == renderer.w:
      let flags = grid[^1].formats[n].format.flags
      if r == cr and r == Rune('_') and flag in flags:
        # double overstrike of _, this is nonsensical on a teletype but less(1)
        # treats it as an underline so we do that too
        grid[^1].formats[n].format.flags.incl(FLAG_UNDERLINE)
      else:
        grid[^1].formats[n].format.flags.incl(flag)
    elif n != -1:
      var format = grid[^1].formats[n].format
      format.flags.incl(flag)
      grid[^1].insertFormat(renderer.w, n + 1, format)
    else:
      grid[^1].addFormat(renderer.w, Format(flags: {flag}))
    renderer.w += r.twidth(renderer.w)
    if renderer.j == grid[^1].str.len:
      grid[^1].addFormat(renderer.w, Format())
    return true
  let n = grid[^1].findFormatN(renderer.w)
  grid[^1].formats.setLen(n)
  grid[^1].str.setLen(renderer.j)
  return false

proc processAscii(grid: var FlexibleGrid, renderer: var StreamRenderer,
    c: char) =
  case c
  of '\b':
    if renderer.j == 0:
      grid[^1].str &= c
      inc renderer.j
      renderer.w += Rune(c).twidth(renderer.w)
    else:
      let (r, len) = lastRune(grid[^1].str, grid[^1].str.high)
      renderer.j -= len
      renderer.w -= r.twidth(renderer.w)
  of '\n':
    grid.addFormat(renderer)
    renderer.newline = true
  of '\r': discard
  of '\e':
    renderer.ansiparser.reset()
  else:
    grid.addFormat(renderer)
    grid[^1].str &= c
    renderer.w += Rune(c).twidth(renderer.w)
    inc renderer.j

proc renderChunk(grid: var FlexibleGrid, renderer: var StreamRenderer,
    buf: string) =
  var i = 0
  while i < buf.len:
    if renderer.newline:
      # avoid newline at end of stream
      grid.addLine()
      renderer.newline = false
      renderer.w = 0
      renderer.j = 0
    let pi = i
    var r: Rune
    fastRuneAt(buf, i, r)
    if renderer.j < grid[^1].str.len:
      if grid.processBackspace(renderer, r):
        continue
    if uint32(r) < 0x80:
      let c = char(r)
      if renderer.ansiparser.state != PARSE_DONE:
        if not renderer.ansiparser.parseAnsiCode(renderer.format, c):
          if renderer.ansiparser.state == PARSE_DONE:
            renderer.af = true
          continue
      grid.processAscii(renderer, c)
    else:
      grid.addFormat(renderer)
      grid[^1].str &= r
      renderer.w += r.twidth(renderer.w)
      renderer.j += i - pi

proc renderStream*(grid: var FlexibleGrid, renderer: var StreamRenderer) =
  var buf = renderer.encoder.readAll()
  while renderer.decoder.failed:
    renderer.rewind()
    grid.setLen(0)
    buf = renderer.encoder.readAll()
  if grid.len == 0:
    grid.addLine()
  grid.renderChunk(renderer, buf)
