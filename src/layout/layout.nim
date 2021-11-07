import unicode

import layout/box
import types/enums
import html/dom
import css/style
import io/buffer
import io/cell
import utils/twtstr

#proc generateGrids(text: Text, maxwidth: int, maxheight: int, x: int, y: int, fromx: int = x): seq[CSSRowBox] =
#  var r: Rune
#  var rowbox: CSSRowBox
#  var i = 0
#  var whitespace = false
#  if fromx > x:
#    let m = fromx - x + maxwidth
#    var w = 0
#    while i < text.data.len:
#      let pi = i
#      fastRuneAt(text.data, i, r)
#      let rw = r.width()
#      if rw + w > m:
#        i = pi
#        break
#      else:
#        if r.isWhitespace():
#          if not whitespace:
#            whitespace = true
#            rowbox.runes.add(Rune(' '))
#            inc rowbox.width
#            w += rw
#        else:
#          if whitespace:
#            whitespace = false
#          rowbox.runes.add(r)
#          inc rowbox.width
#          w += rw
#
#    result.add(rowbox)
#
#  if i < text.data.len:
#    rowbox = CSSRowBox()
#    var w = 0
#    while i < text.data.len:
#      let pi = i
#      fastRuneAt(text.data, i, r)
#      let rw = r.width()
#      if rw + w > maxwidth:
#        i = pi
#        w = 0
#        result.add(rowbox)
#        rowbox = CSSRowBox()
#      else:
#        rowbox.runes.add(r)
#        inc rowbox.width
#        w += rw
#
#  if rowbox.width > 0:
#    result.add(rowbox)
#
#proc generateBox(text: Text, maxwidth: int, maxheight: int, x: int, y: int, fromx: int): CSSInlineBox =
#  new(result)
#  result.content = text.generateGrids(maxwidth, maxheight, x, y, fromx)
#  result.fromx = fromx
#  result.x = x
#  result.y = y
#  var height = 0
#  var width = 0
#  for grid in result.content:
#    inc height
#    width = max(width, grid.width)
#  
#  height = min(height, maxheight)
#  width = min(width, maxwidth)
#  result.width = width
#  result.height = height
#
#proc generateBox(elem: Element, maxwidth: int, maxheight: int, x: int = 0, y: int = 0, fromx: int = x): CSSBox
#
#proc generateChildBoxes(elem: Element, maxwidth: int, maxheight: int, x: int, y: int, fromx: int = 0): seq[CSSBox] =
#  var cx = fromx
#  var cy = y
#  for child in elem.childNodes:
#    case child.nodeType
#    of TEXT_NODE:
#      let box = Text(child).generateBox(maxwidth, maxheight, x, cy, cx)
#      if box != nil:
#        result.add(box)
#        cy += box.height
#        if box.content.len > 0:
#          cx += box.content[^1].width
#    of ELEMENT_NODE:
#      let box = Element(child).generateBox(maxwidth, maxheight, x, cy, cx)
#      if box != nil:
#        result.add(box)
#    else:
#      discard
#
#proc generateBox(elem: Element, maxwidth: int, maxheight: int, x: int = 0, y: int = 0, fromx: int = x): CSSBox =
#  if elem.cssvalues[RULE_DISPLAY].display == DISPLAY_NONE:
#    return nil
#
#  result = CSSBlockBox()
#  result.x = x
#  result.y = y
#
#  var width = 0
#  var height = 0
#  for box in elem.generateChildBoxes(maxwidth, maxheight, x, y, fromx):
#    result.children.add(box)
#    height += box.height
#    height = min(height, maxheight)
#    width = max(width, box.width)
#    width = min(width, maxwidth)
#
#  result.width = width
#  result.height = height
#
#proc genBox(elem: Element, w: int, h: int, x: int = 0, y: int = 0): CSSBlockBox =
#  if elem.cssvalues[RULE_DISPLAY].display == DISPLAY_NONE:
#    return nil
#  result = CSSBlockBox()
#
type
  Frame = object
    node: Node
    maxwidth: int
    maxheight: int
    x: int
    y: int
    fromx: int
    box: CSSBox
    context: FormatContext

  FormatContext = enum
    CONTEXT_BLOCK, CONTEXT_INLINE

