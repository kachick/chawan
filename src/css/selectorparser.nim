import options
import streams
import strutils
import unicode

import css/cssparser
import html/tags

type
  SelectorType* = enum
    TYPE_SELECTOR, ID_SELECTOR, ATTR_SELECTOR, CLASS_SELECTOR,
    UNIVERSAL_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR, COMBINATOR_SELECTOR

  QueryMode = enum
    QUERY_TYPE, QUERY_CLASS, QUERY_ATTR, QUERY_DELIM, QUERY_VALUE,
    QUERY_PSEUDO, QUERY_PSELEM, QUERY_DESC_COMBINATOR, QUERY_CHILD_COMBINATOR,
    QUERY_NEXT_SIBLING_COMBINATOR, QUERY_SUBSEQ_SIBLING_COMBINATOR

  PseudoElem* = enum
    PSEUDO_NONE, PSEUDO_BEFORE, PSEUDO_AFTER,
    # internal
    PSEUDO_INPUT_TEXT, PSEUDO_TEXTAREA_TEXT

  PseudoClass* = enum
    PSEUDO_FIRST_CHILD, PSEUDO_LAST_CHILD, PSEUDO_ONLY_CHILD, PSEUDO_HOVER,
    PSEUDO_ROOT, PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD, PSEUDO_CHECKED,
    PSEUDO_FOCUS, PSEUDO_IS, PSEUDO_NOT, PSEUDO_WHERE

  CombinatorType* = enum
    DESCENDANT_COMBINATOR, CHILD_COMBINATOR, NEXT_SIBLING_COMBINATOR,
    SUBSEQ_SIBLING_COMBINATOR

  SelectorParser = object
    selectors: seq[ComplexSelector]
    query: QueryMode
    combinator: Selector

  Selector* = ref object of RootObj # compound selector
    case t*: SelectorType
    of TYPE_SELECTOR:
      tag*: TagType
    of ID_SELECTOR:
      id*: string
    of ATTR_SELECTOR:
      attr*: string
      value*: string
      rel*: char
    of CLASS_SELECTOR:
      class*: string
    of UNIVERSAL_SELECTOR: #TODO namespaces?
      discard
    of PSEUDO_SELECTOR:
      pseudo*: PseudoData
    of PSELEM_SELECTOR:
      elem*: PseudoElem
    of COMBINATOR_SELECTOR:
      ct*: CombinatorType
      csels*: SelectorList

  PseudoData* = object
    case t*: PseudoClass
    of PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD:
      anb*: CSSAnB
      ofsels*: Option[SelectorList]
    of PSEUDO_IS, PSEUDO_WHERE, PSEUDO_NOT:
      fsels*: SelectorList
    else: discard

  # Kind of an oversimplification, but the distinction between complex and
  # compound selectors isn't too significant.
  ComplexSelector* = seq[Selector]

  SelectorList* = seq[ComplexSelector]

# For debugging
proc tostr(ftype: enum): string =
  return ($ftype).split('_')[1..^1].join("-").tolower()

proc `$`*(sellist: ComplexSelector): string

proc `$`*(sel: Selector): string =
  case sel.t
  of TYPE_SELECTOR:
    return tagName(sel.tag)
  of ID_SELECTOR:
    return '#' & sel.id
  of ATTR_SELECTOR:
    return '[' & sel.attr & sel.rel & sel.value & ']'
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
          result &= ','
      result &= ')'
    of PSEUDO_NTH_CHILD, PSEUDO_NTH_LAST_CHILD:
      result &= '(' & $sel.pseudo.anb.A & 'n' & $sel.pseudo.anb.B
      if sel.pseudo.ofsels.issome:
        result &= " of "
        for fsel in sel.pseudo.ofsels.get:
          result &= $fsel
          if fsel != sel.pseudo.ofsels.get[^1]:
            result &= ','
      result &= ')'
    else: discard
  of PSELEM_SELECTOR:
    return "::" & sel.elem.tostr()
  of COMBINATOR_SELECTOR:
    var delim: char
    case sel.ct
    of DESCENDANT_COMBINATOR: delim = ' '
    of CHILD_COMBINATOR: delim = '>'
    of NEXT_SIBLING_COMBINATOR: delim = '+'
    of SUBSEQ_SIBLING_COMBINATOR: delim = '~'
    for slist in sel.csels:
      result &= $slist
      if slist != sel.csels[^1]:
        result &= delim

