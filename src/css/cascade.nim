import std/algorithm
import std/options
import std/strutils

import css/cssparser
import css/cssvalues
import css/match
import css/mediaquery
import css/selectorparser
import css/sheet
import css/stylednode
import html/catom
import html/dom
import html/enums
import js/jscolor
import layout/layoutunit
import types/color
import types/opt

import chame/tags

type
  RuleList* = array[PseudoElem, seq[CSSRuleDef]]

  RuleListMap* = ref object
    ua: RuleList # user agent
    user: RuleList
    author: seq[RuleList]

func appliesLR(feature: MediaFeature; window: Window;
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

func applies(feature: MediaFeature; window: Window): bool =
  case feature.t
  of mftColor:
    return 8 in feature.range
  of mftGrid:
    return feature.b
  of mftHover:
    return feature.b
  of mftPrefersColorScheme:
    return feature.b
  of mftWidth:
    return feature.appliesLR(window, toLayoutUnit(window.attrs.width_px))
  of mftHeight:
    return feature.appliesLR(window, toLayoutUnit(window.attrs.height_px))
  of mftScripting:
    return feature.b == window.settings.scripting

func applies(mq: MediaQuery; window: Window): bool =
  case mq.t
  of mctMedia:
    case mq.media
    of mtAll: return true
    of mtPrint: return false
    of mtScreen: return true
    of mtSpeech: return false
    of mtTty: return true
    of mtUnknown: return false
  of mctNot:
    return not mq.n.applies(window)
  of mctAnd:
    return mq.anda.applies(window) and mq.andb.applies(window)
  of mctOr:
    return mq.ora.applies(window) or mq.orb.applies(window)
  of mctFeature:
    return mq.feature.applies(window)

func applies*(mqlist: MediaQueryList; window: Window): bool =
  for mq in mqlist:
    if mq.applies(window):
      return true
  return false

appliesFwdDecl = applies

type
  ToSorts = array[PseudoElem, seq[(int, CSSRuleDef)]]

proc calcRule(tosorts: var ToSorts; styledNode: StyledNode; rule: CSSRuleDef) =
  for sel in rule.sels:
    if styledNode.selectorsMatch(sel):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec, rule))

func calcRules(styledNode: StyledNode; sheet: CSSStylesheet): RuleList =
  var tosorts: ToSorts
  let elem = Element(styledNode.node)
  for rule in sheet.genRules(elem.localName, elem.id, elem.classList.toks):
    tosorts.calcRule(styledNode, rule)
  for i in PseudoElem:
    tosorts[i].sort((proc(x, y: (int, CSSRuleDef)): int =
      cmp(x[0], y[0])
    ), order = Ascending)
    result[i] = newSeqOfCap[CSSRuleDef](tosorts[i].len)
    for item in tosorts[i]:
      result[i].add(item[1])

