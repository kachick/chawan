import std/algorithm
import std/options
import std/strutils

import css/cssparser
import css/match
import css/mediaquery
import css/selectorparser
import css/sheet
import css/stylednode
import css/values
import html/dom
import html/enums
import layout/layoutunit
import types/color
import types/opt

import chame/tags

type
  DeclarationList* = array[PseudoElem, seq[CSSDeclaration]]

  DeclarationListMap* = ref object
    ua: DeclarationList # user agent
    user: DeclarationList
    author: seq[DeclarationList]

func appliesLR(feature: MediaFeature, window: Window,
    n: LayoutUnit): bool =
  let a = px(feature.lengthrange.a, window.attrs, 0)
  let b = px(feature.lengthrange.b, window.attrs, 0)
  if not feature.lengthaeq and a == n:
    return false
  if a > n:
    return false
  if not feature.lengthbeq and b == n:
    return false
  if b < n:
    return false
  return true

func applies(feature: MediaFeature, window: Window): bool =
  case feature.t
  of FEATURE_COLOR:
    return 8 in feature.range
  of FEATURE_GRID:
    return feature.b
  of FEATURE_HOVER:
    return feature.b
  of FEATURE_PREFERS_COLOR_SCHEME:
    return feature.b
  of FEATURE_WIDTH:
    return feature.appliesLR(window, toLayoutUnit(window.attrs.width_px))
  of FEATURE_HEIGHT:
    return feature.appliesLR(window, toLayoutUnit(window.attrs.height_px))

func applies(mq: MediaQuery, window: Window): bool =
  case mq.t
  of CONDITION_MEDIA:
    case mq.media
    of MEDIA_TYPE_ALL: return true
    of MEDIA_TYPE_PRINT: return false
    of MEDIA_TYPE_SCREEN: return true
    of MEDIA_TYPE_SPEECH: return false
    of MEDIA_TYPE_TTY: return true
    of MEDIA_TYPE_UNKNOWN: return false
  of CONDITION_NOT:
    return not mq.n.applies(window)
  of CONDITION_AND:
    return mq.anda.applies(window) and mq.andb.applies(window)
  of CONDITION_OR:
    return mq.ora.applies(window) or mq.orb.applies(window)
  of CONDITION_FEATURE:
    return mq.feature.applies(window)

func applies*(mqlist: MediaQueryList, window: Window): bool =
  for mq in mqlist:
    if mq.applies(window):
      return true
  return false

type
  ToSorts = array[PseudoElem, seq[(int, seq[CSSDeclaration])]]

proc calcRule(tosorts: var ToSorts, styledNode: StyledNode, rule: CSSRuleDef) =
  for sel in rule.sels:
    if styledNode.selectorsMatch(sel):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec, rule.decls))

func calcRules(styledNode: StyledNode, sheet: CSSStylesheet): DeclarationList =
  var tosorts: ToSorts
  let elem = Element(styledNode.node)
  for rule in sheet.genRules(elem.localName, elem.id, elem.classList.toks):
    tosorts.calcRule(styledNode, rule)
  for i in PseudoElem:
    tosorts[i].sort((proc(x, y: (int, seq[CSSDeclaration])): int =
      cmp(x[0], y[0])
    ), order = Ascending)
    result[i] = newSeqOfCap[CSSDeclaration](tosorts[i].len)
    for item in tosorts[i]:
      result[i].add(item[1])

