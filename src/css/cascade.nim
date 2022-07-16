import algorithm
import streams
import sugar

import css/cssparser
import css/mediaquery
import css/select
import css/selectorparser
import css/sheet
import css/stylednode
import css/values
import html/dom
import html/tags

type
  ApplyResult = object
    normal: seq[CSSDeclaration]
    important: seq[CSSDeclaration]
  DeclarationList* = array[PseudoElem, seq[CSSDeclaration]]

proc applyProperty(elem: Element, d: CSSDeclaration, pseudo: PseudoElem) =
  var parent: CSSComputedValues
  if elem.parentElement != nil:
    parent = elem.parentElement.css
  else:
    parent = rootProperties()

  if pseudo == PSEUDO_NONE:
    elem.css.applyValue(parent, d)
  else:
    if elem.pseudo[pseudo] == nil:
      elem.pseudo[pseudo] = elem.css.inheritProperties()
    elem.pseudo[pseudo].applyValue(elem.css, d)

  elem.cssapplied = true

proc applyProperty(styledNode: StyledNode, parent: CSSComputedValues, d: CSSDeclaration) =
  
  styledNode.computed.applyValue(parent, d)
  #else:
    #if styled.pseudo[pseudo] == nil:
    #  elem.pseudo[pseudo] = elem.css.inheritProperties()
    #elem.pseudo[pseudo].applyValue(elem.css, d)

  if styledNode.node != nil:
    Element(styledNode.node).cssapplied = true

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

func applies(mqlist: MediaQueryList): bool =
  for mq in mqlist:
    if mq.applies():
      return true
  return false

type ToSorts = array[PseudoElem, seq[(int, seq[CSSDeclaration])]]

proc calcRule(tosorts: var ToSorts, elem: Element, rule: CSSRuleDef) =
  for sel in rule.sels:
    if elem.selectorsMatch(sel):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec,rule.decls))

func calcRules(elem: Element, sheet: CSSStylesheet): DeclarationList =
  var tosorts: ToSorts
  for rule in sheet.gen_rules(elem.tagType, elem.id, elem.classList):
    tosorts.calcRule(elem, rule)

  for i in PseudoElem:
    tosorts[i].sort((x, y) => cmp(x[0], y[0]))
    result[i] = collect(newSeq):
      for item in tosorts[i]:
        for dl in item[1]:
          dl

 
proc applyNormal(ares: var ApplyResult, decls: seq[CSSDeclaration]) =
  for decl in decls:
    if not decl.important:
      ares.normal.add(decl)

proc applyImportant(ares: var ApplyResult, decls: seq[CSSDeclaration]) =
  for decl in decls:
    if decl.important:
      ares.important.add(decl)

proc checkRendered(element: Element, prev: CSSComputedValues, ppseudo: array[PSEUDO_BEFORE..PSEUDO_AFTER, CSSComputedValues]) =
  if element.rendered:
    for p in PSEUDO_BEFORE..PSEUDO_AFTER:
      if ppseudo[p] != element.pseudo[p] and ppseudo[p] == nil:
        if element.parentElement != nil:
          element.parentElement.rendered = false
        element.rendered = false
        return
    for t in CSSPropertyType:
      if not element.css[t].equals(prev[t]):
        if element.parentElement != nil:
          element.parentElement.rendered = false
        element.rendered = false
        return
    for p in PSEUDO_BEFORE..PSEUDO_AFTER:
      if ppseudo[p] != nil:
        for t in CSSPropertyType:
          if not element.pseudo[p][t].equals(ppseudo[p][t]):
            element.rendered = false
            return

proc applyDeclarations(element: Element, ua, user: DeclarationList, author: seq[DeclarationList], pseudo: PseudoElem) =
  var ares: ApplyResult

  ares.applyNormal(ua[pseudo])
  ares.applyNormal(user[pseudo])
  for rule in author:
    ares.applyNormal(rule[pseudo])

  for rule in author:
    ares.applyImportant(rule[pseudo])

  if pseudo == PSEUDO_NONE:
    let style = element.attr("style")
    if style.len > 0:
      let inline_rules = newStringStream(style).parseListOfDeclarations2()
      ares.applyNormal(inline_rules)
      ares.applyImportant(inline_rules)

  ares.applyImportant(user[pseudo])
  ares.applyImportant(ua[pseudo])

  for rule in ares.normal:
    element.applyProperty(rule, pseudo)

  for rule in ares.important:
    element.applyProperty(rule, pseudo)

