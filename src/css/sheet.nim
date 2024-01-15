import std/algorithm
import std/streams
import std/tables

import css/cssparser
import css/mediaquery
import css/selectorparser
import html/catom

type
  CSSRuleBase* = ref object of RootObj

  CSSRuleDef* = ref object of CSSRuleBase
    sels*: SelectorList
    decls*: seq[CSSDeclaration]
    # Absolute position in the stylesheet; used for sorting rules after
    # retrieval from the cache.
    idx: int

  CSSConditionalDef* = ref object of CSSRuleBase
    children*: CSSStylesheet

  CSSMediaQueryDef* = ref object of CSSConditionalDef
    query*: MediaQueryList

  CSSStylesheet* = ref object
    mqList*: seq[CSSMediaQueryDef]
    #TODO maybe just array[TagType] would be more efficient
    tagTable: Table[CAtom, seq[CSSRuleDef]]
    idTable: Table[string, seq[CSSRuleDef]]
    classTable: Table[string, seq[CSSRuleDef]]
    generalList: seq[CSSRuleDef]
    len: int
    factory: CAtomFactory

type SelectorHashes = object
  tag: CAtom
  id: string
  class: string

func newStylesheet*(cap: int, factory: CAtomFactory): CSSStylesheet =
  let bucketsize = cap div 2
  return CSSStylesheet(
    tagTable: initTable[CAtom, seq[CSSRuleDef]](bucketsize),
    idTable: initTable[string, seq[CSSRuleDef]](bucketsize),
    classTable: initTable[string, seq[CSSRuleDef]](bucketsize),
    generalList: newSeqOfCap[CSSRuleDef](bucketsize),
    factory: factory
  )

proc getSelectorIds(hashes: var SelectorHashes, sel: Selector): bool

proc getSelectorIds(hashes: var SelectorHashes, sels: CompoundSelector) =
  for sel in sels:
    if hashes.getSelectorIds(sel):
      break

proc getSelectorIds(hashes: var SelectorHashes, cxsel: ComplexSelector) =
  hashes.getSelectorIds(cxsel[^1])

proc getSelectorIds(hashes: var SelectorHashes, sel: Selector): bool =
  case sel.t
  of TYPE_SELECTOR:
    hashes.tag = sel.tag
    return true
  of CLASS_SELECTOR:
    hashes.class = sel.class
    return true
  of ID_SELECTOR:
    hashes.id = sel.id
    return true
  of ATTR_SELECTOR, PSELEM_SELECTOR, UNIVERSAL_SELECTOR:
    return false
  of PSEUDO_SELECTOR:
    if sel.pseudo.t in {PSEUDO_IS, PSEUDO_WHERE}:
      # Basically just hash whatever the selectors have in common:
      #1. get the hashable values of selector 1
      #2. for every other selector x:
      #3.   get hashable values of selector x
      #4.   store hashable values of selector x that aren't stored yet
      #5.   for every hashable value of selector 1 that doesn't match selector x
      #6.     cancel hashable value
      var cancel_tag = false
      var cancel_id = false
      var cancel_class = false
      var i = 0
      if i < sel.pseudo.fsels.len:
        hashes.getSelectorIds(sel.pseudo.fsels[i])
        inc i

      while i < sel.pseudo.fsels.len:
        var nhashes: SelectorHashes
        nhashes.getSelectorIds(sel.pseudo.fsels[i])
        if hashes.tag == CAtomNull:
          hashes.tag = nhashes.tag
        elif not cancel_tag and nhashes.tag != CAtomNull and nhashes.tag != hashes.tag:
          cancel_tag = true

        if hashes.id == "":
          hashes.id = nhashes.id
        elif not cancel_id and nhashes.id != "" and nhashes.id != hashes.id:
          cancel_id = true

        if hashes.class == "":
          hashes.class = nhashes.class
        elif not cancel_class and nhashes.class != "" and nhashes.class != hashes.class:
          cancel_class = true

        inc i

      if cancel_tag:
        hashes.tag = CAtomNull
      if cancel_id:
        hashes.id = ""
      if cancel_class:
        hashes.class = ""

      if hashes.tag != CAtomNull or hashes.id != "" or hashes.class != "":
        return true