func calcPresentationalHints(element: Element): CSSComputedValues =
  template set_cv(a, b: untyped) =
    if result == nil:
      new(result)
    result{a} = b
  template map_width =
    let s = parseDimensionValues(element.attr(atWidth))
    if s.isSome:
      set_cv "width", s.get
  template map_height =
    let s = parseDimensionValues(element.attr(atHeight))
    if s.isSome:
      set_cv "height", s.get
  template map_width_nozero =
    let s = parseDimensionValues(element.attr(atWidth))
    if s.isSome and s.get.num != 0:
      set_cv "width", s.get
  template map_height_nozero =
    let s = parseDimensionValues(element.attr(atHeight))
    if s.isSome and s.get.num != 0:
      set_cv "height", s.get
  template map_bgcolor =
    let s = element.attr(atBgcolor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "background-color", c.get
  template map_size =
    let s = element.attrul(atSize)
    if s.isSome:
      set_cv "width", CSSLength(num: float64(s.get), unit: UNIT_CH)
  template map_valign =
    case element.attr(atValign).toLowerAscii()
    of "top": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_TOP)
    of "middle": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_MIDDLE)
    of "bottom": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_BOTTOM)
    of "baseline": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_BASELINE)
  template map_align =
    case element.attr(atAlign).toLowerAscii()
    of "center", "middle": set_cv "text-align", TEXT_ALIGN_CHA_CENTER
    of "left": set_cv "text-align", TEXT_ALIGN_CHA_LEFT
    of "right": set_cv "text-align", TEXT_ALIGN_CHA_RIGHT
  template map_table_align =
    case element.attr(atAlign).toLowerAscii()
    of "left":
     set_cv "float", FLOAT_LEFT
    of "right":
      set_cv "float", FLOAT_RIGHT
    of "center":
      set_cv "margin-left", CSSLengthAuto #TODO should be inline-start
      set_cv "margin-right", CSSLengthAuto #TODO should be inline-end
  template map_text =
    let s = element.attr(atText)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get
  template map_color =
    let s = element.attr(atColor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get
  template map_colspan =
    let colspan = element.attrulgz(atColspan)
    if colspan.isSome:
      let i = colspan.get
      if i <= 1000:
        set_cv "-cha-colspan", int(i)
  template map_rowspan =
    let rowspan = element.attrul(atRowspan)
    if rowspan.isSome:
      let i = rowspan.get
      if i <= 65534:
        set_cv "-cha-rowspan", int(i)
  template map_list_type_ol =
    let ctype = element.attr(atType)
    if ctype.len > 0:
      case ctype[0]
      of '1': set_cv "list-style-type", LIST_STYLE_TYPE_DECIMAL
      of 'a': set_cv "list-style-type", LIST_STYLE_TYPE_LOWER_ALPHA
      of 'A': set_cv "list-style-type", LIST_STYLE_TYPE_UPPER_ALPHA
      of 'i': set_cv "list-style-type", LIST_STYLE_TYPE_LOWER_ROMAN
      of 'I': set_cv "list-style-type", LIST_STYLE_TYPE_UPPER_ROMAN
      else: discard
  template map_list_type_ul =
    let ctype = element.attr(atType)
    if ctype.len > 0:
      case ctype.toLowerAscii()
      of "none": set_cv "list-style-type", LIST_STYLE_TYPE_NONE
      of "disc": set_cv "list-style-type", LIST_STYLE_TYPE_DISC
      of "circle": set_cv "list-style-type", LIST_STYLE_TYPE_CIRCLE
      of "square": set_cv "list-style-type", LIST_STYLE_TYPE_SQUARE

  case element.tagType
  of TAG_DIV:
    map_align
  of TAG_TABLE:
    map_height_nozero
    map_width_nozero
    map_bgcolor
    map_table_align
  of TAG_TD, TAG_TH:
    map_height_nozero
    map_width_nozero
    map_bgcolor
    map_valign
    map_align
    map_colspan
    map_rowspan
  of TAG_THEAD, TAG_TBODY, TAG_TFOOT, TAG_TR:
    map_height
    map_bgcolor
    map_valign
    map_align
  of TAG_COL:
    map_width
  of TAG_IMG, TAG_CANVAS:
    map_width
    map_height
  of TAG_BODY:
    map_bgcolor
    map_text
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    let cols = textarea.attrul(atCols).get(20)
    let rows = textarea.attrul(atRows).get(1)
    set_cv "width", CSSLength(unit: UNIT_CH, num: float64(cols))
    set_cv "height", CSSLength(unit: UNIT_EM, num: float64(rows))
  of TAG_FONT:
    map_color
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    if input.inputType in InputTypeWithSize:
      map_size
  of TAG_OL:
    map_list_type_ol
  of TAG_UL:
    map_list_type_ul
  else: discard

proc applyDeclarations(styledNode: StyledNode, parent: CSSComputedValues,
    map: DeclarationListMap) =
  let pseudo = PSEUDO_NONE
  var builder = newComputedValueBuilder(parent)

  builder.addValues(map.ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(map.user[pseudo], ORIGIN_USER)
  for rule in map.author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)
  if styledNode.node != nil:
    let element = Element(styledNode.node)
    let style = element.style_cached
    if style != nil:
      builder.addValues(style.decls, ORIGIN_AUTHOR)
    builder.preshints = element.calcPresentationalHints()

  styledNode.computed = builder.buildComputedValues()

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem, styledParent: StyledNode,
    map: DeclarationListMap): StyledNode =
  var builder = newComputedValueBuilder(styledParent.computed)

  builder.addValues(map.ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(map.user[pseudo], ORIGIN_USER)
  for rule in map.author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)

  if builder.hasValues():
    let cvals = builder.buildComputedValues()
    result = styledParent.newStyledElement(pseudo, cvals)

