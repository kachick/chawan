import std/algorithm
import std/math
import std/options
import std/unicode

import css/cssvalues
import css/stylednode
import img/bitmap
import layout/box
import layout/layoutunit
import types/winattrs
import utils/luwrap
import utils/strwidth
import utils/twtstr
import utils/widthconv

type
  LayoutContext = ref object
    attrsp: ptr WindowAttributes
    positioned: seq[AvailableSpace]
    myRootProperties: CSSComputedValues

  # min-content: box width is longest word's width
  # max-content: box width is content width without wrapping
  # stretch: box width is n px wide
  # fit-content: also known as shrink-to-fit, box width is
  #   min(max-content, stretch(availableWidth))
  #   in other words, as wide as needed, but wrap if wider than allowed
  # (note: I write width here, but it can apply for any constraint)
  SizeConstraintType = enum
    scStretch, scFitContent, scMinContent, scMaxContent

  SizeConstraint = object
    t: SizeConstraintType
    u: LayoutUnit

  AvailableSpace = array[DimensionType, SizeConstraint]

  ResolvedSizes = object
    margin: RelativeRect
    padding: RelativeRect
    positioned: RelativeRect
    space: AvailableSpace
    minMaxSizes: array[DimensionType, Span]

const DefaultSpan = Span(start: 0, send: LayoutUnit.high)

proc `minWidth=`(sizes: var ResolvedSizes; w: LayoutUnit) =
  sizes.minMaxSizes[dtHorizontal].start = w

proc `maxWidth=`(sizes: var ResolvedSizes; w: LayoutUnit) =
  sizes.minMaxSizes[dtHorizontal].send = w

proc `minHeight=`(sizes: var ResolvedSizes; h: LayoutUnit) =
  sizes.minMaxSizes[dtVertical].start = h

proc `maxHeight=`(sizes: var ResolvedSizes; h: LayoutUnit) =
  sizes.minMaxSizes[dtVertical].send = h

func dimSum(rect: RelativeRect; dim: DimensionType): LayoutUnit =
  return rect[dim].start + rect[dim].send

func opposite(dim: DimensionType): DimensionType =
  case dim
  of dtHorizontal: return dtVertical
  of dtVertical: return dtHorizontal

func availableSpace(w, h: SizeConstraint): AvailableSpace =
  return [dtHorizontal: w, dtVertical: h]

func w(space: AvailableSpace): SizeConstraint {.inline.} =
  return space[dtHorizontal]

func w(space: var AvailableSpace): var SizeConstraint {.inline.} =
  return space[dtHorizontal]

func `w=`(space: var AvailableSpace; w: SizeConstraint) {.inline.} =
  space[dtHorizontal] = w

func h(space: var AvailableSpace): var SizeConstraint {.inline.} =
  return space[dtVertical]

func h(space: AvailableSpace): SizeConstraint {.inline.} =
  return space[dtVertical]

func `h=`(space: var AvailableSpace; h: SizeConstraint) {.inline.} =
  space[dtVertical] = h

template attrs(state: LayoutContext): WindowAttributes =
  state.attrsp[]

func maxContent(): SizeConstraint =
  return SizeConstraint(t: scMaxContent)

func stretch(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: scStretch, u: u)

func fitContent(u: LayoutUnit): SizeConstraint =
  return SizeConstraint(t: scFitContent, u: u)

func fitContent(sc: SizeConstraint): SizeConstraint =
  case sc.t
  of scMinContent, scMaxContent:
    return sc
  of scStretch, scFitContent:
    return SizeConstraint(t: scFitContent, u: sc.u)

func isDefinite(sc: SizeConstraint): bool =
  return sc.t in {scStretch, scFitContent}

# Layout (2nd pass)
func px(l: CSSLength; lctx: LayoutContext; p: LayoutUnit = 0):
    LayoutUnit {.inline.} =
  return px(l, lctx.attrs, p)

func px(l: CSSLength; lctx: LayoutContext; p: Option[LayoutUnit]):
    Option[LayoutUnit] {.inline.} =
  if l.unit == cuPerc and p.isNone:
    return none(LayoutUnit)
  return some(px(l, lctx.attrs, p.get(0)))

func canpx(l: CSSLength; sc: SizeConstraint): bool =
  return not l.auto and (l.unit != cuPerc or sc.isDefinite())

func canpx(l: CSSLength; p: Option[LayoutUnit]): bool =
  return not l.auto and (l.unit != cuPerc or p.isSome)

# Note: for margins only
# For percentages, use 0 for indefinite, and containing box's size for
# definite.
func px(l: CSSLength; lctx: LayoutContext; p: SizeConstraint): LayoutUnit =
  if l.unit == cuPerc:
    case p.t
    of scMinContent, scMaxContent:
      return 0
    of scStretch, scFitContent:
      return l.px(lctx, p.u)
  return px(l, lctx.attrs, 0)

func stretchOrMaxContent(l: CSSLength; lctx: LayoutContext; sc: SizeConstraint):
    SizeConstraint =
  if l.canpx(sc):
    return stretch(l.px(lctx, sc))
  return maxContent()

func applySizeConstraint(u: LayoutUnit; availableSize: SizeConstraint):
    LayoutUnit =
  case availableSize.t
  of scStretch:
    return availableSize.u
  of scMinContent, scMaxContent:
    # must be calculated elsewhere...
    return u
  of scFitContent:
    return min(u, availableSize.u)

type
  BlockContext = object
    lctx: LayoutContext
    marginTodo: Strut
    # We use a linked list to set the correct BFC offset and relative offset
    # for every block with an unresolved y offset on margin resolution.
    # marginTarget is a pointer to the last un-resolved ancestor.
    # ancestorsHead is a pointer to the last element of the ancestor list
    # (which may in fact be a pointer to the BPS of a previous sibling's
    # child).
    # parentBps is a pointer to the currently layouted parent block's BPS.
    marginTarget: BlockPositionState
    ancestorsHead: BlockPositionState
    parentBps: BlockPositionState
    exclusions: seq[Exclusion]
    unpositionedFloats: seq[UnpositionedFloat]
    maxFloatHeight: LayoutUnit
    clearOffset: LayoutUnit

  UnpositionedFloat = object
    parentBps: BlockPositionState
    space: AvailableSpace
    box: BlockBox

  BlockPositionState = ref object
    next: BlockPositionState
    box: BlockBox
    offset: Offset # offset relative to the block formatting context
    resolved: bool # has the position been resolved yet?

  Exclusion = object
    offset: Offset
    size: Size
    t: CSSFloat

  Strut = object
    pos: LayoutUnit
    neg: LayoutUnit

type
  LineBoxState = object
    atomstates: seq[InlineAtomState]
    baseline: LayoutUnit
    lineHeight: LayoutUnit
    paddingTop: LayoutUnit
    paddingBottom: LayoutUnit
    line: LineBox
    availableWidth: LayoutUnit
    hasExclusion: bool
    charwidth: int
    # Set at the end of layoutText. It helps determine the beginning of the
    # next inline fragment.
    widthAfterWhitespace: LayoutUnit
    # minimum height to fit all inline atoms
    minHeight: LayoutUnit

  LineBox = ref object
    atoms: seq[InlineAtom]
    size: Size
    offsety: LayoutUnit # offset of line in root fragment
    height: LayoutUnit # height used for painting; does not include padding

  InlineAtomState = object
    vertalign: CSSVerticalAlign
    baseline: LayoutUnit
    marginTop: LayoutUnit
    marginBottom: LayoutUnit

  InlineContext = object
    root: RootInlineFragment
    bctx: ptr BlockContext
    bfcOffset: Offset
    currentLine: LineBoxState
    hasshy: bool
    lctx: LayoutContext
    lines: seq[LineBox]
    space: AvailableSpace
    whitespacenum: int
    whitespaceIsLF: bool
    whitespaceFragment: InlineFragment
    word: InlineAtom
    wordstate: InlineAtomState
    wrappos: int # position of last wrapping opportunity, or -1
    firstTextFragment: InlineFragment
    lastTextFragment: InlineFragment

  InlineState = object
    computed: CSSComputedValues
    node: StyledNode
    fragment: InlineFragment
    firstLine: bool
    startOffsetTop: Offset
    # we do not want to collapse newlines over tag boundaries, so these are
    # in state
    lastrw: int # last rune width of the previous word
    firstrw: int # first rune width of the current word
    prevrw: int # last processed rune's width

func whitespacepre(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WhitespacePre, WhitespacePreLine,
    WhitespacePreWrap}

func nowrap(computed: CSSComputedValues): bool =
  computed{"white-space"} in {WhitespaceNowrap, WhitespacePre}

func cellWidth(lctx: LayoutContext): int =
  lctx.attrs.ppc

func cellWidth(ictx: InlineContext): int =
  ictx.lctx.cellWidth

func cellHeight(lctx: LayoutContext): int =
  lctx.attrs.ppl

func cellHeight(ictx: InlineContext): int =
  ictx.lctx.attrs.ppl

template atoms(state: LineBoxState): untyped =
  state.line.atoms

template size(state: LineBoxState): untyped =
  state.line.size

template offsety(state: LineBoxState): untyped =
  state.line.offsety

func size(ictx: var InlineContext): var Size =
  ictx.root.state.size

# Whitespace between words
func computeShift(ictx: InlineContext; state: InlineState): LayoutUnit =
  if ictx.whitespacenum == 0:
    return 0
  if ictx.whitespaceIsLF and state.lastrw == 2 and state.firstrw == 2:
    # skip line feed between double-width characters
    return 0
  if not state.computed.whitespacepre:
    if ictx.currentLine.atoms.len == 0 or
        ictx.currentLine.atoms[^1].t == iatSpacing:
      return 0
  return ictx.cellWidth * ictx.whitespacenum

proc applyLineHeight(ictx: InlineContext; state: var LineBoxState;
    computed: CSSComputedValues) =
  let lctx = ictx.lctx
  #TODO this should be computed during cascading.
  let lineHeight = if computed{"line-height"}.auto: # ergo normal
    lctx.cellHeight.toLayoutUnit
  else:
    # Percentage: refers to the font size of the element itself.
    computed{"line-height"}.px(lctx, lctx.cellHeight)
  let paddingTop = computed{"padding-top"}.px(lctx, ictx.space.w)
  let paddingBottom = computed{"padding-bottom"}.px(lctx, ictx.space.w)
  state.paddingTop = max(paddingTop, state.paddingTop)
  state.paddingBottom = max(paddingBottom, state.paddingBottom)
  state.lineHeight = max(lineHeight, state.lineHeight)

proc newWord(ictx: var InlineContext; state: var InlineState) =
  ictx.word = InlineAtom(
    t: iatWord,
    size: size(w = 0, h = ictx.cellHeight)
  )
  ictx.wordstate = InlineAtomState(
    vertalign: state.computed{"vertical-align"},
    baseline: ictx.cellHeight
  )
  ictx.wrappos = -1
  ictx.hasshy = false

proc horizontalAlignLines(ictx: var InlineContext; align: CSSTextAlign) =
  let width = case ictx.space.w.t
  of scMinContent, scMaxContent:
    ictx.size.w
  of scFitContent:
    min(ictx.size.w, ictx.space.w.u)
  of scStretch:
    max(ictx.size.w, ictx.space.w.u)
  # we don't support directions for now so left = start and right = end
  case align
  of TextAlignStart, TextAlignLeft, TextAlignChaLeft, TextAlignJustify:
    discard
  of TextAlignEnd, TextAlignRight, TextAlignChaRight:
    # move everything
    for line in ictx.lines:
      let x = max(width, line.size.w) - line.size.w
      for atom in line.atoms:
        atom.offset.x += x
        ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)
  of TextAlignCenter, TextAlignChaCenter:
    # NOTE if we need line x offsets, use:
    #let width = width - line.offset.x
    for line in ictx.lines:
      let x = max((max(width, line.size.w)) div 2 - line.size.w div 2, 0)
      for atom in line.atoms:
        atom.offset.x += x
        ictx.size.w = max(atom.offset.x + atom.size.w, ictx.size.w)

# Calculate the line's baseline based on its atoms' baseline.
func calcBaseline(currentLine: LineBoxState; lctx: LayoutContext): LayoutUnit =
  let lineHeight = currentLine.lineHeight
  var baseline = lineHeight
  for i, atom in currentLine.atoms:
    let iastate = currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      let len = iastate.vertalign.length.px(lctx, lineHeight)
      baseline = max(baseline, iastate.baseline + len)
    of VerticalAlignTop, VerticalAlignBottom:
      baseline = max(baseline, atom.size.h)
    of VerticalAlignMiddle:
      baseline = max(baseline, atom.size.h div 2)
    else:
      baseline = max(baseline, iastate.baseline)
  return baseline

# Resize the line's height based on atoms' height and baseline.
# The line height should be at least as high as the highest baseline used by
# an atom plus that atom's height.
func resizeLine(currentLine: LineBoxState; lctx: LayoutContext): LayoutUnit =
  let baseline = currentLine.baseline
  let lineHeight = currentLine.lineHeight
  var h = currentLine.size.h
  for i, atom in currentLine.atoms:
    let iastate = currentLine.atomstates[i]
    # In all cases, the line's height must at least equal the atom's height.
    # (Where the atom is actually placed is irrelevant here.)
    h = max(h, atom.size.h)
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      # Line height must be at least as high as
      # (line baseline) - (atom baseline) + (atom height) + (extra height).
      let len = iastate.vertalign.length.px(lctx, lineHeight)
      h = max(baseline - iastate.baseline + atom.size.h + len, h)
    of VerticalAlignMiddle:
      # Line height must be at least
      # (line baseline) + (atom height / 2).
      h = max(baseline + atom.size.h div 2, h)
    of VerticalAlignTop, VerticalAlignBottom:
      # Line height must be at least atom height (already ensured above.)
      discard
    else:
      # See baseline (with len = 0).
      h = max(baseline - iastate.baseline + atom.size.h, h)
  return h

# returns marginTop
proc positionAtoms(currentLine: LineBoxState; lctx: LayoutContext): LayoutUnit =
  let lineHeight = currentLine.lineHeight
  let baseline = currentLine.baseline
  var marginTop: LayoutUnit = 0
  for i, atom in currentLine.atoms:
    let iastate = currentLine.atomstates[i]
    case iastate.vertalign.keyword
    of VerticalAlignBaseline:
      # Atom is placed at (line baseline) - (atom baseline) - len
      let len = iastate.vertalign.length.px(lctx, lineHeight)
      atom.offset.y = baseline - iastate.baseline - len
    of VerticalAlignMiddle:
      # Atom is placed at (line baseline) - ((atom height) / 2)
      atom.offset.y = baseline - atom.size.h div 2
    of VerticalAlignTop:
      # Atom is placed at the top of the line.
      atom.offset.y = 0
    of VerticalAlignBottom:
      # Atom is placed at the bottom of the line.
      atom.offset.y = currentLine.size.h - atom.size.h
    else:
      # See baseline (with len = 0).
      atom.offset.y = baseline - iastate.baseline
    # Find the best top margin of all atoms.
    # We are looking for the lowest top edge of the line, so we have to do this
    # after we know where the atoms will be placed.
    # Note: we used to calculate the bottom edge based on margins too, but this
    # generated pointless empty lines so I removed it.
    marginTop = max(iastate.marginTop - atom.offset.y, marginTop)
  return marginTop

