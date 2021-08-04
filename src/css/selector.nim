import unicode

import ../types/enums
import ../types/tagtypes

import ./cssparser

type
  SelectorType* = enum
    TYPE_SELECTOR, ID_SELECTOR, ATTR_SELECTOR, CLASS_SELECTOR,
    UNIVERSAL_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR, FUNC_SELECTOR

  QueryMode* = enum
    QUERY_TYPE, QUERY_CLASS, QUERY_ATTR, QUERY_DELIM, QUERY_VALUE,
    QUERY_PSEUDO, QUERY_PSELEM

  SelectorParser = object
    selectors: seq[SelectorList]
    query: QueryMode
    negate: bool

  #TODO combinators
  Selector* = object
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
      pseudo*: string
    of PSELEM_SELECTOR:
      elem*: string
    of FUNC_SELECTOR:
      name*: string
      selectors*: SelectorList

  SelectorList* = ref object
    sels*: seq[Selector]
    parent*: SelectorList

proc add*(sellist: SelectorList, sel: Selector) = sellist.sels.add(sel)
proc add*(sellist: SelectorList, sels: SelectorList) = sellist.sels.add(sels.sels)
proc setLen*(sellist: SelectorList, i: int) = sellist.sels.setLen(i)
proc `[]`*(sellist: SelectorList, i: int): Selector = sellist.sels[i]
proc len*(sellist: SelectorList): int = sellist.sels.len

func getSpecificity(sel: Selector): int =
  case sel.t
  of ID_SELECTOR:
    result += 1000000
  of CLASS_SELECTOR, ATTR_SELECTOR, PSEUDO_SELECTOR:
    result += 1000
  of TYPE_SELECTOR, PSELEM_SELECTOR:
    result += 1
  of FUNC_SELECTOR:
    case sel.name
    of "is":
      var best = 0
      for child in sel.selectors.sels:
        let s = getSpecificity(child)
        if s > best:
          best = s
      result += best
    of "not":
      for child in sel.selectors.sels:
        result += getSpecificity(child)
    else: discard
  of UNIVERSAL_SELECTOR:
    discard

func getSpecificity*(sels: SelectorList): int =
  for sel in sels.sels:
    result += getSpecificity(sel)

func optimizeSelectorList*(selectors: SelectorList): SelectorList =
  new(result)
  #pass 1: check for invalid sequences
  var i = 1
  while i < selectors.len:
    let sel = selectors[i]
    if sel.t == TYPE_SELECTOR or sel.t == UNIVERSAL_SELECTOR:
      return SelectorList()
    inc i

  #pass 2: move selectors in combination
  if selectors.len > 1:
    var i = 0
    var slow = SelectorList()
    if selectors[0].t == UNIVERSAL_SELECTOR:
      inc i

    while i < selectors.len:
      if selectors[i].t in {ATTR_SELECTOR, PSEUDO_SELECTOR, PSELEM_SELECTOR}:
        slow.add(selectors[i])
      else:
        result.add(selectors[i])
      inc i

    result.add(slow)
  else:
    result.add(selectors[0])

proc parseSelectorToken(state: var SelectorParser, csstoken: CSSToken) =
  case csstoken.tokenType
  of CSS_IDENT_TOKEN:
    case state.query
    of QUERY_CLASS:
      state.selectors[^1].add(Selector(t: CLASS_SELECTOR, class: $csstoken.value))
    of QUERY_TYPE:
      state.selectors[^1].add(Selector(t: TYPE_SELECTOR, tag: tagType($csstoken.value)))
    of QUERY_PSEUDO:
      state.selectors[^1].add(Selector(t: PSEUDO_SELECTOR, pseudo: $csstoken.value))
    of QUERY_PSELEM:
      state.selectors[^1].add(Selector(t: PSELEM_SELECTOR, elem: $csstoken.value))
    else: discard
    state.query = QUERY_TYPE
  of CSS_DELIM_TOKEN:
    if csstoken.rvalue == Rune('.'):
      state.query = QUERY_CLASS
  of CSS_HASH_TOKEN:
    state.selectors[^1].add(Selector(t: ID_SELECTOR, id: $csstoken.value))
  of CSS_COMMA_TOKEN:
    if state.selectors[^1].len > 0:
      state.selectors.add(SelectorList())
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
            state.selectors[^1].add(Selector(t: ATTR_SELECTOR, attr: $csstoken.value, rel: ' '))
          of QUERY_VALUE:
            state.selectors[^1].sels[^1].value = $csstoken.value
            break
          else: discard
        of CSS_STRING_TOKEN:
          case state.query
          of QUERY_VALUE:
            state.selectors[^1].sels[^1].value = $csstoken.value
            break
          else: discard
        of CSS_DELIM_TOKEN:
          case csstoken.rvalue
          of Rune('~'), Rune('|'), Rune('^'), Rune('$'), Rune('*'):
            if state.query == QUERY_DELIM:
              state.selectors[^1].sels[^1].rel = char(csstoken.rvalue)
          of Rune('='):
            if state.query == QUERY_DELIM:
              state.query = QUERY_VALUE
          else: discard
        else: discard
    state.query = QUERY_TYPE
  else: discard

proc parseSelectorFunction(state: var SelectorParser, cssfunction: CSSFunction) =
  case $cssfunction.name
  of "not", "is":
    if state.query != QUERY_PSEUDO:
      return
    state.query = QUERY_TYPE
  else: return
  var fun = Selector(t: FUNC_SELECTOR, name: $cssfunction.name)
  fun.selectors = SelectorList(parent: state.selectors[^1])
  state.selectors[^1].add(fun)
  state.selectors[^1] = fun.selectors
  for cval in cssfunction.value:
    if cval of CSSToken:
      state.parseSelectorToken((CSSToken)cval)
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock((CSSSimpleBlock)cval)
    elif cval of CSSFunction:
      state.parseSelectorFunction((CSSFunction)cval)
  state.selectors[^1] = fun.selectors.parent

func parseSelectors*(cvals: seq[CSSComponentValue]): seq[SelectorList] =
  var state = SelectorParser()
  state.selectors.add(SelectorList())
  for cval in cvals:
    if cval of CSSToken:
      state.parseSelectorToken((CSSToken)cval)
    elif cval of CSSSimpleBlock:
      state.parseSelectorSimpleBlock((CSSSimpleBlock)cval)
    elif cval of CSSFunction:
      state.parseSelectorFunction((CSSFunction)cval)
  return state.selectors
