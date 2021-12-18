import unicode
import strutils
import tables
import streams
import sequtils
import sugar
import algorithm

import css/selector
import css/parser
import css/values
import html/dom
import html/tags

#TODO case sensitivity

type SelectResult = object
  success: bool
  pseudo: PseudoElem

func selectres(s: bool, p: PseudoElem = PSEUDO_NONE): SelectResult =
  return SelectResult(success: s, pseudo: p)

func psuccess(s: SelectResult): bool =
  return s.pseudo == PSEUDO_NONE and s.success

func attrSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.rel
  of ' ': return sel.attr in elem.attributes
  of '=': return elem.attr(sel.attr) == sel.value
  of '~': return sel.value in unicode.split(elem.attr(sel.attr))
  of '|':
    let val = elem.attr(sel.attr)
    return val == sel.value or sel.value.startsWith(val & '-')
  of '^': return elem.attr(sel.attr).startsWith(sel.value)
  of '$': return elem.attr(sel.attr).endsWith(sel.value)
  of '*': return elem.attr(sel.attr).contains(sel.value)
  else: return false

func pseudoSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.pseudo
  of "first-child": return elem.parentNode.firstElementChild == elem
  of "last-child": return elem.parentNode.lastElementChild == elem
  of "only-child": return elem.parentNode.firstElementChild == elem and elem.parentNode.lastElementChild == elem
  of "hover": return elem.hover
  of "root": return elem == elem.ownerDocument.root
  else: return false

func pseudoElemSelectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.elem
  of "before": return selectres(true, PSEUDO_BEFORE)
  of "after": return selectres(true, PSEUDO_AFTER)
  else: return selectres(false)

func selectorsMatch(elem: Element, selectors: SelectorList): SelectResult

func funcSelectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.name
  of "not":
    for slist in sel.fsels:
      let res = elem.selectorsMatch(slist)
      if res.success:
        return selectres(false)
    return selectres(true)
  of "is", "where":
    for slist in sel.fsels:
      let res = elem.selectorsMatch(slist)
      if res.success:
        return selectres(true)
    return selectres(false)
  else: discard

func selectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.t
  of TYPE_SELECTOR:
    return selectres(elem.tagType == sel.tag)
  of CLASS_SELECTOR:
    return selectres(sel.class in elem.classList)
  of ID_SELECTOR:
    return selectres(sel.id == elem.id)
  of ATTR_SELECTOR:
    return selectres(elem.attrSelectorMatches(sel))
  of PSEUDO_SELECTOR:
    return selectres(pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return pseudoElemSelectorMatches(elem, sel)
  of UNIVERSAL_SELECTOR:
    return selectres(true)
  of FUNC_SELECTOR:
    return funcSelectorMatches(elem, sel)
  of COMBINATOR_SELECTOR:
    #combinator without at least two members makes no sense
    assert sel.csels.len > 1
    let match = elem.selectorsMatch(sel.csels[^1])
    if match.success:
      var i = sel.csels.len - 2
      case sel.ct
      of DESCENDANT_COMBINATOR:
        var e = elem.parentElement
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if res.success:
            dec i
          e = e.parentElement
      of CHILD_COMBINATOR:
        var e = elem.parentElement
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if not res.success:
            return selectres(false)
          dec i
          e = e.parentElement
      of NEXT_SIBLING_COMBINATOR:
        var e = elem.previousElementSibling
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if not res.success:
            return selectres(false)
          dec i
          e = e.previousElementSibling
      of SUBSEQ_SIBLING_COMBINATOR:
        var e = elem.previousElementSibling
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if res.success:
            dec i
          e = e.previousElementSibling
      return selectres(i == -1, match.pseudo)
    else:
      return selectres(false)

func selectorsMatch(elem: Element, selectors: SelectorList): SelectResult =
  for sel in selectors.sels:
    let res = selectorMatches(elem, sel)
    if not res.success:
      return selectres(false)
    if res.pseudo != PSEUDO_NONE:
      if result.pseudo != PSEUDO_NONE:
        return selectres(false)
      result.pseudo = res.pseudo
  result.success = true

func selectElems(document: Document, sel: Selector): seq[Element] =
  case sel.t
  of TYPE_SELECTOR:
    return document.type_elements[sel.tag]
  of ID_SELECTOR:
    return document.id_elements[sel.id]
  of CLASS_SELECTOR:
    return document.class_elements[sel.class]
  of UNIVERSAL_SELECTOR:
    return document.all_elements
  of ATTR_SELECTOR:
    return document.all_elements.filter((elem) => attrSelectorMatches(elem, sel))
  of PSEUDO_SELECTOR:
    return document.all_elements.filter((elem) => pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return document.all_elements.filter((elem) => pseudoElemSelectorMatches(elem, sel))
  of FUNC_SELECTOR:
    return document.all_elements.filter((elem) => selectorMatches(elem, sel))
  of COMBINATOR_SELECTOR:
    return document.all_elements.filter((elem) => selectorMatches(elem, sel))

func selectElems(document: Document, selectors: SelectorList): seq[Element] =
  assert(selectors.len > 0)
  let sellist = optimizeSelectorList(selectors)
  result = document.selectElems(selectors[0])
  var i = 1

  while i < sellist.len:
    result = result.filter((elem) => selectorMatches(elem, sellist[i]).psuccess)
    inc i

proc querySelector*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseCSSListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))

