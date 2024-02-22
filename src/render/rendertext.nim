import std/streams
import std/strutils
import std/unicode

import types/cell
import utils/strwidth

type StreamRenderer* = ref object
  ansiparser: AnsiCodeParser
  format: Format
  af: bool
  stream: Stream
  newline: bool
  w: int
  j: int # byte in line

proc newStreamRenderer*(): StreamRenderer =
  return StreamRenderer(ansiparser: AnsiCodeParser(state: PARSE_DONE))

proc rewind*(renderer: StreamRenderer) =
  renderer.format = Format()
  renderer.ansiparser.state = PARSE_DONE

proc addFormat(grid: var FlexibleGrid, renderer: StreamRenderer) =
  if renderer.af:
    renderer.af = false
    if renderer.j == grid[^1].str.len:
      grid[^1].addFormat(renderer.w, renderer.format)

proc processBackspace(grid: var FlexibleGrid, renderer: StreamRenderer,
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

proc processAscii(grid: var FlexibleGrid, renderer: StreamRenderer, c: char) =
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

proc renderChunk*(grid: var FlexibleGrid, renderer: StreamRenderer,
    buf: openArray[char]) =
  if grid.len == 0:
    grid.addLine()
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
