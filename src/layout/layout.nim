import unicode

import layout/box
import types/enums
import html/dom
import css/style
import io/buffer
import io/cell
import utils/twtstr

#type
#  Frame = object
#    node: Node
#    maxwidth: int
#    maxheight: int
#    box: CSSBox
#    context: FormatContext


#proc addText(state: var LayoutState, frame: var Frame, text: Text) =
#  let maxwidth = frame.maxwidth
#  let fromx = state.fromx
#  let x = state.x
#  if maxwidth == 0: return
#  if not (frame.box of CSSInlineBox): return
#  var box = CSSInlineBox(frame.box)
#  var r: Rune
#  var i = 0
#  var rowbox: CSSRowBox
#  if fromx > x:
#    rowbox = CSSRowBox(x: state.fromx, y: state.y)
#    let m = maxwidth - fromx + x
#    var w = 0
#    var lf = false
#    while i < text.data.len:
#      let pi = i
#      fastRuneAt(text.data, i, r)
#      let rw = r.width()
#      if rw + w > m:
#        i = pi
#        inc state.y
#        lf = true
#        break
#      else:
#        if r.isWhitespace():
#          if not state.whitespace:
#            state.whitespace = true
#            rowbox.runes.add(Rune(' '))
#            inc rowbox.width
#            w += rw
#        else:
#          if state.whitespace:
#            state.whitespace = false
#          rowbox.runes.add(r)
#          inc rowbox.width
#          w += rw
#
#    box.content.add(rowbox)
#    if lf:
#      state.fromx = 0
#    else:
#      state.fromx += rowbox.width
#
#  if i < text.data.len:
#    rowbox = CSSRowBox(x: state.x, y: state.y)
#    var w = 0
#    while i < text.data.len:
#      let pi = i
#      fastRuneAt(text.data, i, r)
#      let rw = r.width()
#      if rw + w > maxwidth:
#        i = pi
#        w = 0
#        box.content.add(rowbox)
#        state.fromx += rowbox.width
#        inc state.y
#        rowbox = CSSRowBox(x: state.x, y: state.y)
#      else:
#        rowbox.runes.add(r)
#        inc rowbox.width
#        w += rw
#
#  if rowbox.width > 0:
#    box.content.add(rowbox)
#    state.fromx += rowbox.width

#proc alignBoxes*(buffer: Buffer) =
#  #buffer.rootbox = buffer.document.root.genBox(buffer.width, buffer.height)
#  buffer.rootbox = CSSBlockBox(x: 0, y: 0, width: buffer.width, height: buffer.height)
#  buffer.rootbox.children.add(CSSInlineBox(x: 0, y: 0, width: buffer.width, height: buffer.height))
#  var x = 0
#  var stack: seq[Frame]
#  var state: LayoutState
#  stack.add(Frame(node: buffer.document.root, box: buffer.rootbox, maxwidth: 80, context: CONTEXT_BLOCK))
#  while stack.len > 0:
#    var frame = stack.pop()
#    let node = frame.node
#
#    case frame.context 
#    of CONTEXT_BLOCK:
#      case node.nodeType
#      of TEXT_NODE: #anonymous
#        discard
#      of ELEMENT_NODE: #new formatting context
#        let elem = Element(node)
#        case elem.cssvalues[RULE_DISPLAY].display
#        of DISPLAY_BLOCK:
#          let parent = frame.box
#          state.whitespace = false
#          frame.box = CSSBlockBox(x: state.x, y: state.y, width: frame.maxwidth)
#          parent.children.add(frame.box)
#          frame.context = CONTEXT_BLOCK
#        of DISPLAY_INLINE:
#          let parent = frame.box
#          frame.box = CSSInlineBox(x: state.x, y: state.y, width: frame.maxwidth)
#          parent.children.add(frame.box)
#          frame.context = CONTEXT_INLINE
#        of DISPLAY_NONE: continue
#        else: discard #TODO
#      else: discard
#    of CONTEXT_INLINE:
#      case node.nodeType
#      of TEXT_NODE: #just add to existing inline box no problem
#        let text = Text(node)
#        state.addText(frame, text)
#      of ELEMENT_NODE:
#        let elem = Element(node)
#        case elem.cssvalues[RULE_DISPLAY].display
#        of DISPLAY_NONE: continue
#        else:
#          #ok this is the difficult part (TODO)
#          #NOTE we're assuming the parent isn't inline, if it is we're screwed
#          #basically what we have to do is:
#          #* create a new anonymous BLOCK box
#          #* for every previous INLINE box in parent (BLOCK) box, do:
#          #*  copy INLINE box into new anonymous BLOCK box
#          #*  delete INLINE box
#          #* create a new BLOCK box (this one)
#          #* NOTE after our BLOCK there's a continuation of the last INLINE box
#
#          eprint "?????"
#      else: discard
#
#    var i = node.childNodes.len - 1
#    while i >= 0:
#      let child = node.childNodes[i]
#      stack.add(Frame(node: child, box: frame.box, maxwidth: frame.maxwidth, context: frame.context))
#      dec i