proc addText(frame: var Frame, text: Text) =
  let maxwidth = frame.maxwidth
  let fromx = frame.fromx
  let x = frame.x
  if maxwidth == 0: return
  if not (frame.box of CSSInlineBox): return
  var box = CSSInlineBox(frame.box)
  var r: Rune
  var rowbox = CSSRowBox(x: frame.x, y: frame.y)
  var i = 0
  var whitespace = false
  if fromx > x:
    let m = fromx - x + maxwidth
    var w = 0
    while i < text.data.len:
      let pi = i
      fastRuneAt(text.data, i, r)
      let rw = r.width()
      if rw + w > m:
        i = pi
        break
      else:
        if r.isWhitespace():
          if not whitespace:
            whitespace = true
            rowbox.runes.add(Rune(' '))
            inc rowbox.width
            w += rw
        else:
          if whitespace:
            whitespace = false
          rowbox.runes.add(r)
          inc rowbox.width
          w += rw

    box.content.add(rowbox)
    frame.x += rowbox.width

  if i < text.data.len:
    rowbox = CSSRowBox(x: frame.x, y: frame.y)
    var w = 0
    while i < text.data.len:
      let pi = i
      fastRuneAt(text.data, i, r)
      let rw = r.width()
      if rw + w > maxwidth:
        i = pi
        w = 0
        box.content.add(rowbox)
        frame.x += rowbox.width
        rowbox = CSSRowBox(x: frame.x, y: frame.y)
      else:
        rowbox.runes.add(r)
        inc rowbox.width
        w += rw

  if rowbox.width > 0:
    box.content.add(rowbox)
    frame.x += rowbox.width

proc alignBoxes*(buffer: Buffer) =
  #buffer.rootbox = buffer.document.root.genBox(buffer.width, buffer.height)
  buffer.rootbox = CSSBlockBox(x: 0, y: 0, width: buffer.width, height: buffer.height)
  buffer.rootbox.children.add(CSSInlineBox(x: 0, y: 0, width: buffer.width, height: buffer.height))
  var x = 0
  var stack: seq[Frame]
  stack.add(Frame(node: buffer.document.root, box: buffer.rootbox, x: 0, y: 0, fromx: 0, maxwidth: 80, context: CONTEXT_BLOCK))
  while stack.len > 0:
    var frame = stack.pop()
    let node = frame.node

    case frame.context 
    of CONTEXT_BLOCK:
      case node.nodeType
      of TEXT_NODE: #anonymous
        discard
      of ELEMENT_NODE: #new formatting context
        let elem = Element(node)
        case elem.cssvalues[RULE_DISPLAY].display
        of DISPLAY_BLOCK:
          let parent = frame.box
          frame.box = CSSBlockBox(x: frame.x, y: frame.y, width: frame.maxwidth)
          parent.children.add(frame.box)
          frame.context = CONTEXT_BLOCK
        of DISPLAY_INLINE:
          let parent = frame.box
          frame.box = CSSInlineBox(x: frame.x, y: frame.y, width: frame.maxwidth)
          parent.children.add(frame.box)
          frame.context = CONTEXT_INLINE
        of DISPLAY_NONE: continue
        else: discard #TODO
      else: discard
    of CONTEXT_INLINE:
      case node.nodeType
      of TEXT_NODE: #just add to existing inline box no problem
        let text = Text(node)
        frame.addText(text)
      of ELEMENT_NODE:
        let elem = Element(node)
        case elem.cssvalues[RULE_DISPLAY].display
        of DISPLAY_NONE: continue
        else:
          #ok this is the difficult part (TODO)
          #NOTE we're assuming the parent isn't inline, if it is we're screwed
          #basically what we have to do is:
          #* create a new anonymous BLOCK box
          #* for every previous INLINE box in parent (BLOCK) box, do:
          #*  copy INLINE box into new anonymous BLOCK box
          #*  delete INLINE box
          #* create a new BLOCK box (this one)
          #* NOTE after our BLOCK there's a continuation of the last INLINE box

          eprint "?????"
      else: discard

    # look ahead to figure out if inline box will have to be split
    #var i = node.childNodes.len - 1
    #while i >= 0:
    #  let child = node.childNodes[i]
    #  stack.add(Frame(node: child, box: frame.box, maxwidth: frame.maxwidth, x: frame.x, y: frame.y, fromx: frame.fromx, context: frame.context))

    var i = node.childNodes.len - 1
    while i >= 0:
      let child = node.childNodes[i]
      stack.add(Frame(node: child, box: frame.box, maxwidth: frame.maxwidth, x: frame.x, y: frame.y, fromx: frame.fromx, context: frame.context))
      dec i