proc shiftAtoms(currentLine: var LineBoxState; marginTop: LayoutUnit;
    cellHeight: int) =
  let paddingTop = currentLine.paddingTop
  let offsety = currentLine.offsety
  for atom in currentLine.atoms:
    let atomy = atom.offset.y
    atom.offset.y = (atomy + marginTop + paddingTop + offsety).round(cellHeight)
    currentLine.minHeight = max(currentLine.minHeight,
      atomy - offsety + atom.size.h)

# Align atoms (inline boxes, text, etc.) vertically (i.e. along the block/y
# axis) inside the line.
proc verticalAlignLine(ictx: var InlineContext) =
  # Start with line-height as the baseline and line height.
  let lineHeight = ictx.currentLine.lineHeight
  ictx.currentLine.size.h = lineHeight
  let ch = ictx.cellHeight
  # Find baseline.
  ictx.currentLine.baseline = ictx.currentLine.calcBaseline(ictx.lctx).round(ch)
  # Resize according to the baseline and atom sizes.
  ictx.currentLine.size.h = ictx.currentLine.resizeLine(ictx.lctx)
  # Now we can calculate the actual position of atoms inside the line.
  let marginTop = ictx.currentLine.positionAtoms(ictx.lctx)
  # Finally, offset all atoms' y position by the largest top margin and the
  # line box's top padding.
  ictx.currentLine.shiftAtoms(marginTop, ch)
  #TODO this does not really work with rounding :/
  ictx.currentLine.baseline += ictx.currentLine.paddingTop
  # Ensure that the line is exactly as high as its highest atom demands,
  # rounded up to the next line.
  # (This is almost the same as completely ignoring line height. However, there
  # *is* a difference, because line height is still taken into account when
  # positioning the atoms.)
  ictx.currentLine.size.h = ictx.currentLine.minHeight.ceilTo(ch)
  # Now, if we got a height that is lower than cell height *and* line height,
  # then set it back to the cell height. (This is to avoid the situation where
  # we would swallow hard line breaks with <br>.)
  if lineHeight >= ch and ictx.currentLine.size.h < ch:
    ictx.currentLine.size.h = ch
  # Set the line height to size.h.
  ictx.currentLine.line.height = ictx.currentLine.size.h

proc putAtom(state: var LineBoxState; atom: InlineAtom;
    iastate: InlineAtomState; fragment: InlineFragment) =
  state.atomstates.add(iastate)
  state.atoms.add(atom)
  fragment.state.atoms.add(atom)

proc addSpacing(ictx: var InlineContext; width, height: LayoutUnit;
    state: InlineState; hang = false) =
  let spacing = InlineAtom(
    t: iatSpacing,
    size: size(w = width, h = height),
    offset: offset(x = ictx.currentLine.size.w, y = 0)
  )
  let iastate = InlineAtomState(baseline: height)
  if not hang:
    # In some cases, whitespace may "hang" at the end of the line. This means
    # it is written, but is not actually counted in the box's width.
    ictx.currentLine.size.w += width
  ictx.currentLine.putAtom(spacing, iastate, ictx.whitespaceFragment)

proc flushWhitespace(ictx: var InlineContext; state: InlineState;
    hang = false) =
  let shift = ictx.computeShift(state)
  ictx.currentLine.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  if shift > 0:
    ictx.addSpacing(shift, ictx.cellHeight, state, hang)

# Prepare the next line's initial width and available width.
# (If space on the left is excluded by floats, set the initial width to
# the end of that space. If space on the right is excluded, set the available
# width to that space.)
proc initLine(ictx: var InlineContext) =
  ictx.currentLine.availableWidth = ictx.space.w.u
  let bctx = ictx.bctx
  #TODO what if maxContent/minContent?
  if bctx.exclusions.len != 0:
    let bfcOffset = ictx.bfcOffset
    let y = ictx.currentLine.offsety + bfcOffset.y
    var left = bfcOffset.x
    var right = bfcOffset.x + ictx.currentLine.availableWidth
    for ex in bctx.exclusions:
      if ex.offset.y <= y and y < ex.offset.y + ex.size.h:
        ictx.currentLine.hasExclusion = true
        if ex.t == FloatLeft:
          left = ex.offset.x + ex.size.w
        else:
          right = ex.offset.x
    ictx.currentLine.line.size.w = left - bfcOffset.x
    ictx.currentLine.availableWidth = right - bfcOffset.x

proc finishLine(ictx: var InlineContext; state: var InlineState; wrap: bool;
    force = false) =
  if ictx.currentLine.atoms.len != 0 or force:
    let whitespace = state.computed{"white-space"}
    if whitespace == WhitespacePre:
      ictx.flushWhitespace(state)
    elif whitespace == WhitespacePreWrap:
      ictx.flushWhitespace(state, hang = true)
    else:
      ictx.whitespacenum = 0
    ictx.verticalAlignLine()
    # add line to ictx
    let y = ictx.currentLine.offsety
    # * set first baseline if this is the first line box
    # * always set last baseline (so the baseline of the last line box remains)
    if ictx.lines.len == 0:
      ictx.root.state.firstBaseline = y + ictx.currentLine.baseline
    ictx.root.state.baseline = y + ictx.currentLine.baseline
    ictx.size.h += ictx.currentLine.size.h
    let lineWidth = if wrap:
      ictx.currentLine.availableWidth
    else:
      ictx.currentLine.size.w
    if state.firstLine:
      #TODO padding top
      state.fragment.state.startOffset = offset(
        x = state.startOffsetTop.x,
        y = y + ictx.currentLine.size.h
      )
      state.firstLine = false
    ictx.size.w = max(ictx.size.w, lineWidth)
    ictx.lines.add(ictx.currentLine.line)
    ictx.currentLine = LineBoxState(
      line: LineBox(offsety: y + ictx.currentLine.size.h)
    )
    ictx.initLine()

proc addBackgroundAreas(ictx: var InlineContext; rootFragment: InlineFragment) =
  var traverseStack: seq[InlineFragment] = @[rootFragment]
  var currentStack: seq[InlineFragment] = @[]
  template top: InlineFragment = currentStack[^1]
  var atomIdx = 0
  var lineSkipped = false
  for line in ictx.lines:
    if line.atoms.len == 0:
      # no atoms here; set lineSkipped to true so that we don't accidentally
      # extend background areas over this
      lineSkipped = true
      continue
    var prevEnd: LayoutUnit = 0
    for atom in line.atoms:
      if currentStack.len == 0 or atomIdx >= top.state.atoms.len:
        atomIdx = 0
        while true:
          let thisNode = traverseStack.pop()
          if thisNode == nil: # sentinel found
            let oldTop = currentStack.pop()
            # finish oldTop area
            if oldTop.state.areas[^1].offset.y == line.offsety:
              # if offset.y is this offsety, then it means that we added it on
              # this line, so we just have to set its width
              if prevEnd > 0:
                oldTop.state.areas[^1].size.w = prevEnd -
                  oldTop.state.areas[^1].offset.x
              else:
                # fragment got dropped without prevEnd moving anywhere; delete
                # area
                oldTop.state.areas.setLen(oldTop.state.areas.high)
            elif prevEnd > 0:
              # offset.y is presumably from a previous line
              # (if prevEnd is 0, then the area doesn't extend to this line,
              # so we do not have to do anything.)
              let x = line.atoms[0].offset.x
              let w = prevEnd - x
              if oldTop.state.areas[^1].offset.x == x and
                  oldTop.state.areas[^1].size.w == w:
                # same vertical dimensions; just extend.
                oldTop.state.areas[^1].size.h = line.offsety + line.height -
                  oldTop.state.areas[^1].offset.y
              else:
                # vertical dimensions differ; add new area.
                oldTop.state.areas.add(Area(
                  offset: offset(x = x, y = line.offsety),
                  size: size(w = w, h = line.height)
                ))
            continue
          traverseStack.add(nil) # sentinel
          for i in countdown(thisNode.children.high, 0):
            traverseStack.add(thisNode.children[i])
          thisNode.state.areas.add(Area(
            offset: offset(x = atom.offset.x, y = line.offsety),
            size: size(w = atom.size.w, h = line.height)
          ))
          currentStack.add(thisNode)
          if thisNode.state.atoms.len > 0:
            break
      prevEnd = atom.offset.x + atom.size.w
      assert top.state.atoms[atomIdx] == atom
      inc atomIdx
    # extend current areas
    for node in currentStack:
      if node.state.areas[^1].offset.y == line.offsety:
        # added in this iteration. no need to extend vertically, but make sure
        # that it reaches prevEnd.
        node.state.areas[^1].size.w = prevEnd - node.state.areas[^1].offset.x
        continue
      let x1 = node.state.areas[^1].offset.x
      let x2 = node.state.areas[^1].offset.x + node.state.areas[^1].size.w
      if x1 == line.atoms[0].offset.x and x2 == prevEnd and not lineSkipped:
        # horizontal dimensions are the same as for the last area. just move its
        # vertical end to the current line's end.
        node.state.areas[^1].size.h = line.offsety + line.height -
          node.state.areas[^1].offset.y
      else:
        # horizontal dimensions differ; add a new area
        node.state.areas.add(Area(
          offset: offset(x = line.atoms[0].offset.x, y = line.offsety),
          size: size(w = prevEnd - line.atoms[0].offset.x, h = line.height)
        ))
    lineSkipped = false

func xminwidth(atom: InlineAtom): LayoutUnit =
  if atom.t == iatInlineBlock:
    return atom.innerbox.state.xminwidth
  return atom.size.w

func shouldWrap(ictx: InlineContext; w: LayoutUnit;
    pcomputed: CSSComputedValues): bool =
  if pcomputed != nil and pcomputed.nowrap:
    return false
  if ictx.space.w.t == scMaxContent:
    return false # no wrap with max-content
  if ictx.space.w.t == scMinContent:
    return true # always wrap with min-content
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

func shouldWrap2(ictx: InlineContext; w: LayoutUnit): bool =
  if not ictx.currentLine.hasExclusion:
    return false
  return ictx.currentLine.size.w + w > ictx.currentLine.availableWidth

# Start a new line, even if the previous one is empty
proc flushLine(ictx: var InlineContext; state: var InlineState) =
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  ictx.finishLine(state, wrap = false, force = true)

# Add an inline atom atom, with state iastate.
# Returns true on newline.
proc addAtom(ictx: var InlineContext; state: var InlineState;
    iastate: InlineAtomState; atom: InlineAtom): bool =
  result = false
  var shift = ictx.computeShift(state)
  ictx.currentLine.charwidth += ictx.whitespacenum
  ictx.whitespacenum = 0
  # Line wrapping
  if ictx.shouldWrap(atom.size.w + shift, state.computed):
    ictx.finishLine(state, wrap = true, force = false)
    result = true
    # Recompute on newline
    shift = ictx.computeShift(state)
    # For floats: flush lines until we can place the atom.
    #TODO this is inefficient
    while ictx.shouldWrap2(atom.size.w + shift):
      ictx.applyLineHeight(ictx.currentLine, state.computed)
      ictx.currentLine.lineHeight = max(ictx.currentLine.lineHeight,
        ictx.cellHeight)
      ictx.finishLine(state, wrap = false, force = true)
      # Recompute on newline
      shift = ictx.computeShift(state)
  if atom.size.w > 0 and atom.size.h > 0:
    if shift > 0:
      ictx.addSpacing(shift, ictx.cellHeight, state)
    ictx.root.state.xminwidth = max(ictx.root.state.xminwidth, atom.xminwidth)
    ictx.applyLineHeight(ictx.currentLine, state.computed)
    if atom.t != iatWord:
      ictx.currentLine.charwidth = 0
    ictx.currentLine.putAtom(atom, iastate, state.fragment)
    atom.offset.x += ictx.currentLine.size.w
    ictx.currentLine.size.w += atom.size.w

