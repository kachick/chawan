import options
import streams
import strutils

import css/cssparser
import utils/twtstr

import chame/tags

type
  SelectorType* = enum
    TYPE_SELECTOR, UNKNOWN_TYPE_SELECTOR, ID_SELECTOR, ATTR_SELECTOR,
    CLASS_SELECTOR, UNIVERSAL_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR

  PseudoElem* = enum
    PSEUDO_NONE, PSEUDO_BEFORE, PSEUDO_AFTER,
    # internal
    PSEUDO_INPUT_TEXT, PSEUDO_TEXTAREA_TEXT, PSEUDO_IMAGE, PSEUDO_NEWLINE

  PseudoClass* = enum
    PSEUDO_FIRST_CHILD, PSEUDO_LAST_CHILD, PSEUDO_ONLY_CHILD, PSEUDO_HOVER,
    PSEUDO_ROOT, PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD, PSEUDO_CHECKED,
    PSEUDO_FOCUS, PSEUDO_IS, PSEUDO_NOT, PSEUDO_WHERE, PSEUDO_LANG,
    PSEUDO_LINK, PSEUDO_VISITED

  CombinatorType* = enum
    NO_COMBINATOR, DESCENDANT_COMBINATOR, CHILD_COMBINATOR,
    NEXT_SIBLING_COMBINATOR, SUBSEQ_SIBLING_COMBINATOR

  SelectorParser = object
    selectors: seq[ComplexSelector]
    cvals: seq[CSSComponentValue]
    at: int
    failed: bool

  RelationType* = enum
    RELATION_EXISTS, RELATION_EQUALS, RELATION_TOKEN, RELATION_BEGIN_DASH,
    RELATION_STARTS_WITH, RELATION_ENDS_WITH, RELATION_CONTAINS

  Selector* = ref object # Simple selector
    case t*: SelectorType
    of TYPE_SELECTOR:
      tag*: TagType
    of UNKNOWN_TYPE_SELECTOR:
      tagstr*: string
    of ID_SELECTOR:
      id*: string
    of ATTR_SELECTOR:
      attr*: string
      value*: string
      rel*: RelationType
    of CLASS_SELECTOR:
      class*: string
    of UNIVERSAL_SELECTOR: #TODO namespaces?
      discard
    of PSEUDO_SELECTOR:
      pseudo*: PseudoData
    of PSELEM_SELECTOR:
      elem*: PseudoElem

  PseudoData* = object
    case t*: PseudoClass
    of PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD:
      anb*: CSSAnB
      ofsels*: SelectorList
    of PSEUDO_IS, PSEUDO_WHERE, PSEUDO_NOT:
      fsels*: SelectorList
    of PSEUDO_LANG:
      s*: string
    else: discard

  CompoundSelector* = object
    ct*: CombinatorType # relation to the next entry in a ComplexSelector.
    sels*: seq[Selector]

  ComplexSelector* = seq[CompoundSelector]

  SelectorList* = seq[ComplexSelector]

iterator items*(sels: CompoundSelector): Selector {.inline.} =
  for it in sels.sels:
    yield it

func `[]`*(sels: CompoundSelector, i: int): Selector {.inline.} =
  return sels.sels[i]

func `[]`*(sels: CompoundSelector, i: BackwardsIndex): Selector {.inline.} =
  return sels.sels[i]

func len*(sels: CompoundSelector): int {.inline.} =
  return sels.sels.len

proc add*(sels: var CompoundSelector, sel: Selector) {.inline.} =
  sels.sels.add(sel)

# For debugging
func tostr(ftype: enum): string =
  return ($ftype).split('_')[1..^1].join('-').toLowerAscii()

func `$`*(cxsel: ComplexSelector): string

