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
import types/enums

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
  of "hover": return elem.hover
  of "root": return elem == elem.ownerDocument.root
  else: return false

func pseudoElemSelectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.elem
  of "before": return selectres(true, PSEUDO_BEFORE)
  of "after": return selectres(true, PSEUDO_AFTER)
  else: return selectres(false)

func selectorsMatch(elem: Element, selectors: SelectorList): SelectResult

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
    return selectres(false)
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
            eprint "fail", e.tagType
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
    case sel.name
    of "not":
      return document.all_elements.filter((elem) => not selectorsMatch(elem, sel.fsels).psuccess)
    of "is", "where":
      return document.all_elements.filter((elem) => selectorsMatch(elem, sel.fsels).psuccess)
    return newSeq[Element]()
  of COMBINATOR_SELECTOR:
    return document.all_elements.filter((elem) => selectorMatches(elem, sel))

func selectElems(document: Document, selectors: SelectorList): seq[Element] =
  assert(selectors.len > 0)
  let sellist = optimizeSelectorList(selectors)
  result = document.selectElems(selectors[0])
  var i = 1

  while i < sellist.len:
    if sellist[i].t == FUNC_SELECTOR:
      case sellist[i].name
      of "not":
        result = result.filter((elem) => not selectorsMatch(elem, sellist[i].fsels).psuccess)
      of "is", "where":
        result = result.filter((elem) => selectorsMatch(elem, sellist[i].fsels).psuccess)
      else: discard
    else:
      result = result.filter((elem) => selectorMatches(elem, sellist[i]).psuccess)
    inc i

proc querySelector*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseCSSListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))

proc applyProperty(elem: Element, decl: CSSDeclaration, pseudo: PseudoElem) =
  let cval = getComputedValue(decl, elem.cssvalues)
  case pseudo
  of PSEUDO_NONE:
    elem.cssvalues[cval.t] = cval
  of PSEUDO_BEFORE:
    if elem.cssvalues_before == nil:
      elem.cssvalues_before.rootProperties()
    elem.cssvalues_before[cval.t] = cval
  of PSEUDO_AFTER:
    if elem.cssvalues_after == nil:
      elem.cssvalues_after.rootProperties()
    elem.cssvalues_after[cval.t] = cval
  elem.cssapplied = true
  elem.rendered = false

type
  ParsedRule* = tuple[sels: seq[SelectorList], oblock: CSSSimpleBlock]
  ParsedStylesheet* = seq[ParsedRule]
  ApplyResult = object
    normal: seq[tuple[e:Element,d:CSSDeclaration,p:PseudoElem]]
    important: seq[tuple[e:Element,d:CSSDeclaration,p:PseudoElem]]

proc parseStylesheet*(s: Stream): ParsedStylesheet =
  for v in parseCSS(s).value:
    let sels = parseSelectors(v.prelude)
    if sels.len > 1 or sels[^1].len > 0:
      result.add((sels: sels, oblock: v.oblock))

func calcRules(elem: Element, rules: ParsedStylesheet):
    array[low(PseudoElem)..high(PseudoElem), seq[CSSSimpleBlock]] =
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

proc applyItems*(ares: var ApplyResult, elem: Element, decls: seq[CSSParsedItem], pseudo: PseudoElem) =
  for item in decls:
    if item of CSSDeclaration:
      let decl = CSSDeclaration(item)
      if decl.important:
        ares.important.add((elem, decl, pseudo))
      else:
        ares.normal.add((elem, decl, pseudo))

proc applyRules*(document: Document, pss: ParsedStylesheet, reset: bool = false): ApplyResult =
  var stack: seq[Element]

  document.root.cssvalues.rootProperties()
  stack.add(document.root)

  while stack.len > 0:
    let elem = stack.pop()
    if not elem.cssapplied:
      if reset:
        elem.cssvalues.rootProperties()
        elem.cssvalues_before = nil
        elem.cssvalues_after = nil
      let rules_pseudo = calcRules(elem, pss)
      for pseudo in low(PseudoElem)..high(PseudoElem):
        let rules = rules_pseudo[pseudo]
        for rule in rules:
          let decls = parseCSSListOfDeclarations(rule.value)
          result.applyItems(elem, decls, pseudo)

    var i = elem.children.len - 1
    while i >= 0:
      let child = elem.children[i]
      stack.add(child)
      dec i

proc applyAuthorRules*(document: Document): ApplyResult =
  var stack: seq[Element]
  var embedded_rules: seq[ParsedStylesheet]

  stack.add(document.head)
  var rules_head = ""

  for child in document.head.children:
    if child.tagType == TAG_STYLE:
      for ct in child.childNodes:
        if ct.nodeType == TEXT_NODE:
          rules_head &= Text(ct).data

  stack.setLen(0)

  stack.add(document.root)

  if rules_head.len > 0:
    let parsed = newStringStream(rules_head).parseStylesheet()
    embedded_rules.add(parsed)

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
      let this_rules = embedded_rules.concat()
      let rules_pseudo = calcRules(elem, this_rules)

      for pseudo in low(PseudoElem)..high(PseudoElem):
        let rules = rules_pseudo[pseudo]
        for rule in rules:
          let decls = parseCSSListOfDeclarations(rule.value)
          result.applyItems(elem, decls, pseudo)

      let style = elem.attr("style")
      if style.len > 0:
        let inline_rules = newStringStream(style).parseCSSListOfDeclarations()
        result.applyItems(elem, inline_rules, PSEUDO_NONE)

    var i = elem.children.len - 1
    while i >= 0:
      let child = elem.children[i]
      stack.add(child)
      dec i

    if rules_local.len > 0:
      discard embedded_rules.pop()

proc applyStylesheets*(document: Document, uass: ParsedStylesheet, userss: ParsedStylesheet) =
  let ua = document.applyRules(uass, true)
  let user = document.applyRules(userss)
  let author = document.applyAuthorRules()
  var elems: seq[Element]

  for rule in ua.normal:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)
  for rule in user.normal:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)
  for rule in author.normal:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)

  for rule in author.important:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)
  for rule in user.important:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)
  for rule in ua.important:
    if not rule.e.cssapplied:
      elems.add(rule.e)
    rule.e.applyProperty(rule.d, rule.p)

  for elem in elems:
    if elem.parentElement != nil:
      elem.cssvalues.inheritProperties(elem.parentElement.cssvalues)
      if elem.cssvalues_before != nil:
        elem.cssvalues_before.inheritProperties(elem.cssvalues)
      if elem.cssvalues_after != nil:
        elem.cssvalues_after.inheritProperties(elem.cssvalues)

proc refreshStyle*(elem: Element) =
  elem.cssapplied = false
  for child in elem.children:
    child.refreshStyle()