func calcPresentationalHints(element: Element): CSSComputedValues =
  template set_cv(a, b: untyped) =
    if result == nil:
      new(result)
    result{a} = b
  template map_width =
    let s = parseDimensionValues(element.attr(satWidth))
    if s.isSome:
      set_cv "width", s.get
  template map_height =
    let s = parseDimensionValues(element.attr(satHeight))
    if s.isSome:
      set_cv "height", s.get
  template map_width_nozero =
    let s = parseDimensionValues(element.attr(satWidth))
    if s.isSome and s.get.num != 0:
      set_cv "width", s.get
  template map_height_nozero =
    let s = parseDimensionValues(element.attr(satHeight))
    if s.isSome and s.get.num != 0:
      set_cv "height", s.get
  template map_bgcolor =
    let s = element.attr(satBgcolor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "background-color", c.get.cellColor()
  template map_size =
    let s = element.attrul(satSize)
    if s.isSome:
      set_cv "width", CSSLength(num: float64(s.get), unit: cuCh)
  template map_valign =
    case element.attr(satValign).toLowerAscii()
    of "top":
      set_cv "vertical-align", CSSVerticalAlign(keyword: VerticalAlignTop)
    of "middle":
      set_cv "vertical-align", CSSVerticalAlign(keyword: VerticalAlignMiddle)
    of "bottom":
      set_cv "vertical-align", CSSVerticalAlign(keyword: VerticalAlignBottom)
    of "baseline":
      set_cv "vertical-align", CSSVerticalAlign(keyword: VerticalAlignBaseline)
  template map_align =
    case element.attr(satAlign).toLowerAscii()
    of "center", "middle": set_cv "text-align", TextAlignChaCenter
    of "left": set_cv "text-align", TextAlignChaLeft
    of "right": set_cv "text-align", TextAlignChaRight
  template map_table_align =
    case element.attr(satAlign).toLowerAscii()
    of "left":
     set_cv "float", FloatLeft
    of "right":
      set_cv "float", FloatRight
    of "center":
      set_cv "margin-left", CSSLengthAuto #TODO should be inline-start
      set_cv "margin-right", CSSLengthAuto #TODO should be inline-end
  template map_text =
    let s = element.attr(satText)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get.cellColor()
  template map_color =
    let s = element.attr(satColor)
    if s != "":
      let c = parseLegacyColor(s)
      if c.isSome:
        set_cv "color", c.get.cellColor()
  template map_colspan =
    let colspan = element.attrulgz(satColspan)
    if colspan.isSome:
      let i = colspan.get
      if i <= 1000:
        set_cv "-cha-colspan", int(i)
  template map_rowspan =
    let rowspan = element.attrul(satRowspan)
    if rowspan.isSome:
      let i = rowspan.get
      if i <= 65534:
        set_cv "-cha-rowspan", int(i)
  template map_list_type_ol =
    let ctype = element.attr(satType)
    if ctype.len > 0:
      case ctype[0]
      of '1': set_cv "list-style-type", ListStyleTypeDecimal
      of 'a': set_cv "list-style-type", ListStyleTypeLowerAlpha
      of 'A': set_cv "list-style-type", ListStyleTypeUpperAlpha
      of 'i': set_cv "list-style-type", ListStyleTypeLowerRoman
      of 'I': set_cv "list-style-type", ListStyleTypeUpperRoman
      else: discard
  template map_list_type_ul =
    let ctype = element.attr(satType)
    if ctype.len > 0:
      case ctype.toLowerAscii()
      of "none": set_cv "list-style-type", ListStyleTypeNone
      of "disc": set_cv "list-style-type", ListStyleTypeDisc
      of "circle": set_cv "list-style-type", ListStyleTypeCircle
      of "square": set_cv "list-style-type", ListStyleTypeSquare
  template set_bgcolor_is_canvas =
    set_cv "-cha-bgcolor-is-canvas", true

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
  of TAG_HTML:
    set_bgcolor_is_canvas
  of TAG_BODY:
    set_bgcolor_is_canvas
    map_bgcolor
    map_text
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    let cols = textarea.attrul(satCols).get(20)
    let rows = textarea.attrul(satRows).get(1)
    set_cv "width", CSSLength(unit: cuCh, num: float64(cols))
    set_cv "height", CSSLength(unit: cuEm, num: float64(rows))
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

type
  CSSValueEntryObj = object
    normal: seq[CSSComputedEntry]
    important: seq[CSSComputedEntry]

  CSSValueEntryMap = array[CSSOrigin, CSSValueEntryObj]

func buildComputedValues(rules: CSSValueEntryMap; presHints, parent:
    CSSComputedValues): CSSComputedValues =
  new(result)
  var previousOrigins: array[CSSOrigin, CSSComputedValues]
  for entry in rules[coUserAgent].normal: # user agent
    result.applyValue(entry, parent, nil)
  previousOrigins[coUserAgent] = result.copyProperties()
  # Presentational hints override user agent style, but respect user/author
  # style.
  if presHints != nil:
    for prop in CSSPropertyType:
      if presHints[prop] != nil:
        result[prop] = presHints[prop]
  for entry in rules[coUser].normal: # user
    result.applyValue(entry, parent, previousOrigins[coUserAgent])
  # save user origins so author can use them
  previousOrigins[coUser] = result.copyProperties()
  for entry in rules[coAuthor].normal: # author
    result.applyValue(entry, parent, previousOrigins[coUser])
  # no need to save user origins
  for entry in rules[coAuthor].important: # author important
    result.applyValue(entry, parent, previousOrigins[coUser])
  # important, so no need to save origins
  for entry in rules[coUser].important: # user important
    result.applyValue(entry, parent, previousOrigins[coUserAgent])
  # important, so no need to save origins
  for entry in rules[coUserAgent].important: # user agent important
    result.applyValue(entry, parent, nil)
  # important, so no need to save origins
  # set defaults
  for prop in CSSPropertyType:
    if result[prop] == nil:
      if prop.inherited and parent != nil and parent[prop] != nil:
        result[prop] = parent[prop]
      else:
        result[prop] = getDefault(prop)
  if result{"float"} != FloatNone:
    #TODO it may be better to handle this in layout
    let display = result{"display"}.blockify()
    if display != result{"display"}:
      result{"display"} = display

proc add(map: var CSSValueEntryObj; rules: seq[CSSRuleDef]) =
  for rule in rules:
    map.normal.add(rule.normalVals)
    map.important.add(rule.importantVals)

proc applyDeclarations(styledNode: StyledNode; parent: CSSComputedValues;
    map: RuleListMap) =
  var rules: CSSValueEntryMap
  var presHints: CSSComputedValues = nil
  rules[coUserAgent].add(map.ua[peNone])
  rules[coUser].add(map.user[peNone])
  for rule in map.author:
    rules[coAuthor].add(rule[peNone])
  if styledNode.node != nil:
    let element = Element(styledNode.node)
    let style = element.style_cached
    if style != nil:
      for decl in style.decls:
        let vals = parseComputedValues(decl.name, decl.value)
        if decl.important:
          rules[coAuthor].important.add(vals)
        else:
          rules[coAuthor].normal.add(vals)
    presHints = element.calcPresentationalHints()
  styledNode.computed = rules.buildComputedValues(presHints, parent)

func hasValues(rules: CSSValueEntryMap): bool =
  for origin in CSSOrigin:
    if rules[origin].normal.len > 0 or rules[origin].important.len > 0:
      return true
  return false

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem; styledParent: StyledNode;
    map: RuleListMap): StyledNode =
  var rules: CSSValueEntryMap
  rules[coUserAgent].add(map.ua[pseudo])
  rules[coUser].add(map.user[pseudo])
  for rule in map.author:
    rules[coAuthor].add(rule[pseudo])
  if rules.hasValues():
    let cvals = rules.buildComputedValues(nil, styledParent.computed)
    return styledParent.newStyledElement(pseudo, cvals)
  return nil

