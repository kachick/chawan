import algorithm
import options
import streams
import sugar

import css/cssparser
import css/match
import css/mediaquery
import css/selectorparser
import css/sheet
import css/stylednode
import css/values
import html/dom
import html/tags
import types/color

type
  DeclarationList* = array[PseudoElem, seq[CSSDeclaration]]

func applies(mq: MediaQuery): bool =
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
    return not mq.n.applies()
  of CONDITION_AND:
    return mq.anda.applies() and mq.andb.applies()
  of CONDITION_OR:
    return mq.ora.applies() or mq.orb.applies()
  of CONDITION_FEATURE:
    case mq.feature.t
    of FEATURE_COLOR:
      return true #TODO
    of FEATURE_GRID:
      return mq.feature.b
    of FEATURE_HOVER:
      return mq.feature.b
    of FEATURE_PREFERS_COLOR_SCHEME:
      return mq.feature.b

func applies*(mqlist: MediaQueryList): bool =
  for mq in mqlist:
    if mq.applies():
      return true
  return false

type ToSorts = array[PseudoElem, seq[(int, seq[CSSDeclaration])]]

proc calcRule(tosorts: var ToSorts, styledNode: StyledNode, rule: CSSRuleDef) =
  for sel in rule.sels:
    if styledNode.selectorsMatch(sel):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec,rule.decls))

func calcRules(styledNode: StyledNode, sheet: CSSStylesheet): DeclarationList =
  var tosorts: ToSorts
  let elem = Element(styledNode.node)
  for rule in sheet.gen_rules(elem.tagType, elem.id, elem.classList):
    tosorts.calcRule(styledNode, rule)

  for i in PseudoElem:
    tosorts[i].sort((x, y) => cmp(x[0], y[0]))
    result[i] = collect(newSeq):
      for item in tosorts[i]:
        for dl in item[1]:
          dl

func calcPresentationalHints(element: Element): CSSComputedValues =
  template set_cv(a, b, c: untyped) =
    if result == nil:
      new(result)
    result[a] = CSSComputedValue(t: a, v: ValueTypes[a], b: c)
  template map_width =
    let s = parseDimensionValues(element.attr("width"))
    if s.isSome:
      set_cv(PROPERTY_WIDTH, length, s.get)
  template map_height =
    let s = parseDimensionValues(element.attr("height"))
    if s.isSome:
      set_cv(PROPERTY_HEIGHT, length, s.get)
  template map_width_nozero =
    let s = parseDimensionValues(element.attr("width"))
    if s.isSome and s.get.num != 0:
      set_cv(PROPERTY_WIDTH, length, s.get)
  template map_height_nozero =
    let s = parseDimensionValues(element.attr("height"))
    if s.isSome and s.get.num != 0:
      set_cv(PROPERTY_HEIGHT, length, s.get)
  template map_bgcolor =
    let c = parseLegacyColor(element.attr("bgcolor"))
    if c.isSome:
      set_cv(PROPERTY_BACKGROUND_COLOR, color, c.get)

  case element.tagType
  of TAG_TABLE, TAG_TD, TAG_TH:
    map_height_nozero
    map_width_nozero
    map_bgcolor
  of TAG_THEAD, TAG_TBODY, TAG_TFOOT, TAG_TR:
    map_height
    map_bgcolor
  of TAG_COL:
    map_width
  else: discard
 
proc applyDeclarations(styledNode: StyledNode, parent: CSSComputedValues, ua, user: DeclarationList, author: seq[DeclarationList]) =
  let pseudo = PSEUDO_NONE
  var builder = newComputedValueBuilder(parent)

  builder.addValues(ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(user[pseudo], ORIGIN_USER)
  for rule in author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)
  if styledNode.node != nil:
    let element = Element(styledNode.node)
    let style = element.attr("style")
    if style.len > 0:
      let inline_rules = newStringStream(style).parseListOfDeclarations2()
      builder.addValues(inline_rules, ORIGIN_AUTHOR)
    builder.preshints = element.calcPresentationalHints()

  styledNode.computed = builder.buildComputedValues()

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem, styledParent: StyledNode, ua, user: DeclarationList, author: seq[DeclarationList]): StyledNode =
  var builder = newComputedValueBuilder(styledParent.computed)

  builder.addValues(ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(user[pseudo], ORIGIN_USER)
  for rule in author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)

  if builder.hasValues():
    result = styledParent.newStyledElement(pseudo, builder.buildComputedValues())

func applyMediaQuery(ss: CSSStylesheet): CSSStylesheet =
  if ss == nil: return nil
  result = ss
  for mq in ss.mq_list:
    if mq.query.applies():
      result.add(mq.children.applyMediaQuery())

func calcRules(styledNode: StyledNode, ua, user: CSSStylesheet, author: seq[CSSStylesheet]): tuple[uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]] =
  result.uadecls = calcRules(styledNode, ua)
  if user != nil:
    result.userdecls = calcRules(styledNode, user)
  for rule in author:
    result.authordecls.add(calcRules(styledNode, rule))

proc applyStyle(parent, styledNode: StyledNode, uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]) =
  let parentComputed = if parent != nil:
    parent.computed
  else:
    rootProperties()

  styledNode.applyDeclarations(parentComputed, uadecls, userdecls, authordecls)