# Always returns a new styled node, with the passed declarations applied.
proc applyDeclarations(elem: Element, parent: CSSComputedValues, ua, user: DeclarationList, author: seq[DeclarationList]): StyledNode =
  let pseudo = PSEUDO_NONE
  var ares: ApplyResult

  ares.applyNormal(ua[pseudo])
  ares.applyNormal(user[pseudo])
  for rule in author:
    ares.applyNormal(rule[pseudo])

  for rule in author:
    ares.applyImportant(rule[pseudo])

  let style = Element(elem).attr("style")
  if style.len > 0:
    let inline_rules = newStringStream(style).parseListOfDeclarations2()
    ares.applyNormal(inline_rules)
    ares.applyImportant(inline_rules)

  ares.applyImportant(user[pseudo])
  ares.applyImportant(ua[pseudo])

  result = StyledNode(t: STYLED_ELEMENT, node: elem, computed: parent.inheritProperties())
  for rule in ares.normal:
    result.applyProperty(parent, rule)

  for rule in ares.important:
    result.applyProperty(parent, rule)

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem, parent: CSSComputedValues, ua, user: DeclarationList, author: seq[DeclarationList]): StyledNode =
  var ares: ApplyResult

  ares.applyNormal(ua[pseudo])
  ares.applyNormal(user[pseudo])
  for rule in author:
    ares.applyNormal(rule[pseudo])

  for rule in author:
    ares.applyImportant(rule[pseudo])

  ares.applyImportant(user[pseudo])
  ares.applyImportant(ua[pseudo])

  if ares.normal.len > 0 or ares.important.len > 0:
    result = StyledNode(t: STYLED_ELEMENT, node: nil, computed: parent.inheritProperties(), pseudo: pseudo)
    for rule in ares.normal:
      result.applyProperty(parent, rule)

    for rule in ares.important:
      result.applyProperty(parent, rule)

func applyMediaQuery(ss: CSSStylesheet): CSSStylesheet =
  result = ss
  for mq in ss.mq_list:
    if mq.query.applies():
      result.add(mq.children.applyMediaQuery())

proc resetRules(elem: Element) =
  elem.css = if elem.parentElement != nil:
    elem.parentElement.css.inheritProperties()
  else:
    rootProperties()

  for pseudo in PSEUDO_BEFORE..PSEUDO_AFTER:
    elem.pseudo[pseudo] = nil

proc applyRules(elem: Element, ua, user: CSSStylesheet, author: seq[CSSStylesheet]) =
  let uadecls = calcRules(elem, ua)
  let userdecls = calcRules(elem, user)
  var authordecls: seq[DeclarationList]
  for rule in author:
    authordecls.add(calcRules(elem, rule))

  for pseudo in PseudoElem:
    elem.applyDeclarations(uadecls, userdecls, authordecls, pseudo)

func calcRules(elem: Element, ua, user: CSSStylesheet, author: seq[CSSStylesheet]): tuple[uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]] =
  result.uadecls = calcRules(elem, ua)
  result.userdecls = calcRules(elem, user)
  for rule in author:
    result.authordecls.add(calcRules(elem, rule))

proc applyStyle(parent: StyledNode, elem: Element, uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]): StyledNode =
  let parentComputed = if parent != nil:
    parent.computed
  else:
    rootProperties()

  result = elem.applyDeclarations(parentComputed, uadecls, userdecls, authordecls)
  assert result != nil

