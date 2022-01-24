import algorithm
import streams
import sugar

import css/mediaquery
import css/parser
import css/select
import css/selparser
import css/sheet
import css/values
import html/dom

type
  ApplyResult = object
    normal: seq[CSSDeclaration]
    important: seq[CSSDeclaration]
  DeclarationList* = array[PseudoElem, seq[CSSDeclaration]]

proc applyProperty(elem: Element, d: CSSDeclaration, pseudo: PseudoElem) =
  var parent: CSSSpecifiedValues
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

#TODO couldn't these two procedures be merged?
proc applyNormal(ares: var ApplyResult, decls: seq[CSSDeclaration]) =
  for decl in decls:
    if not decl.important:
      ares.normal.add(decl)

proc applyImportant(ares: var ApplyResult, decls: seq[CSSDeclaration]) =
  for decl in decls:
    if decl.important:
      ares.important.add(decl)

proc checkRendered(element: Element, prev: CSSSpecifiedValues, ppseudo: array[PSEUDO_BEFORE..PSEUDO_AFTER, CSSSpecifiedValues]) =
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

proc applyRules(element: Element, ua, user: DeclarationList, author: seq[DeclarationList], pseudo: PseudoElem) =
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

# TODO this is kinda broken
func applyMediaQuery(ss: CSSStylesheet): CSSStylesheet =
  result = ss
  for mq in ss.mq_list:
    if mq.query.applies():
      result.add(mq.children.applyMediaQuery())

proc applyRules(document: Document, ua, user: CSSStylesheet) =
  var stack: seq[Element]

  var embedded_rules: seq[CSSStylesheet]

  stack.add(document.head)

  for sheet in document.head.sheets:
    embedded_rules.add(sheet)

  stack.setLen(0)

  stack.add(document.root)

  while stack.len > 0:
    let elem = stack.pop()

    embedded_rules.add(elem.sheets)

    if not elem.cssapplied:
      let prev = elem.css
      let ppseudo = elem.pseudo
      if elem.parentElement != nil:
        elem.css = elem.parentElement.css.inheritProperties()
      else:
        elem.css = rootProperties()
      for pseudo in PSEUDO_BEFORE..PSEUDO_AFTER:
        elem.pseudo[pseudo] = nil

      let uarules = calcRules(elem, ua)
      let userrules = calcRules(elem, user)
      var authorrules: seq[DeclarationList]
      for rule in embedded_rules:
        authorrules.add(calcRules(elem, rule))

      for pseudo in PseudoElem:
        elem.applyRules(uarules, userrules, authorrules, pseudo)

      elem.checkRendered(prev, ppseudo)

    for i in countdown(elem.children.high, 0):
      stack.add(elem.children[i])

    embedded_rules.setLen(embedded_rules.len - elem.sheets.len)

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet) =
  let uass = uass.applyMediaQuery()
  let userss = userss.applyMediaQuery()
  document.applyRules(uass, userss)

proc refreshStyle*(elem: Element) =
  elem.cssapplied = false
  for child in elem.children:
    child.refreshStyle()
