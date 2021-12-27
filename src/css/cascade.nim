import algorithm
import sequtils
import streams
import sugar

import css/mediaquery
import css/parser
import css/select
import css/selparser
import css/sheet
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

func calcRule(tosorts: var array[PseudoElem, seq[tuple[s:int,b:CSSSimpleBlock]]], elem: Element, rule: CSSRuleBase) =
  if rule of CSSRuleDef:
    let rule = CSSRuleDef(rule)
    for sel in rule.sels:
      let match = elem.selectorsMatch(sel)
      if match.success:
        let spec = getSpecificity(sel)
        tosorts[match.pseudo].add((spec,rule.oblock))
  elif rule of CSSMediaQueryDef:
    let def = CSSMediaQueryDef(rule)
    if def.query.applies():
      for child in def.children:
        tosorts.calcRule(elem, child)

func calcRules(elem: Element, rules: CSSStylesheet): RuleList =
  var tosorts: array[PseudoElem, seq[tuple[s:int,b:CSSSimpleBlock]]]
  for rule in rules:
    tosorts.calcRule(elem, rule)

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
    let decls = parseListOfDeclarations(rule.value)
    ares.applyItems(decls)

  let rules_user = user[pseudo]
  for rule in rules_user:
    let decls = parseListOfDeclarations(rule.value)
    ares.applyItems(decls)

  let rules_author = author[pseudo]
  for rule in rules_author:
    let decls = parseListOfDeclarations(rule.value)
    ares.applyItems(decls)

  if pseudo == PSEUDO_NONE:
    let style = element.attr("style")
    if style.len > 0:
      let inline_rules = newStringStream(style).parseListOfDeclarations()
      ares.applyItems(inline_rules)

  for rule in ares.normal:
    element.applyProperty(rule, pseudo)

  for rule in ares.important:
    element.applyProperty(rule, pseudo)

proc applyRules*(document: Document, ua, user: CSSStylesheet) =
  var stack: seq[Element]

  var embedded_rules: seq[CSSStylesheet]

  stack.add(document.head)
  var rules_head: CSSStylesheet

  for child in document.head.children:
    if child.tagType == TAG_STYLE:
      let style = HTMLStyleElement(child)
      rules_head.add(style.sheet)

  if rules_head.len > 0:
    embedded_rules.add(rules_head)

  stack.setLen(0)

  stack.add(document.root)

  document.root.css = rootProperties()

  while stack.len > 0:
    let elem = stack.pop()

    var rules_local: CSSStylesheet
    for child in document.head.children:
      if child.tagType == TAG_STYLE:
        let style = HTMLStyleElement(child)
        rules_local.add(style.sheet)

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

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet) =
  document.applyRules(uass, userss)

proc refreshStyle*(elem: Element) =
  elem.cssapplied = false
  for child in elem.children:
    child.refreshStyle()