# Builds a StyledNode tree, optionally based on a previously cached version.
proc applyRules(document: Document, ua, user: CSSStylesheet, cachedTree: StyledNode): StyledNode =
  if document.html == nil:
    return

  var author: seq[CSSStylesheet]

  if document.head != nil:
    for sheet in document.head.sheets:
      author.add(sheet.applyMediaQuery())

  var lenstack = newSeqOfCap[int](256)
  var styledStack: seq[(StyledNode, Node, PseudoElem, StyledNode)]
  styledStack.add((nil, document.html, PSEUDO_NONE, cachedTree))

  while styledStack.len > 0:
    var (styledParent, child, pseudo, cachedChild) = styledStack.pop()

    # Remove stylesheets on nil
    if pseudo == PSEUDO_NONE and child == nil:
      let len = lenstack.pop()
      author.setLen(author.len - len)
      continue

    var styledChild: StyledNode
    if cachedChild != nil and cachedChild.isValid():
      if cachedChild.t == STYLED_ELEMENT:
        if cachedChild.pseudo == PSEUDO_NONE:
          # We can't just copy cachedChild.children from the previous pass, as
          # any child could be invalid.
          styledChild = styledParent.newStyledElement(Element(cachedChild.node), cachedChild.computed, cachedChild.depends)
        else:
          # Pseudo elements can't have invalid children.
          styledChild = cachedChild
          styledChild.parent = styledParent
      else:
        # Text
        styledChild = cachedChild
        styledChild.parent = styledParent
      if styledParent == nil:
        # Root element
        result = styledChild
      else:
        styledParent.children.add(styledChild)
    else:
      cachedChild = nil
      if pseudo != PSEUDO_NONE:
        let (ua, user, authordecls) = styledParent.calcRules(ua, user, author)
        case pseudo
        of PSEUDO_BEFORE, PSEUDO_AFTER:
          let styledPseudo = pseudo.applyDeclarations(styledParent, ua, user, authordecls)
          if styledPseudo != nil:
            styledParent.children.add(styledPseudo)
            let content = styledPseudo.computed{"content"}
            if content.len > 0:
              styledPseudo.children.add(styledPseudo.newStyledText(content))
        of PSEUDO_INPUT_TEXT:
          let content = HTMLInputElement(styledParent.node).inputString()
          if content.len > 0:
            let styledText = styledParent.newStyledText(content)
            styledText.pseudo = pseudo
            styledParent.children.add(styledText)
        of PSEUDO_NONE: discard
      else:
        assert child != nil
        if styledParent != nil:
          if child.nodeType == ELEMENT_NODE:
            styledChild = styledParent.newStyledElement(Element(child))
            styledParent.children.add(styledChild)
            let (ua, user, authordecls) = styledChild.calcRules(ua, user, author)
            applyStyle(styledParent, styledChild, ua, user, authordecls)
          elif child.nodeType == TEXT_NODE:
            let text = Text(child)
            styledChild = styledParent.newStyledText(text)
            styledParent.children.add(styledChild)
        else:
          # Root element
          styledChild = newStyledElement(Element(child))
          let (ua, user, authordecls) = styledChild.calcRules(ua, user, author)
          applyStyle(styledParent, styledChild, ua, user, authordecls)
          result = styledChild

    if styledChild != nil and styledChild.t == STYLED_ELEMENT and styledChild.node != nil:
      styledChild.applyDependValues()
      # i points to the child currently being inspected.
      var i = if cachedChild != nil:
        cachedChild.children.len - 1
      else:
        -1
      template stack_append(styledParent: StyledNode, child: Node) =
        if cachedChild != nil:
          var cached: StyledNode
          while i >= 0:
            let it = cachedChild.children[i]
            dec i
            if it.node == child:
              cached = it
              break
          styledStack.add((styledParent, child, PSEUDO_NONE, cached))
        else:
          styledStack.add((styledParent, child, PSEUDO_NONE, nil))

      template stack_append(styledParent: StyledNode, ps: PseudoElem) =
        if cachedChild != nil:
          var cached: StyledNode
          let oldi = i
          while i >= 0:
            let it = cachedChild.children[i]
            dec i
            if it.pseudo == ps:
              cached = it
              break
          # When calculating pseudo-element rules, their dependencies are added
          # to their parent's dependency list; so invalidating a pseudo-element
          # invalidates its parent too, which in turn automatically rebuilds
          # the pseudo-element.
          # In other words, we can just do this:
          if cached != nil:
            styledStack.add((styledParent, nil, ps, cached))
          else:
            i = oldi # move pointer back to where we started
        else:
          styledStack.add((styledParent, nil, ps, nil))

      let elem = Element(styledChild.node)
      # Add a nil before the last element (in-stack), so we can remove the
      # stylesheets
      let sheets = elem.sheets()
      if sheets.len > 0:
        for sheet in sheets:
          author.add(sheet.applyMediaQuery())
        lenstack.add(sheets.len)
        styledStack.add((nil, nil, PSEUDO_NONE, nil))

      stack_append styledChild, PSEUDO_AFTER

      for i in countdown(elem.childNodes.high, 0):
        if elem.childNodes[i].nodeType in {ELEMENT_NODE, TEXT_NODE}:
          stack_append styledChild, elem.childNodes[i]

      if elem.tagType == TAG_INPUT:
        stack_append styledChild, PSEUDO_INPUT_TEXT
      stack_append styledChild, PSEUDO_BEFORE

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet, previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery()
  let userss = userss.applyMediaQuery()
  return document.applyRules(uass, userss, previousStyled)