proc `$`*(sellist: ComplexSelector): string =
  for sel in sellist:
    result &= $sel

func getSpecificity*(sels: ComplexSelector): int

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
      if sel.pseudo.ofsels.issome:
        var best = 0
        for child in sel.pseudo.ofsels.get:
          let s = getSpecificity(child)
          if s > best:
            best = s
        result += best
      result += 1000
    of PSEUDO_WHERE: discard
    else: result += 1000
  of TYPE_SELECTOR, PSELEM_SELECTOR:
    result += 1
  of UNIVERSAL_SELECTOR:
    discard
  of COMBINATOR_SELECTOR:
    for child in sel.csels:
      result += getSpecificity(child)

func getSpecificity*(sels: ComplexSelector): int =
  for sel in sels:
    result += getSpecificity(sel)

func pseudo*(sels: ComplexSelector): PseudoElem =
  if sels.len > 0 and sels[^1].t == PSELEM_SELECTOR:
    return sels[^1].elem
  return PSEUDO_NONE

proc addSelector(state: var SelectorParser, sel: Selector) =
  if state.combinator != nil:
    state.combinator.csels[^1].add(sel)
  else:
    state.selectors[^1].add(sel)

proc getLastSel(state: SelectorParser): Selector =
  if state.combinator != nil:
    return state.combinator.csels[^1][^1]
  else:
    return state.selectors[^1][^1]

proc addComplexSelector(state: var SelectorParser) =
  if state.combinator != nil:
    state.selectors[^1].add(state.combinator)
    state.combinator = nil
  state.selectors.add(newSeq[Selector]())

func getComplexSelectors(state: var SelectorParser): seq[ComplexSelector] =
  result = state.selectors
  if state.combinator != nil:
    result[^1].add(state.combinator)

proc parseSelectorCombinator(state: var SelectorParser, ct: CombinatorType, csstoken: CSSToken) =
  if csstoken.tokenType notin {CSS_IDENT_TOKEN, CSS_HASH_TOKEN, CSS_COLON_TOKEN} and
     (csstoken.tokenType != CSS_DELIM_TOKEN or csstoken.rvalue != Rune('.')):
    return
  if state.combinator != nil and state.combinator.ct != ct:
    let nc = Selector(t: COMBINATOR_SELECTOR, ct: ct)
    nc.csels.add(@[state.combinator])
    state.combinator = nc

  if state.combinator == nil:
    state.combinator = Selector(t: COMBINATOR_SELECTOR, ct: ct)

  state.combinator.csels.add(state.selectors[^1])
  if state.combinator.csels[^1].len > 0:
    state.combinator.csels.add(newSeq[Selector]())
  state.selectors[^1].setLen(0)
  state.query = QUERY_TYPE

