import std/unicode

import js/regex
import server/buffer
import types/cell
import utils/luwrap
import utils/strwidth

type
  SubmitSelect* = proc(selected: seq[int])
  CloseSelect* = proc()

  Select* = object
    open*: bool
    options: seq[string]
    multiple: bool
    # old selection
    oselected*: seq[int]
    # new selection
    selected*: seq[int]
    # cursor distance from y
    cursor: int
    # widest option
    maxw: int
    # maximum height on screen (yes the naming is dumb)
    maxh: int
    # first index to display
    si: int
    # location on screen
    x: int
    y: int
    redraw*: bool
    submitFun: SubmitSelect
    bpos: seq[int]

proc windowChange*(select: var Select; height: int) =
  select.maxh = height - 2
  if select.y + select.options.len >= select.maxh:
    select.y = height - select.options.len
    if select.y < 0:
      select.si = -select.y
      select.y = 0
  if select.selected.len > 0:
    let i = select.selected[0]
    if select.si > i:
      select.si = i
    elif select.si + select.maxh < i:
      select.si = max(i - select.maxh, 0)
  select.redraw = true

proc initSelect*(select: var Select; selectResult: SelectResult;
    x, y, height: int; submitFun: SubmitSelect) =
  select.open = true
  select.multiple = selectResult.multiple
  select.options = selectResult.options
  select.oselected = selectResult.selected
  select.selected = selectResult.selected
  select.submitFun = submitFun
  for opt in select.options.mitems:
    opt.mnormalize()
    select.maxw = max(select.maxw, opt.width())
  select.x = x
  select.y = y
  select.windowChange(height)

# index of option currently under cursor
func hover(select: Select): int =
  return select.cursor + select.si

func dispheight(select: Select): int =
  return select.maxh - select.y

proc `hover=`(select: var Select; i: int) =
  let i = clamp(i, 0, select.options.high)
  if i >= select.si + select.dispheight:
    select.si = i - select.dispheight + 1
    select.cursor = select.dispheight - 1
  elif i < select.si:
    select.si = i
    select.cursor = 0
  else:
    select.cursor = i - select.si

proc cursorDown*(select: var Select) =
  if select.hover < select.options.high and
      select.cursor + select.y < select.maxh - 1:
    inc select.cursor
    select.redraw = true
  elif select.si < select.options.len - select.maxh:
    inc select.si
    select.redraw = true

proc cursorUp*(select: var Select) =
  if select.cursor > 0:
    dec select.cursor
    select.redraw = true
  elif select.si > 0:
    dec select.si
    select.redraw = true
  elif select.multiple and select.cursor > -1:
    select.cursor = -1

proc close(select: var Select) =
  select = Select()

proc cancel*(select: var Select) =
  select.submitFun(select.oselected)
  select.close()

proc submit(select: var Select) =
  select.submitFun(select.selected)
  select.close()

proc click*(select: var Select) =
  if not select.multiple:
    select.selected = @[select.hover]
    select.submit()
  elif select.cursor == -1:
    select.submit()
  else:
    var k = select.selected.len
    let i = select.hover
    for j in 0 ..< select.selected.len:
      if select.selected[j] >= i:
        k = j
        break
    if k < select.selected.len and select.selected[k] == i:
      select.selected.delete(k)
    else:
      select.selected.insert(i, k)
    select.redraw = true

proc cursorLeft*(select: var Select) =
  select.submit()

proc cursorRight*(select: var Select) =
  select.click()

proc getCursorX*(select: var Select): int =
  if select.cursor == -1:
    return select.x
  return select.x + 1

proc getCursorY*(select: var Select): int =
  return select.y + 1 + select.cursor

proc cursorFirstLine*(select: var Select) =
  if select.cursor != 0 or select.si != 0:
    select.cursor = 0
    select.si = 0
    select.redraw = true

proc cursorLastLine*(select: var Select) =
  if select.hover < select.options.len:
    select.cursor = select.dispheight - 1
    select.si = max(select.options.len - select.maxh, 0)
    select.redraw = true

proc cursorNextMatch*(select: var Select; regex: Regex; wrap: bool) =
  var j = -1
  for i in select.hover + 1 ..< select.options.len:
    if regex.exec(select.options[i]).success:
      j = i
      break
  if j != -1:
    select.hover = j
    select.redraw = true
  elif wrap:
    for i in 0 ..< select.hover:
      if regex.exec(select.options[i]).success:
        j = i
        break
    if j != -1:
      select.hover = j
      select.redraw = true

