import streams

import css/parser
import css/selparser

type
  CSSRuleBase* = object of RootObj

  CSSRuleDef* = object of CSSRuleBase
    sels*: seq[SelectorList]
    oblock*: CSSSimpleBlock

  CSSConditionalDef* = object of CSSRuleBase
    rules*: CSSSimpleBlock
    nested*: seq[CSSConditionalDef]

  CSSMediaQueryDef = object of CSSConditionalDef
    query*: string

  CSSStylesheet* = seq[CSSRuleDef]

proc addRule(stylesheet: var CSSStylesheet, rule: CSSRule) =
  let sels = parseSelectors(rule.prelude)
  if sels.len > 1 or sels[^1].len > 0:
    let r = CSSRuleDef(sels: sels, oblock: rule.oblock)
    stylesheet.add(r)

proc parseAtRule(atrule: CSSAtRule): CSSConditionalDef =
  for v in atrule.oblock.value:
    if v of CSSRule:
      if v of CSSAtRule:
        #let atrule = CSSAtRule(v)
        discard
      else:
        discard
        #let rule = CSSRule(v)
        #let sels = parseSelectors(rule.prelude)
        #result.rules.add(CSSRule)

proc parseStylesheet*(s: Stream): CSSStylesheet =
  for v in parseCSS(s).value:
    if v of CSSAtRule:
      discard
      #result.add(CSSAtRule(v).parseAtRule())
    else:
      result.addRule(v)

proc parseStylesheet*(s: string): CSSStylesheet =
  return newStringStream(s).parseStylesheet()