proc addWord(ictx: var InlineContext; state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    ictx.word.str.mnormalize() #TODO this may break on EOL.
    result = ictx.addAtom(state, ictx.wordstate, ictx.word)
    ictx.newWord(state)

proc addWordEOL(ictx: var InlineContext; state: var InlineState): bool =
  result = false
  if ictx.word.str != "":
    if ictx.wrappos != -1:
      let leftstr = ictx.word.str.substr(ictx.wrappos)
      ictx.word.str.setLen(ictx.wrappos)
      if ictx.hasshy:
        const shy = $Rune(0xAD) # soft hyphen
        ictx.word.str &= shy
        ictx.hasshy = false
      result = ictx.addWord(state)
      ictx.word.str = leftstr
      ictx.word.size.w = leftstr.width() * ictx.cellWidth
    else:
      result = ictx.addWord(state)

proc checkWrap(ictx: var InlineContext; state: var InlineState; r: Rune) =
  if state.computed.nowrap:
    return
  let shift = ictx.computeShift(state)
  let rw = r.width()
  state.prevrw = rw
  if ictx.word.str.len == 0:
    state.firstrw = rw
  if rw >= 2:
    # remove wrap opportunity, so we wrap properly on the last CJK char (instead
    # of any dash inside CJK sentences)
    ictx.wrappos = -1
  case state.computed{"word-break"}
  of WordBreakNormal:
    if rw == 2 or ictx.wrappos != -1: # break on cjk and wrap opportunities
      let plusWidth = ictx.word.size.w + shift + rw * ictx.cellWidth
      if ictx.shouldWrap(plusWidth, nil):
        if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
          ictx.finishLine(state, wrap = true)
          ictx.whitespacenum = 0
  of WordBreakBreakAll:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellWidth
    if ictx.shouldWrap(plusWidth, nil):
      if not ictx.addWordEOL(state): # no line wrapping occured in addAtom
        ictx.finishLine(state, wrap = true)
        ictx.whitespacenum = 0
  of WordBreakKeepAll:
    let plusWidth = ictx.word.size.w + shift + rw * ictx.cellWidth
    if ictx.shouldWrap(plusWidth, nil):
      ictx.finishLine(state, wrap = true)
      ictx.whitespacenum = 0

proc processWhitespace(ictx: var InlineContext; state: var InlineState;
    c: char) =
  discard ictx.addWord(state)
  case state.computed{"white-space"}
  of WhitespaceNormal, WhitespaceNowrap:
    if ictx.whitespacenum < 1:
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
      ictx.whitespaceIsLF = c == '\n'
    if c != '\n':
      ictx.whitespaceIsLF = false
  of WhitespacePreLine:
    if c == '\n':
      ictx.flushLine(state)
    elif ictx.whitespacenum < 1:
      ictx.whitespaceIsLF = false
      ictx.whitespacenum = 1
      ictx.whitespaceFragment = state.fragment
  of WhitespacePre, WhitespacePreWrap:
    #TODO whitespace type should be preserved here. (it isn't, because
    # it would break tabs in the current buffer model.)
    ictx.whitespaceIsLF = false
    if c == '\n':
      ictx.flushLine(state)
    elif c == '\t':
      let realWidth = ictx.currentLine.charwidth + ictx.whitespacenum
      let targetTabStops = realWidth div 8 + 1
      let targetWidth = targetTabStops * 8
      ictx.whitespacenum += targetWidth - realWidth
      ictx.whitespaceFragment = state.fragment
    else:
      inc ictx.whitespacenum
      ictx.whitespaceFragment = state.fragment
  # set the "last word's last rune width" to the previous rune width
  state.lastrw = state.prevrw

func initInlineContext(bctx: var BlockContext; space: AvailableSpace;
    bfcOffset: Offset; root: RootInlineFragment): InlineContext =
  var ictx = InlineContext(
    currentLine: LineBoxState(
      line: LineBox()
    ),
    bctx: addr bctx,
    lctx: bctx.lctx,
    bfcOffset: bfcOffset,
    space: space,
    root: root
  )
  ictx.initLine()
  return ictx

proc layoutTextLoop(ictx: var InlineContext; state: var InlineState;
    str: string) =
  var i = 0
  while i < str.len:
    let c = str[i]
    if c in Ascii:
      if c in AsciiWhitespace:
        ictx.processWhitespace(state, c)
      else:
        let r = Rune(c)
        ictx.checkWrap(state, r)
        ictx.word.str &= c
        let w = r.width()
        ictx.word.size.w += w * ictx.cellWidth
        ictx.currentLine.charwidth += w
        if c == '-': # ascii dash
          ictx.wrappos = ictx.word.str.len
          ictx.hasshy = false
      inc i
    else:
      var r: Rune
      fastRuneAt(str, i, r)
      ictx.checkWrap(state, r)
      if r == Rune(0xAD): # soft hyphen
        ictx.wrappos = ictx.word.str.len
        ictx.hasshy = true
      else:
        ictx.word.str &= r
        let w = r.width()
        ictx.word.size.w += w * ictx.cellWidth
        ictx.currentLine.charwidth += w
  discard ictx.addWord(state)
  let shift = ictx.computeShift(state)
  ictx.currentLine.widthAfterWhitespace = ictx.currentLine.size.w + shift

iterator transform(text: seq[string]; v: CSSTextTransform): string {.inline.} =
  if v == TextTransformNone:
    for str in text:
      yield str
  else:
    for str in text:
      let str = case v
      of TextTransformCapitalize: str.capitalizeLU()
      of TextTransformUppercase: str.toUpperLU()
      of TextTransformLowercase: str.toLowerLU()
      of TextTransformFullWidth: str.fullwidth()
      of TextTransformFullSizeKana: str.fullsize()
      of TextTransformChaHalfWidth: str.halfwidth()
      else: ""
      yield str

proc layoutText(ictx: var InlineContext; state: var InlineState;
    text: seq[string]) =
  for str in text.transform(state.computed{"text-transform"}):
    ictx.flushWhitespace(state)
    ictx.newWord(state)
    ictx.layoutTextLoop(state, str)

func spx(l: CSSLength; lctx: LayoutContext; p: SizeConstraint;
    computed: CSSComputedValues; padding: LayoutUnit): LayoutUnit =
  let u = l.px(lctx, p)
  if computed{"box-sizing"} == BoxSizingBorderBox:
    return max(u - padding, 0)
  return max(u, 0)

func spx(l: CSSLength; lctx: LayoutContext; p: Option[LayoutUnit];
    computed: CSSComputedValues; padding: LayoutUnit): Option[LayoutUnit] =
  let u = l.px(lctx, p)
  if u.isSome:
    let u = u.get
    if computed{"box-sizing"} == BoxSizingBorderBox:
      return some(max(u - padding, 0))
    return some(max(u, 0))
  return u

proc resolveContentWidth(sizes: var ResolvedSizes; widthpx: LayoutUnit;
    containingWidth: SizeConstraint; computed: CSSComputedValues;
    isauto = false) =
  if not sizes.space.w.isDefinite():
    # width is indefinite, so no conflicts can be resolved here.
    return
  let total = widthpx + sizes.margin.dimSum(dtHorizontal) +
    sizes.padding.dimSum(dtHorizontal)
  let underflow = containingWidth.u - total
  if isauto or sizes.space.w.t == scFitContent:
    if underflow >= 0:
      sizes.space.w = SizeConstraint(t: sizes.space.w.t, u: underflow)
    else:
      sizes.margin[dtHorizontal].send += underflow
  elif underflow > 0:
    if not computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin[dtHorizontal].send += underflow
    elif not computed{"margin-left"}.auto and computed{"margin-right"}.auto:
      sizes.margin[dtHorizontal].send = underflow
    elif computed{"margin-left"}.auto and not computed{"margin-right"}.auto:
      sizes.margin[dtHorizontal].start = underflow
    else:
      sizes.margin[dtHorizontal].start = underflow div 2
      sizes.margin[dtHorizontal].send = underflow div 2

proc resolveMargins(availableWidth: SizeConstraint; lctx: LayoutContext;
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return [
    dtHorizontal: Span(
      start: computed{"margin-left"}.px(lctx, availableWidth),
      send: computed{"margin-right"}.px(lctx, availableWidth),
    ),
    dtVertical: Span(
      start: computed{"margin-top"}.px(lctx, availableWidth),
      send: computed{"margin-bottom"}.px(lctx, availableWidth),
    )
  ]

proc resolvePadding(availableWidth: SizeConstraint; lctx: LayoutContext;
    computed: CSSComputedValues): RelativeRect =
  # Note: we use availableWidth for percentage resolution intentionally.
  return [
    dtHorizontal: Span(
      start: computed{"padding-left"}.px(lctx, availableWidth),
      send: computed{"padding-right"}.px(lctx, availableWidth)
    ),
    dtVertical: Span(
      start: computed{"padding-top"}.px(lctx, availableWidth),
      send: computed{"padding-bottom"}.px(lctx, availableWidth),
    )
  ]

func resolvePositioned(space: AvailableSpace; lctx: LayoutContext;
    computed: CSSComputedValues): RelativeRect =
  # As per standard, vertical percentages refer to the *height*, not the width
  # (unlike with margin/padding)
  return [
    dtHorizontal: Span(
      start: computed{"left"}.px(lctx, space.w),
      send: computed{"right"}.px(lctx, space.w)
    ),
    dtVertical: Span(
      start: computed{"top"}.px(lctx, space.h),
      send: computed{"bottom"}.px(lctx, space.h),
    )
  ]

proc resolveBlockWidth(sizes: var ResolvedSizes;
    containingWidth: SizeConstraint; computed: CSSComputedValues;
    lctx: LayoutContext) =
  let width = computed{"width"}
  let padding = sizes.padding.dimSum(dtHorizontal)
  var widthpx: LayoutUnit = 0
  if width.canpx(containingWidth):
    widthpx = width.spx(lctx, containingWidth, computed, padding)
    sizes.space.w = stretch(widthpx)
  sizes.resolveContentWidth(widthpx, containingWidth, computed, width.auto)
  if not computed{"max-width"}.auto:
    let maxWidth = computed{"max-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.maxWidth = maxWidth
    if sizes.space.w.t in {scStretch, scFitContent} and
        maxWidth < sizes.space.w.u or sizes.space.w.t == scMaxContent:
      sizes.space.w = stretch(maxWidth) #TODO is stretch ok here?
      if sizes.space.w.t == scStretch:
        # available width would stretch over max-width
        sizes.space.w = stretch(maxWidth)
      else: # scFitContent
        # available width could be higher than max-width (but not necessarily)
        sizes.space.w = fitContent(maxWidth)
      sizes.resolveContentWidth(maxWidth, containingWidth, computed)
  if not computed{"min-width"}.auto:
    let minWidth = computed{"min-width"}.spx(lctx, containingWidth, computed,
      padding)
    sizes.minWidth = minWidth
    if sizes.space.w.t in {scStretch, scFitContent} and
        minWidth > sizes.space.w.u or sizes.space.w.t == scMinContent:
      # two cases:
      # * available width is stretched under min-width. in this case,
      #   stretch to min-width instead.
      # * available width is fit under min-width. in this case, stretch to
      #   min-width as well (as we must satisfy min-width >= width).
      sizes.space.w = stretch(minWidth)
      sizes.resolveContentWidth(minWidth, containingWidth, computed)

proc resolveBlockHeight(sizes: var ResolvedSizes;
    containingHeight: SizeConstraint; percHeight: Option[LayoutUnit];
    computed: CSSComputedValues; lctx: LayoutContext) =
  let height = computed{"height"}
  let padding = sizes.padding.top + sizes.padding.bottom
  var heightpx: LayoutUnit = 0
  if height.canpx(percHeight):
    heightpx = height.spx(lctx, percHeight, computed, padding).get
    sizes.space.h = stretch(heightpx)
  if not computed{"max-height"}.auto:
    let maxHeight = computed{"max-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.maxHeight = maxHeight.get(high(LayoutUnit))
    if maxHeight.isSome:
      let maxHeight = maxHeight.get
      if sizes.space.h.t in {scStretch, scFitContent} and
          maxHeight < sizes.space.h.u or sizes.space.h.t == scMaxContent:
        # same reasoning as for width.
        if sizes.space.h.t == scStretch:
          sizes.space.h = stretch(maxHeight)
        else: # scFitContent
          sizes.space.h = fitContent(maxHeight)
  if not computed{"min-height"}.auto:
    let minHeight = computed{"min-height"}.spx(lctx, percHeight, computed,
      padding)
    sizes.minHeight = minHeight.get(0)
    if minHeight.isSome:
      let minHeight = minHeight.get
      if sizes.space.h.t in {scStretch, scFitContent} and
          minHeight > sizes.space.h.u or sizes.space.h.t == scMinContent:
        # same reasoning as for width.
        sizes.space.h = stretch(minHeight)

proc resolveAbsoluteSize(sizes: var ResolvedSizes; space: AvailableSpace;
    dim: DimensionType; cvalSize, cvalLeft, cvalRight: CSSLength;
    computed: CSSComputedValues; lctx: LayoutContext) =
  # Note: cvalLeft, cvalRight are top/bottom when called with vertical dim
  if cvalSize.auto:
    if space[dim].isDefinite:
      let u = max(space[dim].u - sizes.positioned.dimSum(dim) -
        sizes.margin.dimSum(dim) - sizes.padding.dimSum(dim), 0)
      if not cvalLeft.auto and not cvalRight.auto:
        # width is auto and left & right are not auto.
        # Solve for width.
        sizes.space[dim] = stretch(u)
      else:
        # Return shrink to fit and solve for left/right.
        sizes.space[dim] = fitContent(u)
    else:
      sizes.space[dim] = space[dim]
  else:
    let padding = sizes.padding.dimSum(dim)
    let sizepx = cvalSize.spx(lctx, space[dim], computed, padding)
    # We could solve for left/right here, as available width is known.
    # Nevertheless, it is only needed for positioning, so we do not solve
    # them yet.
    sizes.space[dim] = stretch(sizepx)

proc resolveBlockSizes(lctx: LayoutContext; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  var sizes = ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: resolvePadding(space.w, lctx, computed),
    # Take defined sizes if our width/height resolves to auto.
    # For block boxes, this is:
    # (width: stretch(parentWidth), height: max-content)
    space: space,
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  if computed{"position"} == PositionRelative:
    # only compute this when needed
    sizes.positioned = resolvePositioned(space, lctx, computed)
  # Finally, calculate available width and height.
  sizes.resolveBlockWidth(space.w, computed, lctx)
  sizes.resolveBlockHeight(space.h, percHeight, computed, lctx)
  return sizes

# Calculate and resolve available width & height for absolutely positioned
# boxes.
proc resolveAbsoluteSizes(lctx: LayoutContext; computed: CSSComputedValues):
    ResolvedSizes =
  let space = lctx.positioned[^1]
  var sizes = ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: resolvePadding(space.w, lctx, computed),
    positioned: resolvePositioned(space, lctx, computed),
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  sizes.resolveAbsoluteSize(space, dtHorizontal, computed{"width"},
    computed{"left"}, computed{"right"}, computed, lctx)
  #TODO this might be incorrect because of percHeight?
  sizes.resolveAbsoluteSize(space, dtVertical, computed{"height"},
    computed{"top"}, computed{"bottom"}, computed, lctx)
  return sizes

# Calculate and resolve available width & height for floating boxes.
proc resolveFloatSizes(lctx: LayoutContext; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  var space = availableSpace(
    w = fitContent(space.w),
    h = space.h
  )
  let padding = resolvePadding(space.w, lctx, computed)
  let inlinePadding = padding.dimSum(dtHorizontal)
  let blockPadding = padding.dimSum(dtVertical)
  let minWidth: LayoutUnit = if not computed{"min-width"}.auto:
    computed{"min-width"}.spx(lctx, space.w, computed, inlinePadding)
  else:
    0
  let maxWidth = if not computed{"max-width"}.auto:
    computed{"max-width"}.spx(lctx, space.w, computed, inlinePadding)
  else:
    high(LayoutUnit)
  let width = computed{"width"}
  if width.canpx(space.w):
    let widthpx = width.spx(lctx, space.w, computed, inlinePadding)
    space.w = stretch(clamp(widthpx, minWidth, maxWidth))
  elif space.w.isDefinite():
    space.w = fitContent(clamp(space.w.u, minWidth, maxWidth))
  let minHeight: LayoutUnit = if not computed{"min-height"}.auto:
    computed{"min-height"}.spx(lctx, percHeight, computed, blockPadding).get(0)
  else:
    0
  let maxHeight = if not computed{"max-height"}.auto:
    computed{"max-height"}.spx(lctx, percHeight, computed, blockPadding)
      .get(high(LayoutUnit))
  else:
    high(LayoutUnit)
  let height = computed{"height"}
  if height.canpx(space.h):
    let heightpx = height.px(lctx, space.h)
    space.h = stretch(clamp(heightpx, minHeight, maxHeight))
  elif space.h.isDefinite():
    space.h = fitContent(clamp(space.h.u, minHeight, maxHeight))
  return ResolvedSizes(
    margin: resolveMargins(space.w, lctx, computed),
    padding: padding,
    space: space,
    minMaxSizes: [
      dtHorizontal: Span(start: minWidth, send: maxWidth),
      dtVertical: Span(start: minHeight, send: maxHeight)
    ]
  )

# Calculate and resolve available width & height for box children.
# space: width/height of the containing box
# Note that this is not the final content size, just the amount of space
# available for content.
# The percentage width/height is generally
# availableSize.isDefinite() ? availableSize.u : 0, but for some reason it
# differs for the root height (TODO: and all heights in quirks mode) in that
# it uses the lctx height. Therefore we pass percHeight as a separate
# parameter. (TODO surely there is a better solution to this?)
proc resolveSizes(lctx: LayoutContext; space: AvailableSpace;
    percHeight: Option[LayoutUnit]; computed: CSSComputedValues):
    ResolvedSizes =
  if computed{"position"} == PositionAbsolute:
    return lctx.resolveAbsoluteSizes(computed)
  elif computed{"float"} != FloatNone:
    return lctx.resolveFloatSizes(space, percHeight, computed)
  else:
    return lctx.resolveBlockSizes(space, percHeight, computed)

func toPercSize(sc: SizeConstraint): Option[LayoutUnit] =
  if sc.isDefinite():
    return some(sc.u)
  return none(LayoutUnit)

proc append(a: var Strut; b: LayoutUnit) =
  if b < 0:
    a.neg = min(b, a.neg)
  else:
    a.pos = max(b, a.pos)

func sum(a: Strut): LayoutUnit =
  return a.pos + a.neg

proc layoutRootInline(bctx: var BlockContext; root: RootInlineFragment;
  space: AvailableSpace; computed: CSSComputedValues; offset, bfcOffset: Offset)
proc layoutBlock(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes)
proc layoutTableWrapper(bctx: BlockContext; box: BlockBox; sizes: ResolvedSizes)
proc layoutFlex(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes)
proc layoutInline(ictx: var InlineContext; fragment: InlineFragment)

# Note: padding must still be applied after this.
proc applySize(box: BlockBox; sizes: ResolvedSizes;
    maxChildSize: LayoutUnit; space: AvailableSpace; dim: DimensionType) =
  # Make the box as small/large as the content's width or specified width.
  box.state.size[dim] = maxChildSize.applySizeConstraint(space[dim])
  # Then, clamp it to minWidth and maxWidth (if applicable).
  let span = sizes.minMaxSizes[dim]
  box.state.size[dim] = clamp(box.state.size[dim], span.start, span.send)

proc applyWidth(box: BlockBox; sizes: ResolvedSizes;
    maxChildWidth: LayoutUnit; space: AvailableSpace) =
  box.applySize(sizes, maxChildWidth, space, dtHorizontal)

proc applyWidth(box: BlockBox; sizes: ResolvedSizes;
    maxChildWidth: LayoutUnit) =
  box.applyWidth(sizes, maxChildWidth, sizes.space)

proc applyHeight(box: BlockBox; sizes: ResolvedSizes;
    maxChildHeight: LayoutUnit) =
  box.applySize(sizes, maxChildHeight, sizes.space, dtVertical)

proc applyPadding(box: BlockBox; padding: RelativeRect) =
  box.state.size.w += padding.dimSum(dtHorizontal)
  box.state.size.h += padding.dimSum(dtVertical)

func bfcOffset(bctx: BlockContext): Offset =
  if bctx.parentBps != nil:
    return bctx.parentBps.offset
  return offset(x = 0, y = 0)

proc layoutInline(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes) =
  var bfcOffset = bctx.bfcOffset
  let offset = offset(x = sizes.padding.left, y = sizes.padding.top)
  bfcOffset.x += box.state.offset.x + offset.x
  bfcOffset.y += box.state.offset.y + offset.y
  bctx.layoutRootInline(box.inline, sizes.space, box.computed, offset,
    bfcOffset)
  box.state.xminwidth = max(box.state.xminwidth, box.inline.state.xminwidth)
  box.state.size.w = box.inline.state.size.w +
    sizes.padding.dimSum(dtHorizontal)
  box.applyWidth(sizes, box.inline.state.size.w)
  box.applyHeight(sizes, box.inline.state.size.h)
  box.applyPadding(sizes.padding)
  box.state.baseline = offset.y + box.inline.state.baseline
  box.state.firstBaseline = offset.y + box.inline.state.firstBaseline

const DisplayBlockLike = {DisplayBlock, DisplayListItem, DisplayInlineBlock}

# Return true if no more margin collapsing can occur for the current strut.
func canFlushMargins(box: BlockBox; sizes: ResolvedSizes): bool =
  if box.computed{"position"} == PositionAbsolute:
    return false
  return sizes.padding.top != 0 or sizes.padding.bottom != 0 or
    box.inline != nil or box.computed{"display"} notin DisplayBlockLike or
    box.computed{"clear"} != ClearNone

proc flushMargins(bctx: var BlockContext; box: BlockBox) =
  # Apply uncommitted margins.
  let margin = bctx.marginTodo.sum()
  if bctx.marginTarget == nil:
    box.state.offset.y += margin
  else:
    if bctx.marginTarget.box != nil:
      bctx.marginTarget.box.state.offset.y += margin
    var p = bctx.marginTarget
    while true:
      p.offset.y += margin
      p.resolved = true
      p = p.next
      if p == nil: break
    bctx.marginTarget = nil
  bctx.marginTodo = Strut()

proc clearFloats(offset: var Offset; bctx: var BlockContext; clear: CSSClear) =
  var y = bctx.bfcOffset.y + offset.y
  case clear
  of ClearLeft, ClearInlineStart:
    for ex in bctx.exclusions:
      if ex.t == FloatLeft:
        y = max(ex.offset.y + ex.size.h, y)
  of ClearRight, ClearInlineEnd:
    for ex in bctx.exclusions:
      if ex.t == FloatRight:
        y = max(ex.offset.y + ex.size.h, y)
  of ClearBoth:
    for ex in bctx.exclusions:
      y = max(ex.offset.y + ex.size.h, y)
  of ClearNone: assert false
  bctx.clearOffset = y
  offset.y = y - bctx.bfcOffset.y

type
  BlockState = object
    offset: Offset
    maxChildWidth: LayoutUnit
    totalFloatWidth: LayoutUnit # used for re-layouts
    space: AvailableSpace
    xminwidth: LayoutUnit
    prevParentBps: BlockPositionState
    needsReLayout: bool
    # State kept for when a re-layout is necessary:
    oldMarginTodo: Strut
    oldExclusionsLen: int
    initialMarginTarget: BlockPositionState
    initialTargetOffset: Offset
    initialParentOffset: Offset

func findNextFloatOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; float: CSSFloat; outw: var LayoutUnit): Offset =
  # Algorithm originally from QEmacs.
  var y = offset.y
  let leftStart = offset.x
  let rightStart = offset.x + max(size.w, space.w.u)
  while true:
    var left = leftStart
    var right = rightStart
    var miny = high(LayoutUnit)
    let cy2 = y + size.h
    for ex in bctx.exclusions:
      let ey2 = ex.offset.y + ex.size.h
      if cy2 >= ex.offset.y and y < ey2:
        let ex2 = ex.offset.x + ex.size.w
        if ex.t == FloatLeft and left < ex2:
          left = ex2
        if ex.t == FloatRight and right > ex.offset.x:
          right = ex.offset.x
        miny = min(ey2, miny)
    let w = right - left
    if w >= size.w or miny == high(LayoutUnit):
      # Enough space, or no other exclusions found at this y offset.
      outw = w
      if float == FloatLeft:
        return offset(x = left, y = y)
      else: # FloatRight
        return offset(x = right - size.w, y = y)
    # Move y to the bottom exclusion edge at the lowest y (where the exclusion
    # still intersects with the previous y).
    y = miny
  assert false

func findNextFloatOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; float: CSSFloat): Offset =
  var dummy: LayoutUnit
  return bctx.findNextFloatOffset(offset, size, space, float, dummy)

func findNextBlockOffset(bctx: BlockContext; offset: Offset; size: Size;
    space: AvailableSpace; outw: var LayoutUnit): Offset =
  return bctx.findNextFloatOffset(offset, size, space, FloatLeft, outw)

proc positionFloat(bctx: var BlockContext; child: BlockBox;
    space: AvailableSpace; bfcOffset: Offset) =
  let clear = child.computed{"clear"}
  if clear != ClearNone:
    child.state.offset.clearFloats(bctx, clear)
  let size = size(
    w = child.state.margin.dimSum(dtHorizontal) + child.state.size.w,
    h = child.state.margin.dimSum(dtVertical) + child.state.size.h
  )
  let childBfcOffset = offset(
    x = bfcOffset.x + child.state.offset.x - child.state.margin.left,
    y = max(bfcOffset.y + child.state.offset.y - child.state.margin.top,
      bctx.clearOffset)
  )
  assert space.w.t != scFitContent
  let ft = child.computed{"float"}
  assert ft != FloatNone
  let offset = bctx.findNextFloatOffset(childBfcOffset, size, space, ft)
  child.state.offset = offset(
    x = offset.x - bfcOffset.x + child.state.margin.left,
    y = offset.y - bfcOffset.y + child.state.margin.top
  )
  let ex = Exclusion(offset: offset, size: size, t: ft)
  bctx.exclusions.add(ex)
  bctx.maxFloatHeight = max(bctx.maxFloatHeight, ex.offset.y + ex.size.h)

proc positionFloats(bctx: var BlockContext) =
  for f in bctx.unpositionedFloats:
    bctx.positionFloat(f.box, f.space, f.parentBps.offset)
  bctx.unpositionedFloats.setLen(0)

proc layoutFlow(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes) =
  if box.canFlushMargins(sizes):
    bctx.flushMargins(box)
    bctx.positionFloats()
  if box.computed{"clear"} != ClearNone:
    box.state.offset.clearFloats(bctx, box.computed{"clear"})
  if box.inline != nil:
    # Builder only contains inline boxes.
    bctx.layoutInline(box, sizes)
  else:
    # Builder only contains block boxes.
    bctx.layoutBlock(box, sizes)

proc layoutListItem(bctx: var BlockContext; box: BlockBox;
    sizes: ResolvedSizes) =
  case box.computed{"list-style-position"}
  of ListStylePositionOutside:
    let marker = box.nested[0]
    let content = box.nested[1]
    marker.state = BlockBoxLayoutState()
    content.state = BlockBoxLayoutState(
      offset: box.state.offset,
      positioned: sizes.positioned
    )
    bctx.layoutFlow(content, sizes)
    #TODO we should put markers right before the first atom of the parent
    # list item or something...
    var bctx = BlockContext(lctx: bctx.lctx)
    let markerSizes = ResolvedSizes(
      space: availableSpace(w = fitContent(sizes.space.w), h = sizes.space.h),
      minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
    )
    bctx.layoutFlow(marker, markerSizes)
    marker.state.offset.x = -marker.state.size.w
    # take inner box min width etc.
    box.state = content.state
    content.state.offset = offset(x = 0, y = 0)
    content.state.margin = [Span(), Span()]
    content.state.positioned = [Span(), Span()]
  of ListStylePositionInside:
    bctx.layoutFlow(box, sizes)

# space: width/height of the containing block.
proc addInlineBlock(ictx: var InlineContext; state: var InlineState;
    box: BlockBox; space: AvailableSpace) =
  let lctx = ictx.lctx
  let percHeight = space.h.toPercSize()
  let space = availableSpace(w = space.w, h = maxContent())
  let sizes = lctx.resolveFloatSizes(space, percHeight, box.computed)
  box.state = BlockBoxLayoutState(
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  var bctx = BlockContext(lctx: lctx)
  bctx.marginTodo.append(sizes.margin.top)
  case box.computed{"display"}
  of DisplayInlineBlock: bctx.layoutFlow(box, sizes)
  of DisplayInlineTableWrapper: bctx.layoutTableWrapper(box, sizes)
  of DisplayInlineFlex: bctx.layoutFlex(box, sizes)
  else: assert false
  assert bctx.unpositionedFloats.len == 0
  bctx.marginTodo.append(sizes.margin.bottom)
  let marginTop = box.state.offset.y
  let marginBottom = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.state.size.h + marginBottom:
    box.state.size.h = bctx.maxFloatHeight - marginBottom
  box.state.offset.y = 0
  # Apply the block box's properties to the atom itself.
  let iblock = InlineAtom(
    t: iatInlineBlock,
    innerbox: box,
    offset: offset(x = sizes.margin.left, y = 0),
    size: size(
      w = box.state.size.w + sizes.margin.dimSum(dtHorizontal),
      h = box.state.size.h
    )
  )
  let iastate = InlineAtomState(
    baseline: box.state.baseline,
    vertalign: box.computed{"vertical-align"},
    marginTop: marginTop,
    marginBottom: bctx.marginTodo.sum()
  )
  discard ictx.addAtom(state, iastate, iblock)
  ictx.whitespacenum = 0

proc layoutChildren(ictx: var InlineContext; state: var InlineState;
    children: seq[InlineFragment]) =
  for child in children:
    case child.computed{"display"}
    of DisplayInline:
      ictx.layoutInline(child)
    of DisplayInlineBlock, DisplayInlineTableWrapper, DisplayInlineFlex:
      child.state = InlineFragmentState()
      var state = InlineState(
        computed: child.computed,
        node: child.node,
        fragment: child
      )
      let space = availableSpace(w = fitContent(ictx.space.w), h = ictx.space.h)
      ictx.addInlineBlock(state, child.box, space)
    else:
      assert false

proc layoutInline(ictx: var InlineContext; fragment: InlineFragment) =
  let lctx = ictx.lctx
  fragment.state = InlineFragmentState()
  if stSplitStart in fragment.splitType:
    let marginLeft = fragment.computed{"margin-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginLeft
  var state = InlineState(
    #TODO do I really have to copy these two?
    computed: fragment.computed,
    node: fragment.node,
    fragment: fragment,
    firstLine: true,
    startOffsetTop: offset(
      x = ictx.currentLine.widthAfterWhitespace,
      y = ictx.currentLine.offsety
    )
  )
  if fragment.newline:
    ictx.flushLine(state)
  if stSplitStart in fragment.splitType:
    let paddingLeft = fragment.computed{"padding-left"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingLeft
  assert fragment.children.len == 0 or fragment.text.len == 0
  ictx.applyLineHeight(ictx.currentLine, state.computed)
  if ictx.firstTextFragment == nil:
    ictx.firstTextFragment = fragment
  ictx.lastTextFragment = fragment
  if fragment.bmp != nil:
    let h = int(fragment.bmp.height).toLayoutUnit().ceilTo(ictx.cellHeight)
    let iastate = InlineAtomState(
      vertalign: state.computed{"vertical-align"},
      baseline: h
    )
    let atom = InlineAtom(
      t: iatImage,
      bmp: fragment.bmp,
      size: size(w = int(fragment.bmp.width), h = h), #TODO overflow
    )
    discard ictx.addAtom(state, iastate, atom)
  else:
    ictx.layoutText(state, fragment.text)
    ictx.layoutChildren(state, fragment.children)
  assert fragment.children.len == 0 or fragment.state.atoms.len == 0
  if stSplitEnd in fragment.splitType:
    let paddingRight = fragment.computed{"padding-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += paddingRight
    let marginRight = fragment.computed{"margin-right"}.px(lctx, ictx.space.w)
    ictx.currentLine.size.w += marginRight
  if state.firstLine:
    fragment.state.startOffset = offset(
      x = state.startOffsetTop.x,
      y = ictx.currentLine.offsety
    )
  else:
    fragment.state.startOffset = offset(x = 0, y = ictx.currentLine.offsety)

proc layoutRootInline(bctx: var BlockContext; root: RootInlineFragment;
    space: AvailableSpace; computed: CSSComputedValues;
    offset, bfcOffset: Offset) =
  root.state = RootInlineFragmentState(offset: offset)
  var ictx = bctx.initInlineContext(space, bfcOffset, root)
  ictx.layoutInline(root.fragment)
  if ictx.firstTextFragment != nil:
    root.fragment.state.startOffset = ictx.firstTextFragment.state.startOffset
  if ictx.lastTextFragment != nil:
    var state = InlineState(computed: computed, fragment: ictx.lastTextFragment)
    ictx.finishLine(state, wrap = false)
  ictx.horizontalAlignLines(computed{"text-align"})
  ictx.addBackgroundAreas(root.fragment)

proc positionAbsolute(lctx: LayoutContext; box: BlockBox;
    margin: RelativeRect) =
  let last = lctx.positioned[^1]
  let parentWidth = applySizeConstraint(lctx.attrs.width_px, last.w)
  let parentHeight = applySizeConstraint(lctx.attrs.height_px, last.h)
  if not box.computed{"left"}.auto:
    box.state.offset.x = box.state.positioned.left + margin.left
  elif not box.computed{"right"}.auto:
    box.state.offset.x = parentWidth - box.state.positioned.right -
      box.state.size.w - margin.right
  if not box.computed{"top"}.auto:
    box.state.offset.y = box.state.positioned.top + margin.top
  elif not box.computed{"bottom"}.auto:
    box.state.offset.y = parentHeight - box.state.positioned.bottom -
      box.state.size.h - margin.bottom

proc positionRelative(parent, box: BlockBox) =
  if not box.computed{"left"}.auto:
    box.state.offset.x += box.state.positioned.left
  elif not box.computed{"right"}.auto:
    box.state.offset.x += parent.state.size.w - box.state.positioned.right -
      box.state.size.w
  if not box.computed{"top"}.auto:
    box.state.offset.y += box.state.positioned.top
  elif not box.computed{"bottom"}.auto:
    box.state.offset.y += parent.state.size.h - box.state.positioned.bottom -
      box.state.size.h

# Note: caption is not included here
const RowGroupBox = {
  DisplayTableRowGroup, DisplayTableHeaderGroup, DisplayTableFooterGroup
}
const ProperTableChild = RowGroupBox + {
  DisplayTableRow, DisplayTableColumn, DisplayTableColumnGroup
}
const ProperTableRowParent = RowGroupBox + {
  DisplayTable, DisplayInlineTable
}

type
  CellWrapper = ref object
    box: BlockBox
    coli: int
    colspan: int
    rowspan: int
    reflow: bool
    grown: int # number of remaining rows
    real: CellWrapper # for filler wrappers
    last: bool # is this the last filler?
    height: LayoutUnit
    baseline: LayoutUnit

  RowContext = object
    cells: seq[CellWrapper]
    reflow: seq[bool]
    width: LayoutUnit
    height: LayoutUnit
    box: BlockBox
    ncols: int

  ColumnContext = object
    minwidth: LayoutUnit
    width: LayoutUnit
    wspecified: bool
    reflow: bool
    weight: float64

  TableContext = object
    lctx: LayoutContext
    rows: seq[RowContext]
    cols: seq[ColumnContext]
    growing: seq[CellWrapper]
    maxwidth: LayoutUnit
    blockSpacing: LayoutUnit
    inlineSpacing: LayoutUnit
    space: AvailableSpace # space we got from parent

proc layoutTableCell(lctx: LayoutContext; box: BlockBox;
    space: AvailableSpace) =
  var sizes = ResolvedSizes(
    padding: resolvePadding(space.w, lctx, box.computed),
    space: space,
    minMaxSizes: [dtHorizontal: DefaultSpan, dtVertical: DefaultSpan]
  )
  if sizes.space.w.isDefinite():
    sizes.space.w.u -= sizes.padding.left
    sizes.space.w.u -= sizes.padding.right
  if sizes.space.h.isDefinite():
    sizes.space.h.u -= sizes.padding.top
    sizes.space.h.u -= sizes.padding.bottom
  box.state = BlockBoxLayoutState(positioned: sizes.positioned)
  var bctx = BlockContext(lctx: lctx)
  bctx.layoutFlow(box, sizes)
  assert bctx.unpositionedFloats.len == 0
  # Table cells ignore margins.
  box.state.offset.y = 0
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  box.state.size.h = max(box.state.size.h, bctx.maxFloatHeight)

# Sort growing cells, and filter out cells that have grown to their intended
# rowspan.
proc sortGrowing(pctx: var TableContext) =
  var i = 0
  for j, cellw in pctx.growing:
    if pctx.growing[i].grown == 0:
      continue
    if j != i:
      pctx.growing[i] = cellw
    inc i
  pctx.growing.setLen(i)
  pctx.growing.sort(proc(a, b: CellWrapper): int = cmp(a.coli, b.coli))

# Grow cells with a rowspan > 1 (to occupy their place in a new row).
proc growRowspan(pctx: var TableContext; ctx: var RowContext;
    growi, i, n: var int; growlen: int) =
  while growi < growlen:
    let cellw = pctx.growing[growi]
    if cellw.coli > n:
      break
    dec cellw.grown
    let rowspanFiller = CellWrapper(
      colspan: cellw.colspan,
      rowspan: cellw.rowspan,
      coli: n,
      real: cellw,
      last: cellw.grown == 0
    )
    ctx.cells.add(nil)
    ctx.cells[i] = rowspanFiller
    for i in n ..< n + cellw.colspan:
      ctx.width += pctx.cols[i].width
      ctx.width += pctx.inlineSpacing * 2
    n += cellw.colspan
    inc i
    inc growi

proc preBuildTableRow(pctx: var TableContext; row, parent: BlockBox;
    rowi, numrows: int): RowContext =
  var ctx = RowContext(box: row, cells: newSeq[CellWrapper](row.nested.len))
  var n = 0
  var i = 0
  var growi = 0
  # this increases in the loop, but we only want to check growing cells that
  # were added by previous rows.
  let growlen = pctx.growing.len
  for box in row.nested:
    assert box.computed{"display"} == DisplayTableCell
    pctx.growRowspan(ctx, growi, i, n, growlen)
    let colspan = box.computed{"-cha-colspan"}
    let rowspan = min(box.computed{"-cha-rowspan"}, numrows - rowi)
    let cw = box.computed{"width"}
    let ch = box.computed{"height"}
    let space = availableSpace(
      w = cw.stretchOrMaxContent(pctx.lctx, pctx.space.w),
      h = ch.stretchOrMaxContent(pctx.lctx, pctx.space.h)
    )
    #TODO specified table height should be distributed among rows.
    # Allow the table cell to use its specified width.
    pctx.lctx.layoutTableCell(box, space)
    let wrapper = CellWrapper(
      box: box,
      colspan: colspan,
      rowspan: rowspan,
      coli: n
    )
    ctx.cells[i] = wrapper
    if rowspan > 1:
      pctx.growing.add(wrapper)
      wrapper.grown = rowspan - 1
    if pctx.cols.len < n + colspan:
      pctx.cols.setLen(n + colspan)
    if ctx.reflow.len < n + colspan:
      ctx.reflow.setLen(n + colspan)
    let minw = box.state.xminwidth div colspan
    let w = box.state.size.w div colspan
    for i in n ..< n + colspan:
      # Add spacing.
      ctx.width += pctx.inlineSpacing
      # Figure out this cell's effect on the column's width.
      # Four cases exits:
      # 1. colwidth already fixed, cell width is fixed: take maximum
      # 2. colwidth already fixed, cell width is auto: take colwidth
      # 3. colwidth is not fixed, cell width is fixed: take cell width
      # 4. neither of colwidth or cell width are fixed: take maximum
      if ctx.reflow.len <= i: ctx.reflow.setLen(i + 1)
      if pctx.cols[i].wspecified:
        if space.w.isDefinite():
          # A specified column already exists; we take the larger width.
          if w > pctx.cols[i].width:
            pctx.cols[i].width = w
            ctx.reflow[i] = true
        if pctx.cols[i].width != w:
          wrapper.reflow = true
      else:
        if space.w.isDefinite():
          # This is the first specified column. Replace colwidth with whatever
          # we have.
          ctx.reflow[i] = true
          pctx.cols[i].wspecified = true
          pctx.cols[i].width = w
        else:
          if w > pctx.cols[i].width:
            pctx.cols[i].width = w
            ctx.reflow[i] = true
          else:
            wrapper.reflow = true
      if pctx.cols[i].minwidth < minw:
        pctx.cols[i].minwidth = minw
        if pctx.cols[i].width < minw:
          pctx.cols[i].width = minw
          ctx.reflow[i] = true
      ctx.width += pctx.cols[i].width
      # Add spacing to the right side.
      ctx.width += pctx.inlineSpacing
    n += colspan
    inc i
  pctx.growRowspan(ctx, growi, i, n, growlen)
  pctx.sortGrowing()
  when defined(debug):
    for cell in ctx.cells:
      assert cell != nil
  ctx.ncols = n
  return ctx

proc alignTableCell(cell: BlockBox; availableHeight, baseline: LayoutUnit) =
  case cell.computed{"vertical-align"}.keyword
  of VerticalAlignTop:
    cell.state.offset.y = 0
  of VerticalAlignMiddle:
    cell.state.offset.y = availableHeight div 2 - cell.state.size.h div 2
  of VerticalAlignBottom:
    cell.state.offset.y = availableHeight - cell.state.size.h
  else:
    cell.state.offset.y = baseline - cell.state.firstBaseline

proc layoutTableRow(tctx: TableContext; ctx: RowContext;
    parent, row: BlockBox) =
  row.state = BlockBoxLayoutState()
  var x: LayoutUnit = 0
  var n = 0
  var baseline: LayoutUnit = 0
  # real cellwrappers of fillers
  var toAlign: seq[CellWrapper] = @[]
  # cells with rowspan > 1 that must store baseline
  var toBaseline: seq[CellWrapper] = @[]
  # cells that we must update row height of
  var toHeight: seq[CellWrapper] = @[]
  for cellw in ctx.cells:
    var w: LayoutUnit = 0
    for i in n ..< n + cellw.colspan:
      w += tctx.cols[i].width
    # Add inline spacing for merged columns.
    w += tctx.inlineSpacing * (cellw.colspan - 1) * 2
    if cellw.reflow and cellw.box != nil:
      # Do not allow the table cell to make use of its specified width.
      # e.g. in the following table
      # <TABLE>
      # <TR>
      # <TD style="width: 5ch" bgcolor=blue>5ch</TD>
      # </TR>
      # <TR>
      # <TD style="width: 9ch" bgcolor=red>9ch</TD>
      # </TR>
      # </TABLE>
      # the TD with a width of 5ch should be 9ch wide as well.
      let space = availableSpace(w = stretch(w), h = maxContent())
      tctx.lctx.layoutTableCell(cellw.box, space)
      w = max(w, cellw.box.state.size.w)
    let cell = cellw.box
    x += tctx.inlineSpacing
    if cell != nil:
      cell.state.offset.x += x
    x += tctx.inlineSpacing
    x += w
    n += cellw.colspan
    const HasNoBaseline = {
      VerticalAlignTop, VerticalAlignMiddle, VerticalAlignBottom
    }
    if cell != nil:
      if cell.computed{"vertical-align"}.keyword notin HasNoBaseline: # baseline
        baseline = max(cell.state.firstBaseline, baseline)
        if cellw.rowspan > 1:
          toBaseline.add(cellw)
      if cellw.rowspan > 1:
        toHeight.add(cellw)
      row.state.size.h = max(row.state.size.h,
        cell.state.size.h div cellw.rowspan)
    else:
      row.state.size.h = max(row.state.size.h,
        cellw.real.box.state.size.h div cellw.rowspan)
      toHeight.add(cellw.real)
      if cellw.last:
        toAlign.add(cellw.real)
  for cellw in toHeight:
    cellw.height += row.state.size.h
  for cellw in toBaseline:
    cellw.baseline = baseline
  for cellw in toAlign:
    alignTableCell(cellw.box, cellw.height, cellw.baseline)
  for cell in row.nested:
    alignTableCell(cell, row.state.size.h, baseline)
  row.state.size.w = x

proc preLayoutTableRows(tctx: var TableContext; rows: seq[BlockBox];
    table: BlockBox) =
  for i, row in rows:
    let rctx = tctx.preBuildTableRow(row, table, i, rows.len)
    tctx.rows.add(rctx)
    tctx.maxwidth = max(rctx.width, tctx.maxwidth)

proc preLayoutTableRows(tctx: var TableContext; table: BlockBox) =
  # Use separate seqs for different row groups, so that e.g. this HTML:
  # echo '<TABLE><TBODY><TR><TD>world<THEAD><TR><TD>hello'|cha -T text/html
  # is rendered as:
  # hello
  # world
  var thead: seq[BlockBox] = @[]
  var tbody: seq[BlockBox] = @[]
  var tfoot: seq[BlockBox] = @[]
  for child in table.nested:
    assert child.computed{"display"} in ProperTableChild
    case child.computed{"display"}
    of DisplayTableRow: tbody.add(child)
    of DisplayTableHeaderGroup: thead.add(child.nested)
    of DisplayTableRowGroup: tbody.add(child.nested)
    of DisplayTableFooterGroup: tfoot.add(child.nested)
    else: assert false
  tctx.preLayoutTableRows(thead, table)
  tctx.preLayoutTableRows(tbody, table)
  tctx.preLayoutTableRows(tfoot, table)

func calcSpecifiedRatio(tctx: TableContext; W: LayoutUnit): LayoutUnit =
  var totalSpecified: LayoutUnit = 0
  var hasUnspecified = false
  for col in tctx.cols:
    if col.wspecified:
      totalSpecified += col.width
    else:
      hasUnspecified = true
      totalSpecified += col.minwidth
  # Only grow specified columns if no unspecified column exists to take the
  # rest of the space.
  if totalSpecified == 0 or W > totalSpecified and hasUnspecified:
    return 1
  return W / totalSpecified

proc calcUnspecifiedColIndices(tctx: var TableContext; W: var LayoutUnit;
    weight: var float64): seq[int] =
  let specifiedRatio = tctx.calcSpecifiedRatio(W)
  # Spacing for each column:
  var avail = newSeqUninitialized[int](tctx.cols.len)
  var j = 0
  for i, col in tctx.cols.mpairs:
    if not col.wspecified:
      avail[j] = i
      let w = if col.width < W:
        toFloat64(col.width)
      else:
        toFloat64(W) * (ln(toFloat64(col.width) / toFloat64(W)) + 1)
      col.weight = w
      weight += w
      inc j
    else:
      if specifiedRatio != 1:
        col.width *= specifiedRatio
        col.reflow = true
      W -= col.width
      avail.del(j)
  return avail

func needsRedistribution(tctx: TableContext; computed: CSSComputedValues):
    bool =
  case tctx.space.w.t
  of scMinContent, scMaxContent:
    return false
  of scStretch:
    return tctx.space.w.u != tctx.maxwidth
  of scFitContent:
    let u = tctx.space.w.u
    return u > tctx.maxwidth and not computed{"width"}.auto or u < tctx.maxwidth

proc redistributeWidth(tctx: var TableContext) =
  # Remove inline spacing from distributable width.
  var W = tctx.space.w.u - tctx.cols.len * tctx.inlineSpacing * 2
  var weight = 0f64
  var avail = tctx.calcUnspecifiedColIndices(W, weight)
  var redo = true
  while redo and avail.len > 0 and weight != 0:
    if weight == 0: break # zero weight; nothing to distribute
    if W < 0:
      W = 0
    redo = false
    # divide delta width by sum of ln(width) for all elem in avail
    let unit = toFloat64(W) / weight
    weight = 0
    for i in countdown(avail.high, 0):
      let j = avail[i]
      let x = (unit * tctx.cols[j].weight).toLayoutUnit()
      let mw = tctx.cols[j].minwidth
      tctx.cols[j].width = x
      if mw > x:
        W -= mw
        tctx.cols[j].width = mw
        avail.del(i)
        redo = true
      else:
        weight += tctx.cols[j].weight
      tctx.cols[j].reflow = true

proc reflowTableCells(tctx: var TableContext) =
  for i in countdown(tctx.rows.high, 0):
    var row = addr tctx.rows[i]
    var n = tctx.cols.len - 1
    for j in countdown(row.cells.high, 0):
      let m = n - row.cells[j].colspan
      while n > m:
        if tctx.cols[n].reflow:
          row.cells[j].reflow = true
        if n < row.reflow.len and row.reflow[n]:
          tctx.cols[n].reflow = true
        dec n

proc layoutTableRows(tctx: TableContext; table: BlockBox;
    sizes: ResolvedSizes) =
  var y: LayoutUnit = 0
  for roww in tctx.rows:
    if roww.box.computed{"visibility"} == VisibilityCollapse:
      continue
    y += tctx.blockSpacing
    let row = roww.box
    tctx.layoutTableRow(roww, table, row)
    row.state.offset.y += y
    row.state.offset.x += sizes.padding.left
    row.state.size.w += sizes.padding.dimSum(dtHorizontal)
    y += tctx.blockSpacing
    y += row.state.size.h
    table.state.size.w = max(row.state.size.w, table.state.size.w)
  table.state.size.h = applySizeConstraint(y, sizes.space.h)

proc layoutCaption(tctx: TableContext; parent, box: BlockBox) =
  let percHeight = tctx.space.h.toPercSize()
  let space = availableSpace(w = stretch(parent.state.size.w), h = maxContent())
  let sizes = tctx.lctx.resolveSizes(space, percHeight, box.computed)
  box.state = BlockBoxLayoutState(
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  var bctx = BlockContext(lctx: tctx.lctx)
  bctx.layoutFlow(box, sizes)
  assert bctx.unpositionedFloats.len == 0
  let outerHeight = box.state.offset.y + box.state.size.h +
    bctx.marginTodo.sum()
  parent.state.size.h += outerHeight
  parent.state.size.w = max(parent.state.size.w, box.state.size.w)
  case box.computed{"caption-side"}
  of CaptionSideTop, CaptionSideBlockStart:
    let table = parent.nested[0]
    table.state.offset.y += outerHeight
  of CaptionSideBottom, CaptionSideBlockEnd:
    box.state.offset.y += outerHeight

# Table layout. We try to emulate w3m's behavior here:
# 1. Calculate minimum and preferred width of each column
# 2. If column width is not auto, set width to max(min_col_width, specified)
# 3. Calculate the maximum preferred row width. If this is
# a) less than the specified table width, or
# b) greater than the table's content width:
#      Distribute the table's content width among cells with an unspecified
#      width. If this would give any cell a width < min_width, set that
#      cell's width to min_width, then re-do the distribution.
proc layoutTable(tctx: var TableContext; table: BlockBox;
    sizes: ResolvedSizes) =
  let lctx = tctx.lctx
  if table.computed{"border-collapse"} != BorderCollapseCollapse:
    tctx.inlineSpacing = table.computed{"border-spacing"}.a.px(lctx)
    tctx.blockSpacing = table.computed{"border-spacing"}.b.px(lctx)
  tctx.preLayoutTableRows(table) # first pass
  if tctx.needsRedistribution(table.computed):
    tctx.redistributeWidth()
  for col in tctx.cols:
    table.state.size.w += col.width
  tctx.reflowTableCells()
  tctx.layoutTableRows(table, sizes) # second pass

# As per standard, we must put the caption outside the actual table, inside a
# block-level wrapper box.
proc layoutTableWrapper(bctx: BlockContext; box: BlockBox;
    sizes: ResolvedSizes) =
  let table = box.nested[0]
  table.state = BlockBoxLayoutState()
  var tctx = TableContext(lctx: bctx.lctx, space: sizes.space)
  tctx.layoutTable(table, sizes)
  box.state.size = table.state.size
  if box.nested.len > 1:
    # do it here, so that caption's box can stretch to our width
    let caption = box.nested[1]
    #TODO also count caption width in table width
    tctx.layoutCaption(box, caption)

proc postAlignChild(box, child: BlockBox; width: LayoutUnit) =
  case box.computed{"text-align"}
  of TextAlignChaCenter:
    child.state.offset.x += max(width div 2 - child.state.size.w div 2, 0)
  of TextAlignChaRight:
    child.state.offset.x += max(width - child.state.size.w -
      child.state.margin.right, 0)
  else: # TextAlignChaLeft or not block-aligned
    discard

proc layout(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes) =
  case box.computed{"display"}
  of DisplayBlock, DisplayFlowRoot, DisplayTableCaption:
    bctx.layoutFlow(box, sizes)
  of DisplayListItem:
    bctx.layoutListItem(box, sizes)
  of DisplayTableWrapper:
    bctx.layoutTableWrapper(box, sizes)
  of DisplayFlex:
    bctx.layoutFlex(box, sizes)
  else:
    assert false

proc layoutFlexChild(lctx: LayoutContext; box: BlockBox; sizes: ResolvedSizes) =
  var bctx = BlockContext(lctx: lctx)
  # note: we do not append margins here, since those belong to the flex item,
  # not its inner BFC.
  box.state = BlockBoxLayoutState(
    offset: offset(x = sizes.margin.left, y = 0),
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  bctx.layout(box, sizes)
  assert bctx.unpositionedFloats.len == 0
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.state.offset.y + box.state.size.h:
    box.state.size.h = bctx.maxFloatHeight - box.state.offset.y

type
  FlexWeightType = enum
    fwtGrow, fwtShrink

  FlexPendingItem = object
    child: BlockBox
    weights: array[FlexWeightType, float64]
    sizes: ResolvedSizes

  FlexMainContext = object
    offset: Offset
    totalSize: Size
    maxSize: Size
    maxMargin: RelativeRect
    totalWeight: array[FlexWeightType, float64]
    lctx: LayoutContext
    pending: seq[FlexPendingItem]

const FlexRow = {FlexDirectionRow, FlexDirectionRowReverse}

func outerSize(box: BlockBox; dim: DimensionType): LayoutUnit =
  return box.state.margin.dimSum(dim) + box.state.size[dim]

proc updateMaxSizes(mctx: var FlexMainContext; child: BlockBox) =
  for dim in DimensionType:
    mctx.maxSize[dim] = max(mctx.maxSize[dim], child.state.size[dim])
    mctx.maxMargin[dim].start = max(mctx.maxMargin[dim].start,
      child.state.margin[dim].start)
    mctx.maxMargin[dim].send = max(mctx.maxMargin[dim].send,
      child.state.margin[dim].send)

proc redistributeMainSize(mctx: var FlexMainContext; sizes: ResolvedSizes;
    dim: DimensionType) =
  let lctx = mctx.lctx
  let odim = dim.opposite
  if sizes.space[dim].isDefinite:
    var diff = sizes.space[dim].u - mctx.totalSize[dim]
    let wt = if diff > 0: fwtGrow else: fwtShrink
    var totalWeight = mctx.totalWeight[wt]
    while (wt == fwtGrow and diff > 0 or wt == fwtShrink and diff < 0) and
        totalWeight > 0:
      # redo maxSize calculation; we only need height here
      mctx.maxSize[odim] = 0
      let unit = diff.toFloat64() / totalWeight
      # reset total weight & available diff for the next iteration (if there is
      # one)
      totalWeight = 0
      diff = 0
      for it in mctx.pending.mitems:
        if it.weights[wt] == 0:
          mctx.updateMaxSizes(it.child)
          continue
        var u = it.child.state.size[dim] +
          (unit * it.weights[wt]).toLayoutUnit()
        # check for min/max violation
        var minu = it.sizes.minMaxSizes[dim].start
        if dim == dtHorizontal:
          minu = max(it.child.state.xminwidth, minu)
        if minu > u:
          # min violation
          if wt == fwtShrink: # freeze
            diff += u - minu
            it.weights[wt] = 0
          u = minu
        let maxu = it.sizes.minMaxSizes[dim].send
        if maxu < u:
          # max violation
          if wt == fwtGrow: # freeze
            diff += u - maxu
            it.weights[wt] = 0
          u = maxu
        it.sizes.space[dim] = stretch(u - it.sizes.padding.dimSum(dim))
        totalWeight += it.weights[wt]
        #TODO we should call this only on freeze, and then put another loop to
        # the end for non-freezed items
        lctx.layoutFlexChild(it.child, it.sizes)
        mctx.updateMaxSizes(it.child)

proc flushMain(mctx: var FlexMainContext; box: BlockBox; sizes: ResolvedSizes;
    totalMaxSize: var Size; dim: DimensionType) =
  let odim = dim.opposite
  let lctx = mctx.lctx
  mctx.redistributeMainSize(sizes, dim)
  let h = mctx.maxSize[odim] + mctx.maxMargin.dimSum(odim)
  var offset = mctx.offset
  for it in mctx.pending.mitems:
    if it.child.state.size[odim] < h and not it.sizes.space[odim].isDefinite:
      # if the max height is greater than our height, then take max height
      # instead. (if the box's available height is definite, then this will
      # change nothing, so we skip it as an optimization.)
      it.sizes.space[odim] = stretch(h - it.sizes.margin.dimSum(odim))
      lctx.layoutFlexChild(it.child, it.sizes)
    it.child.state.offset[dim] += offset[dim]
    # margins are added here, since they belong to the flex item.
    it.child.state.offset[odim] += offset[odim] +
      it.child.state.margin[odim].start
    offset[dim] += it.child.state.size[dim]
  totalMaxSize[dim] = max(totalMaxSize[dim], offset[dim])
  mctx = FlexMainContext(
    lctx: mctx.lctx,
    offset: mctx.offset
  )
  mctx.offset[odim] = mctx.offset[odim] + h

proc layoutFlex(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes) =
  assert box.inline == nil
  let lctx = bctx.lctx
  var i = 0
  var mctx = FlexMainContext(lctx: lctx)
  let flexDir = box.computed{"flex-direction"}
  var totalMaxSize = size(w = 0, h = 0)
  let canWrap = box.computed{"flex-wrap"} != FlexWrapNowrap
  let percHeight = sizes.space.h.toPercSize()
  let dim = if flexDir in FlexRow: dtHorizontal else: dtVertical
  while i < box.nested.len:
    let child = box.nested[i]
    var childSizes = lctx.resolveFloatSizes(sizes.space, percHeight,
      child.computed)
    let flexBasis = child.computed{"flex-basis"}
    if not flexBasis.auto:
      if flexDir in FlexRow:
        childSizes.space.w = stretch(flexBasis.px(lctx, sizes.space.w))
      else:
        childSizes.space.h = stretch(flexBasis.px(lctx, sizes.space.h))
    lctx.layoutFlexChild(child, childSizes)
    if not flexBasis.auto and childSizes.space.w.isDefinite and
        child.state.xminwidth > childSizes.space.w.u:
      # first pass gave us a box that is smaller than the minimum acceptable
      # width whatever reason; this may have happened because the initial flex
      # basis was e.g. 0.  Try to resize it to something more usable.
      # Note: this is a hack; we need it because we cheat with size resolution
      # by using the algorithm that was in fact designed for floats, and without
      # this hack layouts with a flex-base of 0 break down horribly.
      # (And we need flex-base because using auto wherever the two-value `flex'
      # shorthand is used breaks down even more horribly.)
      #TODO implement the standard size resolution properly
      childSizes.space.w = stretch(child.state.xminwidth)
      lctx.layoutFlexChild(child, childSizes)
    if canWrap and (sizes.space[dim].t == scMinContent or
        sizes.space[dim].isDefinite and
        mctx.totalSize[dim] + child.state.size[dim] > sizes.space[dim].u):
      mctx.flushMain(box, sizes, totalMaxSize, dim)
    mctx.totalSize[dim] += child.outerSize(dim)
    mctx.updateMaxSizes(child)
    let grow = child.computed{"flex-grow"}
    let shrink = child.computed{"flex-shrink"}
    mctx.totalWeight[fwtGrow] += grow
    mctx.totalWeight[fwtShrink] += shrink
    mctx.pending.add(FlexPendingItem(
      child: child,
      weights: [grow, shrink],
      sizes: childSizes
    ))
    inc i # need to increment index here for needsGrow
  if mctx.pending.len > 0:
    mctx.flushMain(box, sizes, totalMaxSize, dim)
  box.applySize(sizes, totalMaxSize[dim], sizes.space, dim)
  box.applySize(sizes, mctx.offset[dim.opposite], sizes.space, dim.opposite)

# Build an outer block box inside an existing block formatting context.
proc layoutBlockChild(bctx: var BlockContext; box: BlockBox;
    space: AvailableSpace; offset: Offset; appendMargins: bool) =
  let percHeight = space.h.toPercSize()
  var space = availableSpace(
    w = space.w,
    h = maxContent() #TODO fit-content when clip
  )
  if box.computed{"display"} == DisplayTableWrapper:
    space.w = fitContent(space.w)
  let sizes = bctx.lctx.resolveSizes(space, percHeight, box.computed)
  if appendMargins:
    # for nested blocks that do not establish their own BFC, and thus take part
    # in margin collapsing.
    bctx.marginTodo.append(sizes.margin.top)
  box.state = BlockBoxLayoutState(
    offset: offset(x = offset.x + sizes.margin.left, y = offset.y),
    margin: sizes.margin,
    positioned: sizes.positioned
  )
  bctx.layout(box, sizes)
  if appendMargins:
    bctx.marginTodo.append(sizes.margin.bottom)

# Inner layout for boxes that establish a new block formatting context.
proc layoutRootBlock(lctx: LayoutContext; box: BlockBox;
    space: AvailableSpace; offset: Offset; marginBottomOut: var LayoutUnit) =
  var bctx = BlockContext(lctx: lctx)
  bctx.layoutBlockChild(box, space, offset, appendMargins = false)
  assert bctx.unpositionedFloats.len == 0
  marginBottomOut = bctx.marginTodo.sum()
  # If the highest float edge is higher than the box itself, set that as
  # the box height.
  if bctx.maxFloatHeight > box.state.size.h + marginBottomOut:
    box.state.size.h = bctx.maxFloatHeight - marginBottomOut

proc initBlockPositionStates(state: var BlockState; bctx: var BlockContext;
    box: BlockBox) =
  let prevBps = bctx.ancestorsHead
  bctx.ancestorsHead = BlockPositionState(
    box: box,
    offset: state.offset,
    resolved: bctx.parentBps == nil
  )
  if prevBps != nil:
    prevBps.next = bctx.ancestorsHead
  if bctx.parentBps != nil:
    bctx.ancestorsHead.offset += bctx.parentBps.offset
    # If parentBps is not nil, then our starting position is not in a new
    # BFC -> we must add it to our BFC offset.
    bctx.ancestorsHead.offset += box.state.offset
  if bctx.marginTarget == nil:
    bctx.marginTarget = bctx.ancestorsHead
  state.initialMarginTarget = bctx.marginTarget
  state.initialTargetOffset = bctx.marginTarget.offset
  if bctx.parentBps == nil:
    # We have just established a new BFC. Resolve the margins instantly.
    bctx.marginTarget = nil
  state.prevParentBps = bctx.parentBps
  bctx.parentBps = bctx.ancestorsHead
  state.initialParentOffset = bctx.parentBps.offset

func isParentResolved(state: BlockState; bctx: BlockContext): bool =
  return bctx.marginTarget != state.initialMarginTarget or
    state.prevParentBps != nil and state.prevParentBps.resolved

# Note: this does not include display types that cannot appear as block
# children.
func establishesBFC(computed: CSSComputedValues): bool =
  return computed{"float"} != FloatNone or
    computed{"position"} == PositionAbsolute or
    computed{"display"} in {DisplayFlowRoot, DisplayTable, DisplayTableWrapper,
      DisplayFlex} or
    computed{"overflow"} notin {OverflowVisible, OverflowClip}
    #TODO contain, grid, multicol, column-span

# Outer layout for block-level children that establish a BFC.
# Returns the vertical size used (incl. margins).
proc layoutBlockChildBFC(state: var BlockState; bctx: var BlockContext;
    child: BlockBox): LayoutUnit =
  var marginBottomOut: LayoutUnit
  bctx.lctx.layoutRootBlock(child, state.space, state.offset,
    marginBottomOut)
  # Do not collapse margins of elements that do not participate in
  # the flow.
  if child.computed{"position"} != PositionAbsolute and
      child.computed{"float"} == FloatNone:
    bctx.marginTodo.append(child.state.margin.top)
    bctx.flushMargins(child)
    bctx.positionFloats()
    bctx.marginTodo.append(child.state.margin.bottom)
    if child.computed{"clear"} != ClearNone:
      state.offset.clearFloats(bctx, child.computed{"clear"})
    if bctx.exclusions.len > 0:
      # Consulting the standard for an important edge case... (abridged)
      #
      # > The border box of an element that establishes a new BFC must not
      # > overlap the margin box of any floats in the same BFC as the
      # > element itself. If necessary, implementations should clear the
      # > said element, but may place it adjacent to such floats if there
      # > is sufficient space. CSS2 does not define when a UA may put said
      # > element next to the float.
      #
      # ...as expected. Thanks for nothing.
      #
      # OK here's what we do:
      # * run a normal pass
      # * place the longest word (i.e. xminwidth) somewhere
      # * run another pass with the placement we got
      #
      # I suspect this breaks horribly on some layouts, but I don't care
      # enough to make this convoluted garbage even more complex.
      #
      # Note that we do this only for elements in the flow. FF yanks
      # absolutely positioned elements on top of floats, and so do we.
      let pbfcOffset = bctx.bfcOffset
      let bfcOffset = offset(
        x = pbfcOffset.x + child.state.offset.x,
        y = max(pbfcOffset.y + child.state.offset.y, bctx.clearOffset)
      )
      let minSize = size(w = child.state.xminwidth, h = bctx.lctx.attrs.ppl)
      var outw: LayoutUnit
      let offset = bctx.findNextBlockOffset(bfcOffset, minSize,
        state.space, outw)
      let space = availableSpace(w = stretch(outw), h = state.space.h)
      bctx.lctx.layoutRootBlock(child, space, offset - pbfcOffset,
        marginBottomOut)
  else:
    child.state.offset.y += child.state.margin.top
    if state.isParentResolved(bctx):
      # If parent offset has been resolved, use marginTodo in this
      # float's initial offset.
      child.state.offset.y += bctx.marginTodo.sum()
  # delta y is difference between old and new offsets (margin-top), sum
  # of margin todo in bctx2 (margin-bottom) + height.
  return child.state.offset.y - state.offset.y + child.state.size.h +
    marginBottomOut

# Layout and place all children in the block box.
# Box placement must occur during this pass, since child box layout in the
# same block formatting context depends on knowing where the box offset is
# (because of floats).
proc layoutBlockChildren(state: var BlockState; bctx: var BlockContext;
    parent: BlockBox) =
  for child in parent.nested:
    var dy: LayoutUnit = 0 # delta
    if child.computed.establishesBFC():
      dy = state.layoutBlockChildBFC(bctx, child)
    else:
      bctx.layoutBlockChild(child, state.space, state.offset,
        appendMargins = true)
      # delta y is difference between old and new offsets (margin-top),
      # plus height.
      dy = child.state.offset.y - state.offset.y + child.state.size.h
    let childWidth = child.outerSize(dtHorizontal)
    state.xminwidth = max(state.xminwidth, child.state.xminwidth)
    let isfloat = child.computed{"float"} != FloatNone
    if child.computed{"position"} != PositionAbsolute and not isfloat:
      # Not absolute, and not a float.
      state.maxChildWidth = max(state.maxChildWidth, childWidth)
      state.offset.y += dy
    elif isfloat:
      if state.space.w.t == scFitContent:
        # Float position depends on the available width, but in this case
        # the parent width is not known.
        #
        # Set the "re-layout" flag, and skip this box.
        # (If child boxes with fit-content have floats, those will be
        # re-layouted too first, so we do not have to consider those here.)
        state.needsReLayout = true
        # Since we emulate max-content here, the float will not contribute to
        # maxChildWidth in this iteration; instead, its outer width will be
        # summed up in totalFloatWidth and added to maxChildWidth in
        # initReLayout.
        state.totalFloatWidth += childWidth
        continue
      state.maxChildWidth = max(state.maxChildWidth, childWidth)
      # Two cases exist:
      # a) The float cannot be positioned, because `box' has not resolved
      #    its y offset yet. (e.g. if float comes before the first child,
      #    we do not know yet if said child will move our y offset with a
      #    margin-top value larger than ours.)
      #    In this case we put it in unpositionedFloats, and defer positioning
      #    until our y offset is resolved.
      # b) `box' has resolved its y offset, so the float can already
      #    be positioned.
      # We check whether our y offset has been positioned as follows:
      # * save marginTarget in BlockState at layoutBlock's start
      # * if our saved marginTarget and bctx's marginTarget no longer point
      #   to the same object, that means our (or an ancestor's) offset has
      #   been resolved, i.e. we can position floats already.
      if bctx.marginTarget != state.initialMarginTarget:
        # y offset resolved
        bctx.positionFloat(child, state.space, bctx.parentBps.offset)
      else:
        bctx.unpositionedFloats.add(UnpositionedFloat(
          space: state.space,
          parentBps: bctx.parentBps,
          box: child
        ))

# Unlucky path, where we have floating blocks and a fit-content width.
# Reset marginTodo & the starting offset, and stretch the box to the
# max child width.
proc initReLayout(state: var BlockState; bctx: var BlockContext;
    box: BlockBox; sizes: ResolvedSizes) =
  bctx.marginTodo = state.oldMarginTodo
  # Note: we do not reset our own BlockPositionState's offset; we assume it
  # has already been resolved in the previous pass.
  # (If not, it won't be resolved in this pass either, so the following code
  # does not really change anything.)
  bctx.parentBps.next = nil
  if state.initialMarginTarget != bctx.marginTarget:
    # Reset the initial margin target to its previous state, and then set
    # it as the marginTarget again.
    # Two solutions exist:
    # a) Store the initial margin target offset, then restore it here. Seems
    #    clean, but it would require a linked list traversal to update all
    #    child margin positions.
    # b) Re-use the previous margin target offsets; they are guaranteed
    #    to remain the same, because out-of-flow elements (like floats) do not
    #    participate in margin resolution. We do this by setting the margin
    #    target to a dummy object, which is a small price to pay compared
    #    to solution a).
    bctx.marginTarget = BlockPositionState(
      # Use initialTargetOffset to emulate the BFC positioning of the
      # previous pass.
      offset: state.initialTargetOffset
    )
    # Set ancestorsHead to a dummy object. Rationale: see below.
    # Also set ancestorsHead as the dummy object, so next elements are
    # chained to that.
    bctx.ancestorsHead = bctx.marginTarget
  bctx.exclusions.setLen(state.oldExclusionsLen)
  state.offset = offset(x = sizes.padding.left, y = sizes.padding.top)
  box.applyWidth(sizes, state.maxChildWidth + state.totalFloatWidth)
  state.space.w = stretch(box.state.size.w)

# Re-position the children.
# The x offset with a fit-content width depends on the parent box's width,
# so we cannot do this in the first pass.
proc repositionChildren(state: BlockState; box: BlockBox; lctx: LayoutContext) =
  for child in box.nested:
    if child.computed{"position"} != PositionAbsolute:
      box.postAlignChild(child, box.state.size.w)
    case child.computed{"position"}
    of PositionRelative:
      box.positionRelative(child)
    of PositionAbsolute:
      lctx.positionAbsolute(child, child.state.margin)
    else: discard #TODO

proc layoutBlock(bctx: var BlockContext; box: BlockBox; sizes: ResolvedSizes) =
  let lctx = bctx.lctx
  let positioned = box.computed{"position"} notin {
    PositionStatic, PositionFixed, PositionSticky
  }
  if positioned:
    lctx.positioned.add(sizes.space)
  var state = BlockState(
    offset: offset(x = sizes.padding.left, y = sizes.padding.top),
    space: sizes.space,
    oldMarginTodo: bctx.marginTodo,
    oldExclusionsLen: bctx.exclusions.len
  )
  state.initBlockPositionStates(bctx, box)
  state.layoutBlockChildren(bctx, box)
  if state.needsReLayout:
    state.initReLayout(bctx, box, sizes)
    state.layoutBlockChildren(bctx, box)
  if box.nested.len > 0:
    let lastNested = box.nested[^1]
    box.state.baseline = lastNested.state.offset.y + lastNested.state.baseline
  # Apply width then move the inline offset of children that still need
  # further relative positioning.
  box.applyWidth(sizes, state.maxChildWidth, state.space)
  state.repositionChildren(box, lctx)
  # Set the inner height to the last y offset minus the starting offset
  # (that is, top padding).
  let innerHeight = state.offset.y - sizes.padding.top
  box.applyHeight(sizes, innerHeight)
  # Add padding; we cannot do this further up without influencing positioning.
  box.applyPadding(sizes.padding)
  # Pass down relevant data from state.
  box.state.xminwidth = state.xminwidth
  if state.isParentResolved(bctx):
    # Our offset has already been resolved, ergo any margins in marginTodo will
    # be passed onto the next box. Set marginTarget to nil, so that if we
    # (or one of our ancestors) was still set as a marginTarget, it no
    # longer is.
    bctx.positionFloats()
    bctx.marginTarget = nil
  # Reset parentBps to the previous node.
  bctx.parentBps = state.prevParentBps
  if positioned:
    lctx.positioned.setLen(lctx.positioned.len - 1)

# Tree generation (1st pass)

proc newMarkerBox(computed: CSSComputedValues; listItemCounter: int):
    InlineFragment =
  let computed = computed.inheritProperties()
  computed{"display"} = DisplayInline
  # Use pre, so the space at the end of the default markers isn't ignored.
  computed{"white-space"} = WhitespacePre
  return InlineFragment(
    computed: computed,
    text: @[computed{"list-style-type"}.listMarker(listItemCounter)]
  )

type BlockGroup = object
  parent: BlockBox
  # if inline is not nil, then inline.children.len > 0
  inline: RootInlineFragment
  lctx: LayoutContext

type InnerBlockContext = object
  styledNode: StyledNode
  blockgroup: BlockGroup
  lctx: LayoutContext
  ibox: InlineFragment
  iroot: InlineFragment
  anonRow: BlockBox
  anonTableWrapper: BlockBox
  quoteLevel: int
  listItemCounter: int
  listItemReset: bool
  parent: ptr InnerBlockContext
  inlineStack: seq[StyledNode]

proc add(blockgroup: var BlockGroup; box: InlineFragment) =
  assert box.computed{"display"} == DisplayInline
  if blockgroup.inline == nil:
    blockgroup.inline = RootInlineFragment(
      fragment: InlineFragment(computed: blockgroup.lctx.myRootProperties)
    )
  blockgroup.inline.fragment.children.add(box)

proc flush(blockgroup: var BlockGroup) =
  if blockgroup.inline != nil:
    assert blockgroup.parent.computed{"display"} != DisplayInline
    let computed = blockgroup.parent.computed.inheritProperties()
    computed{"display"} = DisplayBlock
    let box = BlockBox(
      computed: computed,
      inline: blockgroup.inline
    )
    blockgroup.parent.nested.add(box)
    blockgroup.inline = nil

# Don't build empty anonymous inline blocks between block boxes
func canBuildAnonymousInline(blockgroup: BlockGroup;
    computed: CSSComputedValues; str: string): bool =
  return blockgroup.inline != nil and
      blockgroup.inline.fragment.children.len > 0 or
    computed.whitespacepre or not str.onlyWhitespace()

proc buildTable(parent: var InnerBlockContext; styledNode: StyledNode): BlockBox
proc buildTableRowGroup(parent: var InnerBlockContext; styledNode: StyledNode):
  BlockBox
proc buildTableRow(parent: var InnerBlockContext; styledNode: StyledNode):
  BlockBox
proc buildTableCell(parent: var InnerBlockContext; styledNode: StyledNode):
  BlockBox
proc buildTableCaption(parent: var InnerBlockContext; styledNode: StyledNode):
  BlockBox
proc buildBlock(styledNode: StyledNode; lctx: LayoutContext;
  marker: InlineFragment = nil; parent: ptr InnerBlockContext = nil):
  BlockBox
proc buildFlex(styledNode: StyledNode; lctx: LayoutContext;
  parent: ptr InnerBlockContext = nil): BlockBox
proc buildInlineBoxes(ctx: var InnerBlockContext; styledNode: StyledNode)

proc buildBlock(pctx: var InnerBlockContext; styledNode: StyledNode;
    marker: InlineFragment = nil): BlockBox =
  return buildBlock(styledNode, pctx.lctx, marker, addr pctx)

proc buildFlex(pctx: var InnerBlockContext; styledNode: StyledNode): BlockBox =
  return buildFlex(styledNode, pctx.lctx, addr pctx)

func toTableWrapper(display: CSSDisplay): CSSDisplay =
  if display == DisplayTable:
    return DisplayTableWrapper
  assert display == DisplayInlineTable
  return DisplayInlineTableWrapper

proc createAnonTable(ctx: var InnerBlockContext; computed: CSSComputedValues) =
  if ctx.anonTableWrapper == nil:
    let inherited = computed.inheritProperties()
    let (outerComputed, innerComputed) = inherited.splitTable()
    #TODO this should be DisplayInlineTableWrapper inside inline contexts
    outerComputed{"display"} = DisplayTableWrapper
    let innerTable = BlockBox(computed: innerComputed)
    ctx.anonTableWrapper = BlockBox(
      computed: outerComputed,
      nested: @[innerTable]
    )

proc flushTableRow(ctx: var InnerBlockContext) =
  if ctx.anonRow != nil:
    if ctx.blockgroup.parent.computed{"display"} in ProperTableRowParent:
      ctx.blockgroup.parent.nested.add(ctx.anonRow)
    else:
      ctx.createAnonTable(ctx.styledNode.computed)
      ctx.anonTableWrapper.nested[0].nested.add(ctx.anonRow)
    ctx.anonRow = nil

proc flushTable(ctx: var InnerBlockContext) =
  ctx.flushTableRow()
  if ctx.anonTableWrapper != nil:
    ctx.blockgroup.parent.nested.add(ctx.anonTableWrapper)

proc iflush(ctx: var InnerBlockContext) =
  if ctx.iroot != nil:
    assert ctx.iroot.computed{"display"} in {DisplayInline, DisplayInlineBlock,
      DisplayInlineTable, DisplayInlineFlex}
    ctx.blockgroup.add(ctx.iroot)
    ctx.iroot = nil
    ctx.ibox = nil

proc bflush(ctx: var InnerBlockContext) =
  ctx.iflush()
  ctx.blockgroup.flush()

proc flushInherit(ctx: var InnerBlockContext) =
  if ctx.parent != nil:
    if not ctx.listItemReset:
      ctx.parent.listItemCounter = ctx.listItemCounter
    ctx.parent.quoteLevel = ctx.quoteLevel

proc flush(ctx: var InnerBlockContext) =
  ctx.blockgroup.flush()
  ctx.flushTableRow()
  ctx.flushTable()
  ctx.flushInherit()

proc reconstructInlineParents(ctx: var InnerBlockContext): InlineFragment =
  let rootNode = ctx.inlineStack[0]
  var parent = InlineFragment(
    computed: rootNode.computed,
    node: rootNode
  )
  ctx.iroot = parent
  for i in 1 ..< ctx.inlineStack.len:
    let node = ctx.inlineStack[i]
    let nbox = InlineFragment(computed: node.computed, node: node)
    assert nbox.computed{"display"} != DisplayTableCell
    parent.children.add(nbox)
    parent = nbox
  return parent

proc buildFromElem(ctx: var InnerBlockContext; styledNode: StyledNode) =
  let box = ctx.blockgroup.parent
  case styledNode.computed{"display"}
  of DisplayBlock, DisplayFlowRoot:
    ctx.iflush()
    ctx.flush()
    box.nested.add(ctx.buildBlock(styledNode))
  of DisplayFlex:
    ctx.iflush()
    ctx.flush()
    box.nested.add(ctx.buildFlex(styledNode))
  of DisplayListItem:
    ctx.flush()
    inc ctx.listItemCounter
    let marker = newMarkerBox(styledNode.computed, ctx.listItemCounter)
    let position = styledNode.computed{"list-style-position"}
    let content = case position
    of ListStylePositionOutside: ctx.buildBlock(styledNode)
    of ListStylePositionInside: ctx.buildBlock(styledNode, marker)
    case position
    of ListStylePositionOutside:
      content.computed = content.computed.copyProperties()
      content.computed{"display"} = DisplayBlock
      let markerComputed = marker.computed.copyProperties()
      markerComputed{"display"} = DisplayBlock
      let marker = BlockBox(
        computed: marker.computed,
        inline: RootInlineFragment(fragment: marker)
      )
      let child = BlockBox(
        computed: styledNode.computed,
        nested: @[marker, content]
      )
      box.nested.add(child)
    of ListStylePositionInside:
      box.nested.add(content)
  of DisplayInline:
    ctx.buildInlineBoxes(styledNode)
  of DisplayInlineBlock, DisplayInlineTable, DisplayInlineFlex:
    # create a new inline box that we can safely put our inline block into
    ctx.iflush()
    let computed = styledNode.computed.inheritProperties()
    ctx.ibox = InlineFragment(computed: computed, node: styledNode)
    if ctx.inlineStack.len > 0:
      let iparent = ctx.reconstructInlineParents()
      iparent.children.add(ctx.ibox)
      ctx.iroot = iparent
    else:
      ctx.iroot = ctx.ibox
    let childBox = case styledNode.computed{"display"}
    of DisplayInlineBlock: ctx.buildBlock(styledNode)
    of DisplayInlineTable: ctx.buildTable(styledNode)
    of DisplayInlineFlex: ctx.buildFlex(styledNode)
    else: nil
    let wrapper = InlineFragment(computed: childBox.computed, box: childBox)
    ctx.ibox.children.add(wrapper)
    ctx.iflush()
  of DisplayTable:
    #TODO why no ctx.iflush()?
    ctx.flush()
    let child = ctx.buildTable(styledNode)
    box.nested.add(child)
  of DisplayTableRow:
    ctx.bflush()
    ctx.flushTableRow()
    let child = ctx.buildTableRow(styledNode)
    if box.computed{"display"} in ProperTableRowParent:
      box.nested.add(child)
    else:
      ctx.createAnonTable(box.computed)
      ctx.anonTableWrapper.nested[0].nested.add(child)
  of DisplayTableRowGroup, DisplayTableHeaderGroup, DisplayTableFooterGroup:
    ctx.bflush()
    ctx.flushTableRow()
    let child = ctx.buildTableRowGroup(styledNode)
    if box.computed{"display"} in {DisplayTable, DisplayInlineTable}:
      box.nested.add(child)
    else:
      ctx.createAnonTable(box.computed)
      ctx.anonTableWrapper.nested[0].nested.add(child)
  of DisplayTableCell:
    ctx.bflush()
    let child = ctx.buildTableCell(styledNode)
    if box.computed{"display"} == DisplayTableRow:
      box.nested.add(child)
    else:
      if ctx.anonRow == nil:
        let wrapperVals = box.computed.inheritProperties()
        wrapperVals{"display"} = DisplayTableRow
        ctx.anonRow = BlockBox(computed: wrapperVals)
      ctx.anonRow.nested.add(child)
  of DisplayTableCaption:
    ctx.bflush()
    ctx.flushTableRow()
    let child = ctx.buildTableCaption(styledNode)
    if box.computed{"display"} in {DisplayTable, DisplayInlineTable}:
      box.nested.add(child)
    else:
      ctx.createAnonTable(box.computed)
      # only add first caption
      if ctx.anonTableWrapper.nested.len == 1:
        ctx.anonTableWrapper.nested.add(child)
  of DisplayTableColumn:
    discard #TODO
  of DisplayTableColumnGroup:
    discard #TODO
  of DisplayNone: discard
  of DisplayTableWrapper, DisplayInlineTableWrapper:
    assert false

proc buildAnonymousInlineText(ctx: var InnerBlockContext; text: string;
    styledNode: StyledNode; bmp: Bitmap = nil) =
  if ctx.iroot == nil:
    let computed = styledNode.computed.inheritProperties()
    ctx.ibox = InlineFragment(computed: computed, node: styledNode)
    if ctx.inlineStack.len > 0:
      let iparent = ctx.reconstructInlineParents()
      iparent.children.add(ctx.ibox)
      ctx.iroot = iparent
    else:
      ctx.iroot = ctx.ibox
  ctx.ibox.bmp = bmp
  ctx.ibox.text.add(text)

proc buildReplacement(ctx: var InnerBlockContext; child, parent: StyledNode) =
  case child.content.t
  of ContentOpenQuote:
    let quotes = parent.computed{"quotes"}
    var text: string = ""
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].s
    elif quotes.auto:
      text = quoteStart(ctx.quoteLevel)
    else: return
    ctx.buildAnonymousInlineText(text, parent)
    inc ctx.quoteLevel
  of ContentCloseQuote:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
    let quotes = parent.computed{"quotes"}
    var text: string = ""
    if quotes.qs.len > 0:
      text = quotes.qs[min(ctx.quoteLevel, quotes.qs.high)].e
    elif quotes.auto:
      text = quoteEnd(ctx.quoteLevel)
    else: return
    ctx.buildAnonymousInlineText(text, parent)
  of ContentNoOpenQuote:
    inc ctx.quoteLevel
  of ContentNoCloseQuote:
    if ctx.quoteLevel > 0: dec ctx.quoteLevel
  of ContentString:
    #TODO canBuildAnonymousInline?
    ctx.buildAnonymousInlineText(child.content.s, parent)
  of ContentImage:
    #TODO idk
    ctx.buildAnonymousInlineText("[img]", parent, child.content.bmp)
  of ContentVideo:
    ctx.buildAnonymousInlineText("[video]", parent)
  of ContentAudio:
    ctx.buildAnonymousInlineText("[audio]", parent)
  of ContentNewline:
    ctx.iflush()
    #TODO ??
    # this used to set ibox (before we had iroot), now I'm not sure if we
    # should reconstruct here first
    ctx.iroot = InlineFragment(
      computed: parent.computed.inheritProperties(),
      newline: true
    )
    ctx.iflush()

proc buildInlineBoxes(ctx: var InnerBlockContext; styledNode: StyledNode) =
  ctx.iflush()
  ctx.inlineStack.add(styledNode)
  var lbox = ctx.reconstructInlineParents()
  lbox.splitType.incl(stSplitStart)
  ctx.ibox = lbox
  for child in styledNode.children:
    case child.t
    of stElement:
      ctx.buildFromElem(child)
    of stText:
      if ctx.ibox != lbox:
        ctx.iflush()
        lbox = ctx.reconstructInlineParents()
        ctx.ibox = lbox
      lbox.text.add(child.textData)
    of stReplacement:
      ctx.buildReplacement(child, styledNode)
  if ctx.ibox != lbox:
    ctx.iflush()
    lbox = ctx.reconstructInlineParents()
    ctx.ibox = lbox
  lbox.splitType.incl(stSplitEnd)
  ctx.inlineStack.setLen(ctx.inlineStack.len - 1)
  ctx.iflush()

proc newInnerBlockContext(styledNode: StyledNode; box: BlockBox;
    lctx: LayoutContext; parent: ptr InnerBlockContext): InnerBlockContext =
  assert box.computed{"display"} != DisplayInline
  var ctx = InnerBlockContext(
    styledNode: styledNode,
    blockgroup: BlockGroup(parent: box, lctx: lctx),
    lctx: lctx,
    parent: parent
  )
  if parent != nil:
    ctx.listItemCounter = parent[].listItemCounter
    ctx.quoteLevel = parent[].quoteLevel
  for reset in styledNode.computed{"counter-reset"}:
    if reset.name == "list-item":
      ctx.listItemCounter = reset.num
      ctx.listItemReset = true
  return ctx

proc buildInnerBlockBox(ctx: var InnerBlockContext) =
  let box = ctx.blockgroup.parent
  assert box.computed{"display"} != DisplayInline
  for child in ctx.styledNode.children:
    case child.t
    of stElement:
      ctx.iflush()
      ctx.buildFromElem(child)
    of stText:
      let text = child.textData
      if canBuildAnonymousInline(ctx.blockgroup, box.computed, text):
        ctx.buildAnonymousInlineText(text, ctx.styledNode)
    of stReplacement:
      ctx.buildReplacement(child, ctx.styledNode)
  ctx.iflush()

proc buildBlock(styledNode: StyledNode; lctx: LayoutContext;
    marker: InlineFragment = nil; parent: ptr InnerBlockContext = nil):
    BlockBox =
  let box = BlockBox(computed: styledNode.computed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, lctx, parent)
  if marker != nil:
    ctx.iroot = marker
    ctx.iflush()
  ctx.buildInnerBlockBox()
  # Flush anonymous tables here, to avoid setting inline layout with tables.
  ctx.flushTableRow()
  ctx.flushTable()
  # (flush here, because why not)
  ctx.flushInherit()
  # Avoid unnecessary anonymous block boxes. This also helps set our layout to
  # inline even if no inner anonymous block was buildd.
  if box.nested.len == 0:
    box.inline = if ctx.blockgroup.inline != nil:
      ctx.blockgroup.inline
    else:
      RootInlineFragment(fragment: InlineFragment(
        computed: lctx.myRootProperties
      ))
    ctx.blockgroup.inline = nil
  ctx.blockgroup.flush()
  return box

proc buildFlex(styledNode: StyledNode; lctx: LayoutContext;
    parent: ptr InnerBlockContext = nil): BlockBox =
  let box = BlockBox(computed: styledNode.computed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, lctx, parent)
  assert box.computed{"display"} != DisplayInline
  for child in ctx.styledNode.children:
    case child.t
    of stElement:
      ctx.iflush()
      let display = child.computed{"display"}.blockify()
      if display != child.computed{"display"}:
        #TODO this is a hack.
        # it exists because passing down a different `computed' would need
        # changes in way too many procedures, which I am not ready to make yet.
        let newChild = StyledNode()
        newChild[] = child[]
        newChild.computed = child.computed.copyProperties()
        newChild.computed{"display"} = display
        ctx.buildFromElem(newChild)
      else:
        ctx.buildFromElem(child)
    of stText:
      let text = child.textData
      if ctx.blockgroup.canBuildAnonymousInline(box.computed, text):
        ctx.buildAnonymousInlineText(text, ctx.styledNode)
    of stReplacement:
      ctx.buildReplacement(child, ctx.styledNode)
  ctx.iflush()
  # Flush anonymous tables here, to avoid setting inline layout with tables.
  ctx.flushTableRow()
  ctx.flushTable()
  # (flush here, because why not)
  ctx.flushInherit()
  ctx.blockgroup.flush()
  assert box.inline == nil
  const FlexReverse = {FlexDirectionRowReverse, FlexDirectionColumnReverse}
  if box.computed{"flex-direction"} in FlexReverse:
    box.nested.reverse()
  return box

proc buildTableCell(parent: var InnerBlockContext; styledNode: StyledNode):
    BlockBox =
  let box = BlockBox(node: styledNode, computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, parent.lctx, addr parent)
  ctx.buildInnerBlockBox()
  ctx.flush()
  return box

proc buildTableRowChildWrappers(box: BlockBox) =
  var wrapperVals: CSSComputedValues = nil
  for child in box.nested.mitems:
    if child.computed{"display"} != DisplayTableCell:
      if wrapperVals == nil:
        wrapperVals = box.computed.inheritProperties()
        wrapperVals{"display"} = DisplayTableCell
      child = BlockBox(computed: wrapperVals, nested: @[child])

proc buildTableRow(parent: var InnerBlockContext; styledNode: StyledNode):
    BlockBox =
  let box = BlockBox(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, parent.lctx, addr parent)
  ctx.buildInnerBlockBox()
  ctx.flush()
  box.buildTableRowChildWrappers()
  return box

proc buildTableRowGroupChildWrappers(box: BlockBox) =
  let wrapperVals = box.computed.inheritProperties()
  wrapperVals{"display"} = DisplayTableRow
  for child in box.nested.mitems:
    if child.computed{"display"} != DisplayTableRow:
      let wrapper = BlockBox(computed: wrapperVals, nested: @[child])
      wrapper.buildTableRowChildWrappers()
      child = wrapper

proc buildTableRowGroup(parent: var InnerBlockContext; styledNode: StyledNode):
    BlockBox =
  let box = BlockBox(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, parent.lctx, addr parent)
  ctx.buildInnerBlockBox()
  ctx.flush()
  box.buildTableRowGroupChildWrappers()
  return box

proc buildTableCaption(parent: var InnerBlockContext; styledNode: StyledNode):
    BlockBox =
  let box = BlockBox(computed: styledNode.computed)
  var ctx = newInnerBlockContext(styledNode, box, parent.lctx, addr parent)
  ctx.buildInnerBlockBox()
  ctx.flush()
  return box

proc buildTableChildWrappers(box: BlockBox; computed: CSSComputedValues) =
  let innerTable = BlockBox(computed: computed, node: box.node)
  let wrapperVals = box.computed.inheritProperties()
  wrapperVals{"display"} = DisplayTableRow
  var caption: BlockBox = nil
  for child in box.nested:
    if child.computed{"display"} in ProperTableChild:
      innerTable.nested.add(child)
    elif child.computed{"display"} == DisplayTableCaption:
      if caption == nil:
        caption = child
    else:
      let wrapper = BlockBox(computed: wrapperVals, nested: @[child])
      wrapper.buildTableRowChildWrappers()
      innerTable.nested.add(wrapper)
  box.nested = @[innerTable]
  if caption != nil:
    box.nested.add(caption)

proc buildTable(parent: var InnerBlockContext; styledNode: StyledNode):
    BlockBox =
  let (outerComputed, innerComputed) = styledNode.computed.splitTable()
  let box = BlockBox(computed: outerComputed, node: styledNode)
  var ctx = newInnerBlockContext(styledNode, box, parent.lctx, addr parent)
  ctx.buildInnerBlockBox()
  ctx.flush()
  outerComputed{"display"} = outerComputed{"display"}.toTableWrapper()
  box.buildTableChildWrappers(innerComputed)
  return box

proc layout*(root: StyledNode; attrsp: ptr WindowAttributes): BlockBox =
  let space = availableSpace(
    w = stretch(attrsp[].width_px),
    h = stretch(attrsp[].height_px)
  )
  let lctx = LayoutContext(
    attrsp: attrsp,
    positioned: @[space],
    myRootProperties: rootProperties()
  )
  let box = root.buildBlock(lctx)
  var marginBottomOut: LayoutUnit
  lctx.layoutRootBlock(box, space, offset(x = 0, y = 0), marginBottomOut)
  return box