func applyMediaQuery(ss: CSSStylesheet, window: Window): CSSStylesheet =
  if ss == nil: return nil
  new(result)
  result[] = ss[]
  for mq in ss.mqList:
    if mq.query.applies(window):
      result.add(mq.children.applyMediaQuery(window))

func calcRules(styledNode: StyledNode, ua, user: CSSStylesheet,
    author: seq[CSSStylesheet]): DeclarationListMap =
  let uadecls = calcRules(styledNode, ua)
  var userdecls: DeclarationList
  if user != nil:
    userdecls = calcRules(styledNode, user)
  var authordecls: seq[DeclarationList]
  for rule in author:
    authordecls.add(calcRules(styledNode, rule))
  return DeclarationListMap(
    ua: uadecls,
    user: userdecls,
    author: authordecls
  )

proc applyStyle(parent, styledNode: StyledNode, map: DeclarationListMap) =
  let parentComputed = if parent != nil:
    parent.computed
  else:
    rootProperties()
  styledNode.applyDeclarations(parentComputed, map)

type CascadeFrame = object
  styledParent: StyledNode
  child: Node
  pseudo: PseudoElem
  cachedChild: StyledNode
  parentDeclMap: DeclarationListMap

proc getAuthorSheets(document: Document): seq[CSSStylesheet] =
  var author: seq[CSSStylesheet]
  for sheet in document.sheets():
    author.add(sheet.applyMediaQuery(document.window))
  return author

proc applyRulesFrameValid(frame: CascadeFrame): StyledNode =
  let styledParent = frame.styledParent
  let cachedChild = frame.cachedChild
  let styledChild = if cachedChild.t == STYLED_ELEMENT:
    if cachedChild.pseudo != PSEUDO_NONE:
      # Pseudo elements can't have invalid children.
      cachedChild
    else:
      # We can't just copy cachedChild.children from the previous pass,
      # as any child could be invalid.
      let element = Element(cachedChild.node)
      styledParent.newStyledElement(element, cachedChild.computed,
        cachedChild.depends)
  else:
    # Text
    cachedChild
  styledChild.parent = styledParent
  if styledParent != nil:
    styledParent.children.add(styledChild)
  return styledChild

proc applyRulesFrameInvalid(frame: CascadeFrame, ua, user: CSSStylesheet,
    author: seq[CSSStylesheet], declmap: var DeclarationListMap): StyledNode =
  var styledChild: StyledNode
  let pseudo = frame.pseudo
  let styledParent = frame.styledParent
  let child = frame.child
  if frame.pseudo != PSEUDO_NONE:
    case pseudo
    of PSEUDO_BEFORE, PSEUDO_AFTER:
      let declmap = frame.parentDeclMap
      let styledPseudo = pseudo.applyDeclarations(styledParent, declmap)
      if styledPseudo != nil:
        let contents = styledPseudo.computed{"content"}
        for content in contents:
          styledPseudo.children.add(styledPseudo.newStyledReplacement(content))
        styledParent.children.add(styledPseudo)
    of PSEUDO_INPUT_TEXT:
      let content = HTMLInputElement(styledParent.node).inputString()
      if content.len > 0:
        let styledText = styledParent.newStyledText(content)
        # Note: some pseudo-elements (like input text) generate text nodes
        # directly, so we have to cache them like this.
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of PSEUDO_TEXTAREA_TEXT:
      let content = HTMLTextAreaElement(styledParent.node).textAreaString()
      if content.len > 0:
        let styledText = styledParent.newStyledText(content)
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of PSEUDO_IMAGE:
      let src = Element(styledParent.node).attr(atSrc)
      let content = CSSContent(t: CONTENT_IMAGE, s: src)
      let styledText = styledParent.newStyledReplacement(content)
      styledText.pseudo = pseudo
      styledParent.children.add(styledText)
    of PSEUDO_NEWLINE:
      let content = CSSContent(t: CONTENT_NEWLINE)
      let styledText = styledParent.newStyledReplacement(content)
      styledParent.children.add(styledText)
      styledText.pseudo = pseudo
    of PSEUDO_NONE: assert false
  else:
    assert child != nil
    if styledParent != nil:
      if child of Element:
        styledChild = styledParent.newStyledElement(Element(child))
        styledParent.children.add(styledChild)
        declmap = styledChild.calcRules(ua, user, author)
        applyStyle(styledParent, styledChild, declmap)
      elif child of Text:
        let text = Text(child)
        styledChild = styledParent.newStyledText(text)
        styledParent.children.add(styledChild)
    else:
      # Root element
      styledChild = newStyledElement(Element(child))
      declmap = styledChild.calcRules(ua, user, author)
      applyStyle(styledParent, styledChild, declmap)
  return styledChild