func `$`*(sel: Selector): string =
  case sel.t
  of TYPE_SELECTOR:
    return tagName(sel.tag)
  of UNKNOWN_TYPE_SELECTOR:
    return sel.tagstr
  of ID_SELECTOR:
    return '#' & sel.id
  of ATTR_SELECTOR:
    let rel = case sel.rel
    of RELATION_EXISTS: ""
    of RELATION_EQUALS: "="
    of RELATION_TOKEN: "~="
    of RELATION_BEGIN_DASH: "|="
    of RELATION_STARTS_WITH: "^="
    of RELATION_ENDS_WITH: "$="
    of RELATION_CONTAINS: "*="
    return '[' & sel.attr & rel & sel.value & ']'
  of CLASS_SELECTOR:
    return '.' & sel.class
  of UNIVERSAL_SELECTOR:
    return "*"
  of PSEUDO_SELECTOR:
    result = ':' & sel.pseudo.t.tostr()
    case sel.pseudo.t
    of PSEUDO_IS, PSEUDO_NOT, PSEUDO_WHERE:
      result &= '('
      for fsel in sel.pseudo.fsels:
        result &= $fsel
        if fsel != sel.pseudo.fsels[^1]:
          result &= ", "
      result &= ')'
    of PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD:
      result &= '(' & $sel.pseudo.anb.A & 'n' & $sel.pseudo.anb.B
      if sel.pseudo.ofsels.len != 0:
        result &= " of "
        for fsel in sel.pseudo.ofsels:
          result &= $fsel
          if fsel != sel.pseudo.ofsels[^1]:
            result &= ','
      result &= ')'
    else: discard
  of PSELEM_SELECTOR:
    return "::" & sel.elem.tostr()

func `$`*(sels: CompoundSelector): string =
  for sel in sels:
    result &= $sel

func `$`*(cxsel: ComplexSelector): string =
  for sels in cxsel:
    result &= $sels
    case sels.ct
    of DESCENDANT_COMBINATOR: result &= ' '
    of CHILD_COMBINATOR: result &= " > "
    of NEXT_SIBLING_COMBINATOR: result &= " + "
    of SUBSEQ_SIBLING_COMBINATOR: result &= " ~ "
    of NO_COMBINATOR: discard

func `$`*(slist: SelectorList): string =
  var s = false
  for cxsel in slist:
    if s:
      result &= ", "
    result &= $cxsel
    s = true

func getSpecificity*(cxsel: ComplexSelector): int

func getSpecificity(sel: Selector): int =
  case sel.t
  of ID_SELECTOR:
    result += 1000000
  of CLASS_SELECTOR, ATTR_SELECTOR:
    result += 1000
  of PSEUDO_SELECTOR:
    case sel.pseudo.t
    of PSEUDO_IS, PSEUDO_NOT:
      var best = 0
      for child in sel.pseudo.fsels:
        let s = getSpecificity(child)
        if s > best:
          best = s
      result += best
    of PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD:
      if sel.pseudo.ofsels.len != 0:
        var best = 0
        for child in sel.pseudo.ofsels:
          let s = getSpecificity(child)
          if s > best:
            best = s
        result += best
      result += 1000
    of PSEUDO_WHERE: discard
    else: result += 1000
  of TYPE_SELECTOR, UNKNOWN_TYPE_SELECTOR, PSELEM_SELECTOR:
    result += 1
  of UNIVERSAL_SELECTOR:
    discard

func getSpecificity*(sels: CompoundSelector): int =
  for sel in sels:
    result += getSpecificity(sel)

func getSpecificity*(cxsel: ComplexSelector): int =
  for sels in cxsel:
    result += getSpecificity(sels)

func pseudo*(cxsel: ComplexSelector): PseudoElem =
  if cxsel[^1][^1].t == PSELEM_SELECTOR:
    return cxsel[^1][^1].elem
  return PSEUDO_NONE

proc consume(state: var SelectorParser): CSSComponentValue =
  result = state.cvals[state.at]
  inc state.at

proc has(state: var SelectorParser, i = 0): bool =
  return not state.failed and state.at + i < state.cvals.len

proc peek(state: var SelectorParser, i = 0): CSSComponentValue =
  return state.cvals[state.at + i]

template fail() =
  state.failed = true
  return

template get_tok(cval: CSSComponentValue): CSSToken =
  let c = cval
  if not (c of CSSToken): fail
  CSSToken(c)

proc parseSelectorList(cvals: seq[CSSComponentValue]): SelectorList

# Functions that may contain other selectors, functions, etc.
proc parseRecursiveSelectorFunction(state: var SelectorParser, class: PseudoClass, body: seq[CSSComponentValue]): Selector =
  var fun = Selector(
    t: PSEUDO_SELECTOR,
    pseudo: PseudoData(t: class),
  )
  fun.pseudo.fsels = parseSelectorList(body)
  if fun.pseudo.fsels.len == 0: fail
  return fun