func applyMediaQuery(ss: CSSStylesheet; window: Window): CSSStylesheet =
  if ss == nil:
    return nil
  var res = CSSStylesheet()
  res[] = ss[]
  for mq in ss.mqList:
    if mq.query.applies(window):
      res.add(mq.children.applyMediaQuery(window))
  return res

func calcRules(styledNode: StyledNode; ua, user: CSSStylesheet;
    author: seq[CSSStylesheet]): RuleListMap =
  let uadecls = calcRules(styledNode, ua)
  var userdecls: RuleList
  if user != nil:
    userdecls = calcRules(styledNode, user)
  var authordecls: seq[RuleList]
  for rule in author:
    authordecls.add(calcRules(styledNode, rule))
  return RuleListMap(
    ua: uadecls,
    user: userdecls,
    author: authordecls
  )

proc applyStyle(parent, styledNode: StyledNode; map: RuleListMap) =
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
  parentDeclMap: RuleListMap

proc getAuthorSheets(document: Document): seq[CSSStylesheet] =
  var author: seq[CSSStylesheet]
  for sheet in document.sheets():
    author.add(sheet.applyMediaQuery(document.window))
  return author

proc applyRulesFrameValid(frame: CascadeFrame): StyledNode =
  let styledParent = frame.styledParent
  let cachedChild = frame.cachedChild
  let styledChild = if cachedChild.t == stElement:
    if cachedChild.pseudo != peNone:
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