proc parseSelectorToken(state: var SelectorParser, csstoken: CSSToken) =
  case state.query
  of QUERY_DESC_COMBINATOR:
    state.parseSelectorCombinator(DESCENDANT_COMBINATOR, csstoken)
  of QUERY_CHILD_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(CHILD_COMBINATOR, csstoken)
  of QUERY_NEXT_SIBLING_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(NEXT_SIBLING_COMBINATOR, csstoken)
  of QUERY_SUBSEQ_SIBLING_COMBINATOR:
    if csstoken.tokenType == CSS_WHITESPACE_TOKEN:
      return
    state.parseSelectorCombinator(SUBSEQ_SIBLING_COMBINATOR, csstoken)
  else: discard

  template add_pseudo_element(element: PseudoElem) =
    state.addSelector(Selector(t: PSELEM_SELECTOR, elem: element))
  case csstoken.tokenType
  of CSS_IDENT_TOKEN:
    case state.query
    of QUERY_CLASS:
      state.addSelector(Selector(t: CLASS_SELECTOR, class: csstoken.value))
    of QUERY_TYPE:
      state.addSelector(Selector(t: TYPE_SELECTOR, tag: tagType(csstoken.value)))
    of QUERY_PSEUDO:
      template add_pseudo_class(class: PseudoClass) =
        state.addSelector(Selector(t: PSEUDO_SELECTOR, pseudo: PseudoData(t: class)))
      case csstoken.value
      of "before":
        add_pseudo_element PSEUDO_BEFORE
      of "after":
        add_pseudo_element PSEUDO_AFTER
      of "first-child":
        add_pseudo_class PSEUDO_FIRST_CHILD
      of "last-child":
        add_pseudo_class PSEUDO_LAST_CHILD
      of "only-child":
        add_pseudo_class PSEUDO_ONLY_CHILD
      of "hover":
        add_pseudo_class PSEUDO_HOVER
      of "root":
        add_pseudo_class PSEUDO_ROOT
      of "checked":
        add_pseudo_class PSEUDO_CHECKED
      of "focus":
        add_pseudo_class PSEUDO_FOCUS
    of QUERY_PSELEM:
      case csstoken.value
      of "before":
        add_pseudo_element PSEUDO_BEFORE
      of "after":
        add_pseudo_element PSEUDO_AFTER
      else: discard
    else: discard
    state.query = QUERY_TYPE
  of CSS_DELIM_TOKEN:
    case csstoken.rvalue
    of Rune('.'):
      state.query = QUERY_CLASS
    of Rune('>'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_CHILD_COMBINATOR
    of Rune('+'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_NEXT_SIBLING_COMBINATOR
    of Rune('~'):
      if state.selectors[^1].len > 0 or state.combinator != nil:
        state.query = QUERY_SUBSEQ_SIBLING_COMBINATOR
    of Rune('*'):
      state.addSelector(Selector(t: UNIVERSAL_SELECTOR))
    else: discard
  of CSS_HASH_TOKEN:
    state.addSelector(Selector(t: ID_SELECTOR, id: csstoken.value))
  of CSS_COMMA_TOKEN:
    if state.selectors[^1].len > 0:
      state.addComplexSelector()
  of CSS_WHITESPACE_TOKEN:
    if state.selectors[^1].len > 0 or state.combinator != nil:
      state.query = QUERY_DESC_COMBINATOR
  of CSS_COLON_TOKEN:
    if state.query == QUERY_PSEUDO:
      state.query = QUERY_PSELEM
    else:
      state.query = QUERY_PSEUDO
  else: discard

proc parseSelectorSimpleBlock(state: var SelectorParser, cssblock: CSSSimpleBlock) =
  case cssblock.token.tokenType
  of CSS_LBRACKET_TOKEN:
    state.query = QUERY_ATTR
    for cval in cssblock.value:
      if cval of CSSToken:
        let csstoken = (CSSToken)cval
        case csstoken.tokenType
        of CSS_IDENT_TOKEN:
          case state.query
          of QUERY_ATTR:
            state.query = QUERY_DELIM
            state.addSelector(Selector(t: ATTR_SELECTOR, attr: csstoken.value, rel: ' '))
          of QUERY_VALUE:
            state.getLastSel().value = csstoken.value
            break
          else: discard
        of CSS_STRING_TOKEN:
          case state.query
          of QUERY_VALUE:
            state.getLastSel().value = csstoken.value
            break
          else: discard
        of CSS_DELIM_TOKEN:
          case csstoken.rvalue
          of Rune('~'), Rune('|'), Rune('^'), Rune('$'), Rune('*'):
            if state.query == QUERY_DELIM:
              state.getLastSel().rel = char(csstoken.rvalue)
          of Rune('='):
            if state.query == QUERY_DELIM:
              if state.getLastSel().rel == ' ':
                state.getLastSel().rel = '='
              state.query = QUERY_VALUE
          else: discard
        else: discard
    state.query = QUERY_TYPE
  else: discard

proc parseSelectorFunction(state: var SelectorParser, cssfunction: CSSFunction)

proc parseSelectorFunctionBody(state: var SelectorParser, body: seq[CSSComponentValue]): seq[ComplexSelector] =
  let osels = state.selectors
  let ocomb = state.combinator
  state.combinator = nil
  state.selectors = newSeq[ComplexSelector]()
  state.addComplexSelector()
  for cval in body:
    if cval of CSSToken:
      state.parseSelectorToken(CSSToken(cval))
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock(CSSSimpleBlock(cval))
    elif cval of CSSFunction:
      state.parseSelectorFunction(CSSFunction(cval))
  result = state.getComplexSelectors()
  state.selectors = osels
  state.combinator = ocomb

proc parseNthChild(state: var SelectorParser, cssfunction: CSSFunction, data: PseudoData) =
  var data = data
  let (anb, i) = parseAnB(cssfunction.value)
  if anb.issome:
    data.anb = anb.get
    var nthchild = Selector(t: PSEUDO_SELECTOR, pseudo: data)
    var i = i
    while i < cssfunction.value.len and cssfunction.value[i] == CSS_WHITESPACE_TOKEN:
      inc i
    if i >= cssfunction.value.len:
      state.addSelector(nthchild)
    else:
      if cssfunction.value[i] == CSS_IDENT_TOKEN and CSSToken(cssfunction.value[i]).value == "of":
        if i < cssfunction.value.len:
          let body = cssfunction.value[i..^1]
          let val = state.parseSelectorFunctionBody(body)
          if val.len > 0:
            nthchild.pseudo.ofsels = some(val)
            state.addSelector(nthchild)
  state.query = QUERY_TYPE

proc parseSelectorFunction(state: var SelectorParser, cssfunction: CSSFunction) =
  if state.query != QUERY_PSEUDO:
    return
  let ftype = case cssfunction.name
  of "not": PSEUDO_NOT
  of "is": PSEUDO_IS
  of "where": PSEUDO_WHERE
  of "nth-child":
    state.parseNthChild(cssfunction, PseudoData(t: PSEUDO_NTH_CHILD))
    return
  of "nth-last-child":
    state.parseNthChild(cssfunction, PseudoData(t: PSEUDO_NTH_LAST_CHILD))
    return
  else: return
  state.query = QUERY_TYPE
  var data = PseudoData(t: ftype)
  var fun = Selector(t: PSEUDO_SELECTOR, pseudo: data)
  state.addSelector(fun)
  fun.pseudo.fsels = state.parseSelectorFunctionBody(cssfunction.value)

func parseSelectors*(cvals: seq[CSSComponentValue]): seq[ComplexSelector] = {.cast(noSideEffect).}:
  var state = SelectorParser()
  state.addComplexSelector()
  for cval in cvals:
    if cval of CSSToken:
      state.parseSelectorToken(CSSToken(cval))
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock(CSSSimpleBlock(cval))
    elif cval of CSSFunction:
      state.parseSelectorFunction(CSSFunction(cval))
  if state.combinator != nil:
    if state.combinator.csels.len == 1:
      if state.combinator.ct == DESCENDANT_COMBINATOR:
        # otherwise it's an invalid combinator
        state.selectors[^1].add(state.combinator.csels[0])
    else:
      state.selectors[^1].add(state.combinator)
    state.combinator = nil
  return state.selectors

proc parseSelectors*(stream: Stream): seq[ComplexSelector] =
  return parseSelectors(parseListOfComponentValues(stream))