type
  LayoutState = object
    x: int
    y: int
    fromx: int
    whitespace: bool
    context: FormatContext

  FormatContext = enum
    CONTEXT_BLOCK, CONTEXT_INLINE

proc addChild(parent: var CSSBox, box: CSSBox) =
  if box == nil:
    return
  parent.height += box.height
  parent.children.add(box)

proc processNode(parent: CSSBox, node: Node): CSSBox =
  case node.nodeType
  of ELEMENT_NODE:
    let elem = Element(node)
    var box: CSSBox
    case elem.cssvalues[RULE_DISPLAY].display
    of DISPLAY_BLOCK:
      box = CSSBlockBox(x: parent.x, y: parent.y + parent.height, width: parent.width)
    of DISPLAY_INLINE:
      #TODO split this into its own thing
      #TODO also rethink this bc it isn't very great
      #TODO like, it doesn't work
      var fromx = parent.x
      if parent.children.len > 0 and parent.children[^1] of CSSInlineBox:
        let sib = CSSInlineBox(parent.children[^1])
        if sib.content.len > 0:
          fromx = sib.content[^1].x + sib.content[^1].width
        else:
          eprint "???"
      elif parent of CSSInlineBox:
        let sib = CSSInlineBox(parent)
        if sib.content.len > 0:
          fromx = sib.content[^1].x + sib.content[^1].width
        else:
          eprint "???"
      box = CSSInlineBox(x: parent.x, y: parent.y + parent.height, width: parent.width)
      CSSInlineBox(box).content.add(CSSRowBox(x: fromx, y: box.y))
    of DISPLAY_NONE:
      return nil
    else:
      return nil

    for child in elem.childNodes:
      CSSBox(box).addChild(processNode(box, child))
    return box
  of TEXT_NODE:
    let text = Text(node)
    #TODO not always anonymous
    var ibox = CSSInlineBox(x: parent.x, y: parent.y + parent.height, width: parent.width)
    var ws = true #TODO doesn't always start with newline
    let str = text.data

    if text.data.len == 0:
      return

    #TODO ok we'll have to rethink this methinks
    var fromx = ibox.x
    if parent.children.len > 0 and parent.children[^1] of CSSInlineBox:
      let sib = CSSInlineBox(parent.children[^1])
      if sib.content.len > 0:
        fromx = sib.content[^1].x + sib.content[^1].width
      else:
        eprint "???"
    elif parent of CSSInlineBox:
      let sib = CSSInlineBox(parent)
      if sib.content.len > 0:
        fromx = sib.content[^1].x + sib.content[^1].width
      else:
        eprint "???"

    var i = 0
    var w = 0
    var rowi = 0
    var rowbox = CSSRowBox(x: fromx, y: ibox.y + rowi)
    var r: Rune
    while i < text.data.len:
      fastRuneAt(text.data, i, r)
      if w + r.width() > ibox.width:
        ibox.content.add(rowbox)
        inc rowi
        rowbox = CSSRowBox(x: ibox.x, y: ibox.y + rowi)
      if r.isWhitespace():
        if ws:
          continue
        else:
          ws = true
      else:
        ws = false
      rowbox.width += r.width()
      rowbox.runes.add(r)
    if rowbox.runes.len > 0:
      ibox.content.add(rowbox)
      inc rowi

    ibox.height += rowi
    return ibox
  else: discard
  return nil

proc alignBoxes*(buffer: Buffer) =
  buffer.rootbox = CSSBlockBox(x: 0, y: 0, width: buffer.width, height: 0)
  for child in buffer.document.root.childNodes:
    buffer.rootbox.addChild(processNode(buffer.rootbox, child))