proc applyRulesFrameInvalid(frame: CascadeFrame; ua, user: CSSStylesheet;
    author: seq[CSSStylesheet]; declmap: var RuleListMap): StyledNode =
  var styledChild: StyledNode
  let pseudo = frame.pseudo
  let styledParent = frame.styledParent
  let child = frame.child
  if frame.pseudo != peNone:
    case pseudo
    of peBefore, peAfter:
      let declmap = frame.parentDeclMap
      let styledPseudo = pseudo.applyDeclarations(styledParent, declmap)
      if styledPseudo != nil and styledPseudo.computed{"content"}.len > 0:
        for content in styledPseudo.computed{"content"}:
          styledPseudo.children.add(styledPseudo.newStyledReplacement(content))
        styledParent.children.add(styledPseudo)
    of peInputText:
      let s = HTMLInputElement(styledParent.node).inputString()
      if s.len > 0:
        let content = styledParent.node.document.newText(s)
        let styledText = styledParent.newStyledText(content)
        # Note: some pseudo-elements (like input text) generate text nodes
        # directly, so we have to cache them like this.
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of peTextareaText:
      let s = HTMLTextAreaElement(styledParent.node).textAreaString()
      if s.len > 0:
        let content = styledParent.node.document.newText(s)
        let styledText = styledParent.newStyledText(content)
        styledText.pseudo = pseudo
        styledParent.children.add(styledText)
    of peImage:
      let src = Element(styledParent.node).attr(satSrc)
      let content = CSSContent(
        t: ContentImage,
        s: src,
        bmp: HTMLImageElement(styledParent.node).bitmap
      )
      let styledText = styledParent.newStyledReplacement(content)
      styledText.pseudo = pseudo
      styledParent.children.add(styledText)
    of peCanvas:
      let content = CSSContent(
        t: ContentImage,
        s: "canvas://",
        bmp: HTMLCanvasElement(styledParent.node).bitmap
      )
      let styledText = styledParent.newStyledReplacement(content)
      styledText.pseudo = pseudo
      styledParent.children.add(styledText)
    of peVideo:
      let content = CSSContent(t: ContentVideo)
      let styledText = styledParent.newStyledReplacement(content)
      styledText.pseudo = pseudo
      styledParent.children.add(styledText)
    of peAudio:
      let content = CSSContent(t: ContentAudio)
      let styledText = styledParent.newStyledReplacement(content)
      styledText.pseudo = pseudo
      styledParent.children.add(styledText)
    of peNewline:
      let content = CSSContent(t: ContentNewline)
      let styledText = styledParent.newStyledReplacement(content)
      styledParent.children.add(styledText)
      styledText.pseudo = pseudo
    of peNone: assert false
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

proc stackAppend(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledParent: StyledNode; child: Node; i: var int) =
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
      pseudo: peNone,
      cachedChild: cached
    ))
  else:
    styledStack.add(CascadeFrame(
      styledParent: styledParent,
      child: child,
      pseudo: peNone,
      cachedChild: nil
    ))

proc stackAppend(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledParent: StyledNode; pseudo: PseudoElem; i: var int;
    parentDeclMap: RuleListMap = nil) =
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
proc appendChildren(styledStack: var seq[CascadeFrame]; frame: CascadeFrame;
    styledChild: StyledNode; parentDeclMap: RuleListMap) =
  # i points to the child currently being inspected.
  var idx = if frame.cachedChild != nil:
    frame.cachedChild.children.len - 1
  else:
    -1
  let elem = Element(styledChild.node)
  styledStack.stackAppend(frame, styledChild, peAfter, idx, parentDeclMap)
  case elem.tagType
  of TAG_TEXTAREA: styledStack.stackAppend(frame, styledChild, peTextareaText, idx)
  of TAG_IMG, TAG_IMAGE: styledStack.stackAppend(frame, styledChild, peImage, idx)
  of TAG_VIDEO: styledStack.stackAppend(frame, styledChild, peVideo, idx)
  of TAG_AUDIO: styledStack.stackAppend(frame, styledChild, peAudio, idx)
  of TAG_BR: styledStack.stackAppend(frame, styledChild, peNewline, idx)
  of TAG_CANVAS: styledStack.stackAppend(frame, styledChild, peCanvas, idx)
  else:
    for i in countdown(elem.childList.high, 0):
      if elem.childList[i] of Element or elem.childList[i] of Text:
        styledStack.stackAppend(frame, styledChild, elem.childList[i], idx)
    if elem.tagType == TAG_INPUT:
      styledStack.stackAppend(frame, styledChild, peInputText, idx)
  styledStack.stackAppend(frame, styledChild, peBefore, idx, parentDeclMap)

# Builds a StyledNode tree, optionally based on a previously cached version.
proc applyRules(document: Document; ua, user: CSSStylesheet;
    cachedTree: StyledNode): StyledNode =
  let html = document.html
  if html == nil:
    return
  let author = document.getAuthorSheets()
  var styledStack = @[CascadeFrame(
    child: html,
    pseudo: peNone,
    cachedChild: cachedTree
  )]
  var root: StyledNode
  while styledStack.len > 0:
    var frame = styledStack.pop()
    var declmap: RuleListMap
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
      if styledChild.t == stElement and styledChild.node != nil:
        styledChild.applyDependValues()
        styledStack.appendChildren(frame, styledChild, declmap)
  return root

proc applyStylesheets*(document: Document; uass, userss: CSSStylesheet;
    previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery(document.window)
  let userss = userss.applyMediaQuery(document.window)
  return document.applyRules(uass, userss, previousStyled)