proc parseNthChild(state: var SelectorParser, cssfunction: CSSFunction, data: PseudoData): Selector =
  var data = data
  var (anb, i) = parseAnB(cssfunction.value)
  if anb.isNone: fail
  data.anb = anb.get
  var nthchild = Selector(t: PSEUDO_SELECTOR, pseudo: data)
  while i < cssfunction.value.len and cssfunction.value[i] == CSS_WHITESPACE_TOKEN:
    inc i
  if i >= cssfunction.value.len:
    return nthchild
  if not (get_tok cssfunction.value[i]).value.equalsIgnoreCase("of"): fail
  if i == cssfunction.value.len: fail
  nthchild.pseudo.ofsels = parseSelectorList(cssfunction.value[i..^1])
  if nthchild.pseudo.ofsels.len == 0: fail
  return nthchild

proc skipWhitespace(state: var SelectorParser) =
  while state.has() and state.peek() of CSSToken and
      CSSToken(state.peek()).tokenType == CSS_WHITESPACE_TOKEN:
    inc state.at

proc parseLang(cvals: seq[CSSComponentValue]): Selector =
  var state = SelectorParser(cvals: cvals)
  state.skipWhitespace()
  if not state.has(): fail
  let tok = get_tok state.consume()
  if tok.tokenType != CSS_IDENT_TOKEN: fail
  return Selector(t: PSEUDO_SELECTOR, pseudo: PseudoData(t: PSEUDO_LANG, s: tok.value))

proc parseSelectorFunction(state: var SelectorParser, cssfunction: CSSFunction): Selector =
  return case cssfunction.name.toLowerAscii()
  of "not":
    state.parseRecursiveSelectorFunction(PSEUDO_NOT, cssfunction.value)
  of "is":
    state.parseRecursiveSelectorFunction(PSEUDO_IS, cssfunction.value)
  of "where":
    state.parseRecursiveSelectorFunction(PSEUDO_WHERE, cssfunction.value)
  of "nth-child":
    state.parseNthChild(cssfunction, PseudoData(t: PSEUDO_NTH_CHILD))
  of "nth-last-child":
    state.parseNthChild(cssfunction, PseudoData(t: PSEUDO_NTH_LAST_CHILD))
  of "lang":
    parseLang(cssfunction.value)
  else: fail

proc parsePseudoSelector(state: var SelectorParser): Selector =
  if not state.has(): fail
  let cval = state.consume()
  if cval of CSSToken:
    template add_pseudo_element(element: PseudoElem) =
      return Selector(t: PSELEM_SELECTOR, elem: element)
    let tok = CSSToken(cval)
    case tok.tokenType
    of CSS_IDENT_TOKEN:
      template add_pseudo_class(class: PseudoClass) =
        return Selector(t: PSEUDO_SELECTOR, pseudo: PseudoData(t: class))
      case tok.value.toLowerAscii()
      of "before": add_pseudo_element PSEUDO_BEFORE
      of "after": add_pseudo_element PSEUDO_AFTER
      of "first-child": add_pseudo_class PSEUDO_FIRST_CHILD
      of "last-child": add_pseudo_class PSEUDO_LAST_CHILD
      of "only-child": add_pseudo_class PSEUDO_ONLY_CHILD
      of "hover": add_pseudo_class PSEUDO_HOVER
      of "root": add_pseudo_class PSEUDO_ROOT
      of "checked": add_pseudo_class PSEUDO_CHECKED
      of "focus": add_pseudo_class PSEUDO_FOCUS
      of "link": add_pseudo_class PSEUDO_LINK
      of "visited": add_pseudo_class PSEUDO_VISITED
      else: fail
    of CSS_COLON_TOKEN:
      if not state.has(): fail
      let tok = get_tok state.consume()
      if tok.tokenType != CSS_IDENT_TOKEN: fail
      case tok.value.toLowerAscii()
      of "before": add_pseudo_element PSEUDO_BEFORE
      of "after": add_pseudo_element PSEUDO_AFTER
      else: fail
    else: fail
  elif cval of CSSFunction:
    return state.parseSelectorFunction(CSSFunction(cval))
  else: fail

proc parseComplexSelector(state: var SelectorParser): ComplexSelector