proc cursorPrevMatch*(select: var Select; regex: Regex; wrap: bool) =
  var j = -1
  for i in countdown(select.hover - 1, 0):
    if regex.exec(select.options[i]).success:
      j = i
      break
  if j != -1:
    select.hover = j
    select.redraw = true
  elif wrap:
    for i in countdown(select.options.high, select.hover):
      if regex.exec(select.options[i]).success:
        j = i
        break
    if j != -1:
      select.hover = j
      select.redraw = true

proc pushCursorPos*(select: var Select) =
  select.bpos.add(select.hover)

proc popCursorPos*(select: var Select; nojump = false) =
  select.hover = select.bpos.pop()
  if not nojump:
    select.redraw = true

const HorizontalBar = $Rune(0x2500)
const VerticalBar = $Rune(0x2502)
const CornerTopLeft = $Rune(0x250C)
const CornerTopRight = $Rune(0x2510)
const CornerBottomLeft = $Rune(0x2514)
const CornerBottomRight = $Rune(0x2518)

proc drawBorders(display: var FixedGrid; sx, ex, sy, ey: int;
    upmore, downmore: bool) =
  for y in sy .. ey:
    var x = 0
    while x < sx:
      if display[y * display.width + x].str == "":
        display[y * display.width + x].str = " "
        inc x
      else:
        #x = display[y * display.width + x].str.twidth(x)
        inc x
  # Draw corners.
  let tl = if upmore: VerticalBar else: CornerTopLeft
  let tr = if upmore: VerticalBar else: CornerTopRight
  let bl = if downmore: VerticalBar else: CornerBottomLeft
  let br = if downmore: VerticalBar else: CornerBottomRight
  const fmt = Format()
  display[sy * display.width + sx].str = tl
  display[sy * display.width + ex].str = tr
  display[ey * display.width + sx].str = bl
  display[ey * display.width + ex].str = br
  display[sy * display.width + sx].format = fmt
  display[sy * display.width + ex].format = fmt
  display[ey * display.width + sx].format = fmt
  display[ey * display.width + ex].format = fmt
  # Draw top, bottom borders.
  let ups = if upmore: " " else: HorizontalBar
  let downs = if downmore: " " else: HorizontalBar
  for x in sx + 1 .. ex - 1:
    display[sy * display.width + x].str = ups
    display[ey * display.width + x].str = downs
    display[sy * display.width + x].format = fmt
    display[ey * display.width + x].format = fmt
  if upmore:
    display[sy * display.width + sx + (ex - sx) div 2].str = ":"
  if downmore:
    display[ey * display.width + sx + (ex - sx) div 2].str = ":"
  # Draw left, right borders.
  for y in sy + 1 .. ey - 1:
    display[y * display.width + sx].str = VerticalBar
    display[y * display.width + ex].str = VerticalBar
    display[y * display.width + sx].format = fmt
    display[y * display.width + ex].format = fmt

proc drawSelect*(select: Select; display: var FixedGrid) =
  if display.width < 2 or display.height < 2:
    return # border does not fit...
  # Max width, height with one row/column on the sides.
  let mw = display.width - 2
  let mh = display.height - 2
  var sy = select.y
  let si = select.si
  var ey = min(sy + select.options.len, mh) + 1
  var sx = select.x
  if sx + select.maxw >= mw:
    sx = display.width - select.maxw
    if sx < 0:
      # This means the widest option is wider than the available screen.
      # w3m simply cuts off the part that doesn't fit, and we do that too,
      # but I feel like this may not be the best solution.
      sx = 0
  var ex = min(sx + select.maxw, mw) + 1
  let upmore = select.si > 0
  let downmore = select.si + mh < select.options.len
  drawBorders(display, sx, ex, sy, ey, upmore, downmore)
  if select.multiple and not upmore:
    display[sy * display.width + sx].str = "X"
  # move inside border
  inc sy
  inc sx
  var r: Rune
  var k = 0
  var format = Format()
  while k < select.selected.len and select.selected[k] < si:
    inc k
  for y in sy ..< ey:
    let i = y - sy + si
    var j = 0
    var x = sx
    let dls = y * display.width
    if k < select.selected.len and select.selected[k] == i:
      format.flags.incl(ffReverse)
      inc k
    else:
      format.flags.excl(ffReverse)
    while j < select.options[i].len:
      fastRuneAt(select.options[i], j, r)
      let rw = r.twidth(x)
      let ox = x
      x += rw
      if x > ex:
        break
      display[dls + ox].str = $r
      display[dls + ox].format = format
    while x < ex:
      display[dls + x].str = " "
      display[dls + x].format = format
      inc x