proc applyProperty(elem: Element, d: CSSDeclaration, pseudo: PseudoElem) =
  var parent: CSSSpecifiedValues
  if elem.parentElement != nil:
    parent = elem.parentElement.css
  else:
    parent = rootProperties()

  case pseudo
  of PSEUDO_NONE:
    elem.css.applyValue(parent, d)
  of PSEUDO_BEFORE, PSEUDO_AFTER:
    if elem.pseudo[pseudo] == nil:
      elem.pseudo[pseudo] = elem.css.inheritProperties()
    elem.pseudo[pseudo].applyValue(parent, d)

  elem.cssapplied = true
  elem.rendered = false

type
  ParsedRule* = tuple[sels: seq[SelectorList], oblock: CSSSimpleBlock]
  ParsedStylesheet* = seq[ParsedRule]
  ApplyResult = object
    normal: seq[CSSDeclaration]
    important: seq[CSSDeclaration]
  RuleList = array[low(PseudoElem)..high(PseudoElem), seq[CSSSimpleBlock]]

proc parseStylesheet*(s: Stream): ParsedStylesheet =
  for v in parseCSS(s).value:
    let sels = parseSelectors(v.prelude)
    if sels.len > 1 or sels[^1].len > 0:
      result.add((sels: sels, oblock: v.oblock))

func calcRules(elem: Element, rules: ParsedStylesheet): RuleList =
  var tosorts: array[low(PseudoElem)..high(PseudoElem), seq[tuple[s:int,b:CSSSimpleBlock]]]
  for rule in rules:
    for sel in rule.sels:
      let match = elem.selectorsMatch(sel)
      if match.success:
        let spec = getSpecificity(sel)
        tosorts[match.pseudo].add((spec,rule.oblock))

  for i in low(PseudoElem)..high(PseudoElem):
    tosorts[i].sort((x, y) => cmp(x.s,y.s))
    result[i] = tosorts[i].map((x) => x.b)

proc applyItems(ares: var ApplyResult, decls: seq[CSSParsedItem]) =
  for item in decls:
    if item of CSSDeclaration:
      let decl = CSSDeclaration(item)
      if decl.important:
        ares.important.add(decl)
      else:
        ares.normal.add(decl)

proc applyRules(element: Element, ua, user, author: RuleList, pseudo: PseudoElem) =
  var ares: ApplyResult

  let rules_user_agent = ua[pseudo]
  for rule in rules_user_agent:
    let decls = parseCSSListOfDeclarations(rule.value)
    ares.applyItems(decls)

  let rules_user = user[pseudo]
  for rule in rules_user:
    let decls = parseCSSListOfDeclarations(rule.value)
    ares.applyItems(decls)

  let rules_author = author[pseudo]
  for rule in rules_author:
    let decls = parseCSSListOfDeclarations(rule.value)
    ares.applyItems(decls)

  if pseudo == PSEUDO_NONE:
    let style = element.attr("style")
    if style.len > 0:
      let inline_rules = newStringStream(style).parseCSSListOfDeclarations()
      ares.applyItems(inline_rules)

  for rule in ares.normal:
    element.applyProperty(rule, pseudo)

  for rule in ares.important:
    element.applyProperty(rule, pseudo)

proc applyRules*(document: Document, ua, user: ParsedStylesheet) =
  var stack: seq[Element]

  var embedded_rules: seq[ParsedStylesheet]

  stack.add(document.head)
  var rules_head = ""

  for child in document.head.children:
    if child.tagType == TAG_STYLE:
      for ct in child.childNodes:
        if ct.nodeType == TEXT_NODE:
          rules_head &= Text(ct).data

  if rules_head.len > 0:
    let parsed = newStringStream(rules_head).parseStylesheet()
    embedded_rules.add(parsed)

  stack.setLen(0)

  stack.add(document.root)

  document.root.css = rootProperties()

  while stack.len > 0:
    let elem = stack.pop()

    var rules_local = ""
    for child in elem.children:
      if child.tagType == TAG_STYLE:
        for ct in child.childNodes:
          if ct.nodeType == TEXT_NODE:
            rules_local &= Text(ct).data

    if rules_local.len > 0:
      let parsed = newStringStream(rules_local).parseStylesheet()
      embedded_rules.add(parsed)

    if not elem.cssapplied:
      if elem.parentElement != nil:
        elem.css = elem.parentElement.css.inheritProperties()
      else:
        elem.css = rootProperties()

      let uarules = calcRules(elem, ua)
      let userrules = calcRules(elem, user)
      let this_rules = embedded_rules.concat()
      let authorrules = calcRules(elem, this_rules)

      for pseudo in low(PseudoElem)..high(PseudoElem):
        elem.applyRules(uarules, userrules, authorrules, pseudo)

    var i = elem.children.len - 1
    while i >= 0:
      let child = elem.children[i]
      stack.add(child)
      dec i

    if rules_local.len > 0:
      discard embedded_rules.pop()

proc applyStylesheets*(document: Document, uass, userss: ParsedStylesheet) =
  document.applyRules(uass, userss)

proc refreshStyle*(elem: Element) =
  elem.cssapplied = false
  for child in elem.children:
    child.refreshStyle()
