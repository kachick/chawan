import streams
import sequtils
import sugar
import algorithm

import css/select
import css/selparser
import css/parser
import css/values
import html/dom
import html/tags

type
  ApplyResult = object
    normal: seq[CSSDeclaration]
    important: seq[CSSDeclaration]
  RuleList* = array[low(PseudoElem)..high(PseudoElem), seq[CSSSimpleBlock]]

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
  var rules_head: ParsedStylesheet

  for child in document.head.children:
    if child.tagType == TAG_STYLE:
      let style = HTMLStyleElement(child)
      rules_head.add(style.stylesheet)

  if rules_head.len > 0:
    embedded_rules.add(rules_head)

  stack.setLen(0)

  stack.add(document.root)

  document.root.css = rootProperties()

  while stack.len > 0:
    let elem = stack.pop()

    var rules_local: ParsedStylesheet
    for child in document.head.children:
      if child.tagType == TAG_STYLE:
        let style = HTMLStyleElement(child)
        rules_local.add(style.stylesheet)

    if rules_local.len > 0:
      embedded_rules.add(rules_local)

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