proc ruleDefCmp(a, b: CSSRuleDef): int =
  cmp(a.idx, b.idx)

iterator genRules*(sheet: CSSStylesheet, tag: CAtom, id: string,
    classes: seq[string]): CSSRuleDef =
  var rules: seq[CSSRuleDef]
  sheet.tagTable.withValue(tag, v):
    for rule in v[]:
      rules.add(rule)
  if id != "":
    sheet.idTable.withValue(id, v):
      for rule in v[]:
        rules.add(rule)
  for class in classes:
    sheet.classTable.withValue(class, v):
      for rule in v[]:
        rules.add(rule)
  for rule in sheet.generalList:
    rules.add(rule)
  rules.sort(ruleDefCmp, order = Ascending)
  for rule in rules:
    yield rule

proc add(sheet: var CSSStylesheet, rule: CSSRuleDef) =
  var hashes: SelectorHashes
  for cxsel in rule.sels:
    hashes.getSelectorIds(cxsel)
    if hashes.tag != CAtomNull:
      sheet.tagTable.withValue(hashes.tag, p):
        p[].add(rule)
      do:
        sheet.tagTable[hashes.tag] = @[rule]
    elif hashes.id != "":
      sheet.idTable.withValue(hashes.id, p):
        p[].add(rule)
      do:
        sheet.idTable[hashes.id] = @[rule]
    elif hashes.class != "":
      sheet.classTable.withValue(hashes.class, p):
        p[].add(rule)
      do:
        sheet.classTable[hashes.class] = @[rule]
    else:
      sheet.generalList.add(rule)

proc add*(sheet: var CSSStylesheet, sheet2: CSSStylesheet) =
  sheet.generalList.add(sheet2.generalList)
  for key, value in sheet2.tagTable.pairs:
    sheet.tagTable.withValue(key, p):
      p[].add(value)
    do:
      sheet.tagTable[key] = value
  for key, value in sheet2.idTable.pairs:
    sheet.idTable.withValue(key, p):
      p[].add(value)
    do:
      sheet.idTable[key] = value
  for key, value in sheet2.classTable.pairs:
    sheet.classTable.withValue(key, p):
      p[].add(value)
    do:
      sheet.classTable[key] = value

proc addRule(stylesheet: var CSSStylesheet, rule: CSSQualifiedRule) =
  let sels = parseSelectors(rule.prelude, stylesheet.factory)
  if sels.len > 0:
    let r = CSSRuleDef(
      sels: sels,
      decls: rule.oblock.value.parseListOfDeclarations2(),
      idx: stylesheet.len
    )
    stylesheet.add(r)
    inc stylesheet.len

proc addAtRule(stylesheet: var CSSStylesheet, atrule: CSSAtRule) =
  case atrule.name
  of "media":
    if atrule.oblock == nil:
      # invalid at-rule
      return
    let query = parseMediaQueryList(atrule.prelude)
    let rules = atrule.oblock.value.parseListOfRules()
    if rules.len > 0:
      var media = CSSMediaQueryDef()
      media.children = newStylesheet(rules.len, stylesheet.factory)
      media.children.len = stylesheet.len
      media.query = query
      for rule in rules:
        if rule of CSSAtRule:
          media.children.addAtRule(CSSAtRule(rule))
        else:
          media.children.addRule(CSSQualifiedRule(rule))
      stylesheet.mqList.add(media)
      stylesheet.len = media.children.len
  else: discard #TODO

proc parseStylesheet*(s: Stream, factory: CAtomFactory): CSSStylesheet =
  let css = parseCSS(s)
  result = newStylesheet(css.value.len, factory)
  for v in css.value:
    if v of CSSAtRule: result.addAtRule(CSSAtRule(v))
    else: result.addRule(CSSQualifiedRule(v))
  s.close()

proc parseStylesheet*(s: string, factory: CAtomFactory): CSSStylesheet =
  return newStringStream(s).parseStylesheet(factory)