proc parseAttributeSelector(state: var SelectorParser,
    cssblock: CSSSimpleBlock): Selector =
  if cssblock.token.tokenType != CSS_LBRACKET_TOKEN: fail
  var state2 = SelectorParser(cvals: cssblock.value)
  state2.skipWhitespace()
  if not state2.has(): fail
  let attr = get_tok state2.consume()
  if attr.tokenType != CSS_IDENT_TOKEN: fail
  state2.skipWhitespace()
  if not state2.has():
    return Selector(t: ATTR_SELECTOR, attr: attr.value, rel: RELATION_EXISTS)
  let delim0 = get_tok state2.consume()
  if delim0.tokenType != CSS_DELIM_TOKEN: fail
  let rel = case delim0.cvalue
  of '~': RELATION_TOKEN
  of '|': RELATION_BEGIN_DASH
  of '^': RELATION_STARTS_WITH
  of '$': RELATION_ENDS_WITH
  of '*': RELATION_CONTAINS
  of '=': RELATION_EQUALS
  else: fail
  if rel != RELATION_EQUALS:
    let delim1 = get_tok state2.consume()
    if delim1.tokenType != CSS_DELIM_TOKEN or delim1.cvalue != '=': fail
  state2.skipWhitespace()
  if not state2.has(): fail
  let value = get_tok state2.consume()
  if value.tokenType notin {CSS_IDENT_TOKEN, CSS_STRING_TOKEN}: fail
  return Selector(
    t: ATTR_SELECTOR,
    attr: attr.value,
    value: value.value,
    rel: rel
  )

proc parseClassSelector(state: var SelectorParser): Selector =
  if not state.has(): fail
  let tok = get_tok state.consume()
  if tok.tokenType != CSS_IDENT_TOKEN: fail
  return Selector(t: CLASS_SELECTOR, class: tok.value)

proc parseCompoundSelector(state: var SelectorParser): CompoundSelector =
  while state.has():
    let cval = state.peek()
    if cval of CSSToken:
      let tok = CSSToken(cval)
      case tok.tokenType
      of CSS_IDENT_TOKEN:
        inc state.at
        let s = tok.value.toLowerAscii()
        let tag = tagType(s)
        if tag == TAG_UNKNOWN:
          result.add(Selector(t: UNKNOWN_TYPE_SELECTOR, tagstr: s))
        else:
          result.add(Selector(t: TYPE_SELECTOR, tag: tag))
      of CSS_COLON_TOKEN:
        inc state.at
        result.add(state.parsePseudoSelector())
      of CSS_HASH_TOKEN:
        inc state.at
        result.add(Selector(t: ID_SELECTOR, id: tok.value))
      of CSS_COMMA_TOKEN: break
      of CSS_DELIM_TOKEN:
        case tok.cvalue
        of '.':
          inc state.at
          result.add(state.parseClassSelector())
        of '*':
          inc state.at
          result.add(Selector(t: UNIVERSAL_SELECTOR))
        of '>', '+', '~': break
        else: fail
      of CSS_WHITESPACE_TOKEN:
        # skip trailing whitespace
        if not state.has(1) or state.peek(1) == CSS_COMMA_TOKEN:
          inc state.at
        elif state.peek(1) == CSS_DELIM_TOKEN:
          let tok = CSSToken(state.peek(1))
          if tok.cvalue in {'>', '+', '~'}:
            inc state.at
        break
      else: fail
    elif cval of CSSSimpleBlock:
      inc state.at
      result.add(state.parseAttributeSelector(CSSSimpleBlock(cval)))
    else:
      fail

proc parseComplexSelector(state: var SelectorParser): ComplexSelector =
  while true:
    state.skipWhitespace()
    let sels = state.parseCompoundSelector()
    result.add(sels)
    if sels.len == 0: fail
    if not state.has():
      break # finish
    let tok = get_tok state.consume()
    case tok.tokenType
    of CSS_DELIM_TOKEN:
      case tok.cvalue
      of '>': result[^1].ct = CHILD_COMBINATOR
      of '+': result[^1].ct = NEXT_SIBLING_COMBINATOR
      of '~': result[^1].ct = SUBSEQ_SIBLING_COMBINATOR
      else: fail
    of CSS_WHITESPACE_TOKEN:
      result[^1].ct = DESCENDANT_COMBINATOR
    of CSS_COMMA_TOKEN:
      break # finish
    else: fail
  if result.len == 0 or result[^1].ct != NO_COMBINATOR:
    fail

proc parseSelectorList(cvals: seq[CSSComponentValue]): SelectorList =
  var state = SelectorParser(cvals: cvals)
  var res: SelectorList
  while state.has():
    res.add(state.parseComplexSelector())
  if not state.failed:
    return res

func parseSelectors*(cvals: seq[CSSComponentValue]): seq[ComplexSelector] = {.cast(noSideEffect).}:
  return parseSelectorList(cvals)

proc parseSelectors*(stream: Stream): seq[ComplexSelector] =
  return parseSelectors(parseListOfComponentValues(stream))