proc applyRules(document: Document, ua, user: CSSStylesheet, previousStyled: StyledNode): StyledNode =
  if document.html == nil:
    return

  var author: seq[CSSStylesheet]

  if document.head != nil:
    for sheet in document.head.sheets:
      author.add(sheet)

  var lenstack = newSeqOfCap[int](256)
  var styledStack: seq[(StyledNode, Node, PseudoElem, StyledNode)]
  if previousStyled != nil:
    styledStack.add((nil, document.html, PSEUDO_NONE, previousStyled))
  else:
    styledStack.add((nil, document.html, PSEUDO_NONE, nil))

  #TODO TODO TODO this can't work as we currently store cached children in the
  # same seq we use for storing new children...
  # For now we just reset previous children which effectively disables caching.
  while styledStack.len > 0:
    let (styledParent, child, pseudo, cachedChild) = styledStack.pop()

    # Remove stylesheets on nil
    if pseudo == PSEUDO_NONE and child == nil:
      let len = lenstack.pop()
      author.setLen(author.len - len)
      continue

    template stack_append(styledParent: StyledNode, child: Node) =
      if child.nodeType != ELEMENT_NODE or Element(child).cssapplied:
        var cachedChild: StyledNode
        for it in styledParent.children:
          if it.node == child:
            cachedChild = it
            break
        styledStack.add((styledParent, child, PSEUDO_NONE, cachedChild))
      else:
        eprint "else branch"
        styledStack.add((styledParent, child, PSEUDO_NONE, nil))

    template stack_append(styledParent: StyledNode, ps: PseudoElem) =
      if Element(styledParent.node).cssapplied:
        var cachedChild: StyledNode
        for it in styledParent.children:
          if it.t == STYLED_ELEMENT and it.pseudo == ps:
            cachedChild = it
            break
        styledStack.add((styledParent, nil, ps, cachedChild))
      else:
        eprint "else branch 2"
        styledStack.add((styledParent, nil, ps, nil))

    var styledChild: StyledNode
    if cachedChild != nil:
      styledChild = cachedChild
      if styledParent == nil:
        result = styledChild
      else:
        styledParent.children.add(styledChild)
      styledChild.children.setLen(0)
    else:
      if pseudo != PSEUDO_NONE:
        let (ua, user, authordecls) = Element(styledParent.node).calcRules(ua, user, author)
        let styledPseudo = pseudo.applyDeclarations(styledParent.computed, ua, user, authordecls)
        if styledPseudo != nil:
          styledParent.children.add(styledPseudo)
          let content = styledPseudo.computed{"content"}
          if content.len > 0:
            styledPseudo.children.add(StyledNode(t: STYLED_TEXT, text: content))
      else:
        assert child != nil
        if styledParent != nil:
          if child.nodeType == ELEMENT_NODE:
            let (ua, user, authordecls) = Element(child).calcRules(ua, user, author)
            styledChild = applyStyle(styledParent, Element(child), ua, user, authordecls)
            styledParent.children.add(styledChild)
          elif child.nodeType == TEXT_NODE:
            let text = Text(child)
            styledChild = StyledNode(t: STYLED_TEXT, node: child, text: text.data)
            styledParent.children.add(styledChild)
        else:
          # Root element
          assert result == nil
          let (ua, user, authordecls) = Element(child).calcRules(ua, user, author)
          styledChild = applyStyle(styledParent, Element(child), ua, user, authordecls)
          result = styledChild

    if styledChild != nil and styledChild.node != nil and styledChild.node.nodeType == ELEMENT_NODE:
      let elem = Element(styledChild.node)
      # Add a nil before the last element (in-stack), so we can remove the
      # stylesheets
      if elem.sheets.len > 0:
        author.add(elem.sheets)
        lenstack.add(elem.sheets.len)
        styledStack.add((nil, nil, PSEUDO_NONE, nil))

      stack_append styledChild, PSEUDO_AFTER

      for i in countdown(elem.childNodes.high, 0):
        stack_append styledChild, elem.childNodes[i]

      stack_append styledChild, PSEUDO_BEFORE

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet, previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery()
  let userss = userss.applyMediaQuery()
  return document.applyRules(uass, userss, previousStyled)

proc refreshStyle*(elem: Element) =
  elem.cssapplied = false
  for child in elem.children:
    child.refreshStyle()
