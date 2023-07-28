import streams
import tables

import css/mediaquery
import css/cssparser
import css/selectorparser
import html/tags

type
  CSSRuleBase* = ref object of RootObj

  CSSRuleDef* = ref object of CSSRuleBase
    sels*: SelectorList
    decls*: seq[CSSDeclaration]

  CSSConditionalDef* = ref object of CSSRuleBase
    children*: CSSStylesheet

  CSSMediaQueryDef* = ref object of CSSConditionalDef
    query*: MediaQueryList

  CSSStylesheet* = ref object
    mq_list*: seq[CSSMediaQueryDef]
    tag_table*: array[TagType, seq[CSSRuleDef]]
    id_table*: Table[string, seq[CSSRuleDef]]
    class_table*: Table[string, seq[CSSRuleDef]]
    general_list*: seq[CSSRuleDef]
    len*: int

type SelectorHashes = object
  tag: TagType
  id: string
  class: string

func newStylesheet*(cap: int): CSSStylesheet =
  new(result)
  let bucketsize = cap div 2
  result.id_table = initTable[string, seq[CSSRuleDef]](bucketsize)
  result.class_table = initTable[string, seq[CSSRuleDef]](bucketsize)
  result.general_list = newSeqOfCap[CSSRuleDef](bucketsize)

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
  of ATTR_SELECTOR, PSELEM_SELECTOR, UNIVERSAL_SELECTOR, UNKNOWN_TYPE_SELECTOR:
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
        if hashes.tag == TAG_UNKNOWN:
          hashes.tag = nhashes.tag
        elif not cancel_tag and nhashes.tag != TAG_UNKNOWN and nhashes.tag != hashes.tag:
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
        hashes.tag = TAG_UNKNOWN
      if cancel_id:
        hashes.id = ""
      if cancel_class:
        hashes.class = ""

      if hashes.tag != TAG_UNKNOWN or hashes.id != "" or hashes.class != "":
        return true

iterator gen_rules*(sheet: CSSStylesheet, tag: TagType, id: string, classes: seq[string]): CSSRuleDef =
  for rule in sheet.tag_table[tag]:
    yield rule
  if id != "":
    sheet.id_table.withValue(id, v):
      for rule in v[]:
        yield rule
  for class in classes:
    sheet.class_table.withValue(class, v):
      for rule in v[]:
        yield rule
  for rule in sheet.general_list:
    yield rule

proc add(sheet: var CSSStylesheet, rule: CSSRuleDef) =
  var hashes: SelectorHashes
  for cxsel in rule.sels:
    hashes.getSelectorIds(cxsel)
    if hashes.tag != TAG_UNKNOWN:
      sheet.tag_table[hashes.tag].add(rule)
    elif hashes.id != "":
      if hashes.id notin sheet.id_table:
        sheet.id_table[hashes.id] = newSeq[CSSRuleDef]()
      sheet.id_table[hashes.id].add(rule)
    elif hashes.class != "":
      if hashes.class notin sheet.class_table:
        sheet.class_table[hashes.class] = newSeq[CSSRuleDef]()
      sheet.class_table[hashes.class].add(rule)
    else:
      sheet.general_list.add(rule)

proc add*(sheet: var CSSStylesheet, rule: CSSRuleBase) {.inline.} =
  if rule of CSSRuleDef:
    sheet.add(CSSRuleDef(rule))
  else:
    sheet.mq_list.add(CSSMediaQueryDef(rule))
  inc sheet.len

proc add*(sheet: var CSSStylesheet, sheet2: CSSStylesheet) {.inline.} =
  sheet.general_list.add(sheet2.general_list)
  for tag in TagType:
    sheet.tag_table[tag].add(sheet2.tag_table[tag])
  for key, value in sheet2.id_table.pairs:
    if key notin sheet.id_table:
      sheet.id_table[key] = newSeq[CSSRuleDef]()
    sheet.id_table[key].add(value)
  for key, value in sheet2.class_table.pairs:
    if key notin sheet.class_table:
      sheet.class_table[key] = newSeq[CSSRuleDef]()
    sheet.class_table[key].add(value)
  sheet.len += sheet2.len

proc getDeclarations(rule: CSSQualifiedRule): seq[CSSDeclaration] {.inline.} =
  rule.oblock.value.parseListOfDeclarations2()

proc addRule(stylesheet: var CSSStylesheet, rule: CSSQualifiedRule) =
  let sels = parseSelectors(rule.prelude)
  if sels.len > 0:
    let r = CSSRuleDef(sels: sels, decls: rule.getDeclarations())
    stylesheet.add(r)

proc addAtRule(stylesheet: var CSSStylesheet, atrule: CSSAtRule) =
  case atrule.name
  of "media":
    let query = parseMediaQueryList(atrule.prelude)
    let rules = atrule.oblock.value.parseListOfRules()
    if rules.len > 0:
      var media = CSSMediaQueryDef()
      media.children = newStylesheet(rules.len)
      media.query = query
      for rule in rules:
        if rule of CSSAtRule:
          media.children.addAtRule(CSSAtRule(rule))
        else:
          media.children.addRule(CSSQualifiedRule(rule))
      stylesheet.add(media)
  else: discard #TODO

proc parseStylesheet*(s: Stream): CSSStylesheet =
  let css = parseCSS(s)
  result = newStylesheet(css.value.len)
  for v in css.value:
    if v of CSSAtRule: result.addAtRule(CSSAtRule(v))
    else: result.addRule(CSSQualifiedRule(v))
  s.close()

proc parseStylesheet*(s: string): CSSStylesheet =
  return newStringStream(s).parseStylesheet()