proc stackAppend(styledStack: var seq[CascadeFrame], frame: CascadeFrame,
    styledParent: StyledNode, child: Node, i: var int) =
  if frame.cachedChild != nil:
    var cached: StyledNode
    while i >= 0:
      let it = frame.cachedChild.children[i]
      dec i
      if it.node == child:
        cached = it
        break
    styledStack.add(CascadeFrame(
      styledParent: styledParent,
      child: child,
      pseudo: PSEUDO_NONE,
      cachedChild: cached
    ))
  else:
    styledStack.add(CascadeFrame(
      styledParent: styledParent,
      child: child,
      pseudo: PSEUDO_NONE,
      cachedChild: nil
    ))

proc stackAppend(styledStack: var seq[CascadeFrame], frame: CascadeFrame,
    styledParent: StyledNode, pseudo: PseudoElem, i: var int,
    parentDeclMap: DeclarationListMap = nil) =
  if frame.cachedChild != nil:
    var cached: StyledNode
    let oldi = i
    while i >= 0:
      let it = frame.cachedChild.children[i]
      dec i
      if it.pseudo == pseudo:
        cached = it
        break
    # When calculating pseudo-element rules, their dependencies are added
    # to their parent's dependency list; so invalidating a pseudo-element
    # invalidates its parent too, which in turn automatically rebuilds
    # the pseudo-element.
    # In other words, we can just do this:
    if cached != nil:
      styledStack.add(CascadeFrame(
        styledParent: styledParent,
        pseudo: pseudo,
        cachedChild: cached,
        parentDeclMap: parentDeclMap
      ))
    else:
      i = oldi # move pointer back to where we started
  else:
    styledStack.add(CascadeFrame(
      styledParent: styledParent,
      pseudo: pseudo,
      cachedChild: nil,
      parentDeclMap: parentDeclMap
    ))

# Append children to styledChild.
proc appendChildren(styledStack: var seq[CascadeFrame], frame: CascadeFrame,
    styledChild: StyledNode, parentDeclMap: DeclarationListMap) =
  # i points to the child currently being inspected.
  var idx = if frame.cachedChild != nil:
    frame.cachedChild.children.len - 1
  else:
    -1
  let elem = Element(styledChild.node)
  styledStack.stackAppend(frame, styledChild, PSEUDO_AFTER, idx, parentDeclMap)
  if elem.tagType == TAG_TEXTAREA:
    styledStack.stackAppend(frame, styledChild, PSEUDO_TEXTAREA_TEXT, idx)
  elif elem.tagType == TAG_IMG or elem.tagType == TAG_IMAGE:
    styledStack.stackAppend(frame, styledChild, PSEUDO_IMAGE, idx)
  elif elem.tagType == TAG_BR:
    styledStack.stackAppend(frame, styledChild, PSEUDO_NEWLINE, idx)
  else:
    for i in countdown(elem.childList.high, 0):
      if elem.childList[i] of Element or elem.childList[i] of Text:
        styledStack.stackAppend(frame, styledChild, elem.childList[i], idx)
    if elem.tagType == TAG_INPUT:
      styledStack.stackAppend(frame, styledChild, PSEUDO_INPUT_TEXT, idx)
  styledStack.stackAppend(frame, styledChild, PSEUDO_BEFORE, idx, parentDeclMap)

# Builds a StyledNode tree, optionally based on a previously cached version.
proc applyRules(document: Document, ua, user: CSSStylesheet, cachedTree: StyledNode): StyledNode =
  let html = document.html
  if html == nil:
    return
  let author = document.getAuthorSheets()
  var styledStack = @[CascadeFrame(
    child: html,
    pseudo: PSEUDO_NONE,
    cachedChild: cachedTree
  )]
  var root: StyledNode
  while styledStack.len > 0:
    var frame = styledStack.pop()
    var declmap: DeclarationListMap
    let styledParent = frame.styledParent
    let valid = frame.cachedChild != nil and frame.cachedChild.isValid()
    let styledChild = if valid:
      frame.applyRulesFrameValid()
    else:
      # From here on, computed values of this node's children are invalid
      # because of property inheritance.
      frame.cachedChild = nil
      frame.applyRulesFrameInvalid(ua, user, author, declmap)
    if styledChild != nil:
      if styledParent == nil:
        # Root element
        root = styledChild
      if styledChild.t == STYLED_ELEMENT and styledChild.node != nil:
        styledChild.applyDependValues()
        styledStack.appendChildren(frame, styledChild, declmap)
  return root

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet,
    previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery(document.window)
  let userss = userss.applyMediaQuery(document.window)
  return document.applyRules(uass, userss, previousStyled)
