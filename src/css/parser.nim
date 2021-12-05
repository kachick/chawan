import unicode
import streams
import math
import options
import sugar

import utils/twtstr
import types/enums

type
  CSSTokenizerState = object
    at: int
    stream: Stream
    buf: seq[Rune]

  CSSParseState = object
    tokens: seq[CSSParsedItem]
    at: int
    top_level: bool

  tflaga = enum
    TFLAGA_UNRESTRICTED, TFLAGA_ID
  tflagb = enum
    TFLAGB_INTEGER, TFLAGB_NUMBER

  CSSParsedItem* = ref object of RootObj
  CSSComponentValue* = ref object of CSSParsedItem

  CSSToken* = ref object of CSSComponentValue
    case tokenType*: CSSTokenType
    of CSS_IDENT_TOKEN, CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN,
       CSS_HASH_TOKEN, CSS_STRING_TOKEN, CSS_URL_TOKEN:
      value*: seq[Rune]
      tflaga*: tflaga
    of CSS_DELIM_TOKEN:
      rvalue*: Rune
    of CSS_NUMBER_TOKEN, CSS_PERCENTAGE_TOKEN, CSS_DIMENSION_TOKEN:
      nvalue*: float64
      tflagb*: tflagb
      unit*: seq[Rune]
    else: discard

  CSSRule* = ref object of CSSParsedItem
    prelude*: seq[CSSComponentValue]
    oblock*: CSSSimpleBlock

  CSSAtRule* = ref object of CSSRule
    name*: seq[Rune]

  CSSQualifiedRule* = ref object of CSSRule

  CSSDeclaration* = ref object of CSSComponentValue
    name*: seq[Rune]
    value*: seq[CSSComponentValue]
    important*: bool

  CSSFunction* = ref object of CSSComponentValue
    name*: seq[Rune]
    value*: seq[CSSComponentValue]

  CSSSimpleBlock* = ref object of CSSComponentValue
    token*: CSSToken
    value*: seq[CSSComponentValue]

  CSSStylesheet* = object
    value*: seq[CSSRule]

  SyntaxError = object of ValueError

func `==`*(a: CSSParsedItem, b: CSSTokenType): bool =
  return a of CSSToken and CSSToken(a).tokenType == b

func isNameStartCodePoint*(r: Rune): bool =
  return not isAscii(r) or r == Rune('_') or isAlphaAscii(r)

func isNameCodePoint*(r: Rune): bool =
  return isNameStartCodePoint(r) or isDigitAscii(r) or r == Rune('-')

proc consume(state: var CSSTokenizerState): Rune =
  result = state.buf[state.at]
  inc state.at

proc reconsume(state: var CSSTokenizerState) =
  dec state.at

func peek(state: CSSTokenizerState, i: int): Rune =
  return state.buf[state.at + i]

proc has(state: var CSSTokenizerState, i: int = 0): bool =
  if state.at + i >= state.buf.len and not state.stream.atEnd():
    state.buf &= state.stream.readLine().toRunes() & Rune('\n')
  return state.at + i < state.buf.len

func curr(state: CSSTokenizerState): Rune =
  return state.buf[state.at]

proc isValidEscape*(state: var CSSTokenizerState): bool =
  return state.has(1) and state.curr() == Rune('\\') and state.peek(1) != Rune('\n')

proc startsWithIdentifier*(state: var CSSTokenizerState): bool =
  if not state.has():
    return false

  if isNameStartCodePoint(state.curr()):
    return true
  if state.curr() == Rune('-'):
    if state.has(1) and state.peek(1).isNameStartCodePoint():
      return true
    if state.isValidEscape():
      return true
    return false
  elif state.curr() == Rune('\\'):
    return state.isValidEscape()

  return false

proc startsWithNumber*(state: var CSSTokenizerState): bool =
  if state.has():
    case state.curr()
    of Rune('+'), Rune('-'):
      if state.has(1):
        if isDigitAscii(state.peek(1)):
          return true
        elif state.peek(1) == Rune('.'):
          if state.has(2) and isDigitAscii(state.peek(2)):
            return true
    of Rune('.'):
      if isDigitAscii(state.peek(1)):
        return true
    elif isDigitAscii(state.curr()):
      return true
    else:
      return false
  return false

proc consumeEscape(state: var CSSTokenizerState): Rune =
  let r = state.consume()
  var num = hexValue(r)
  if num != -1:
    var i = 0
    while state.has() and i <= 5:
      let r = state.consume()
      if hexValue(r) == -1:
        state.reconsume()
        break
      num *= 0x10
      num += hexValue(r)
      inc i
    if num == 0 or num > 0x10FFFF or num in {0xD800..0xDFFF}:
      return Rune(0xFFFD)
    else:
      return Rune(num)
  else:
    return r

proc consumeString(state: var CSSTokenizerState): CSSToken =
  var s: seq[Rune]
  state.reconsume()
  let ending = state.consume()

  while state.has():
    let r = state.consume()
    case r
    of Rune('\n'):
      return CSSToken(tokenType: CSS_BAD_STRING_TOKEN)
    of Rune('\\'):
      s &= consumeEscape(state)
    elif r == ending:
      break
    else:
      s &= r
  return CSSToken(tokenType: CSS_STRING_TOKEN, value: s)

proc consumeName(state: var CSSTokenizerState): seq[Rune] =
  while state.has():
    let r = state.consume()
    if state.isValidEscape():
      result &= state.consumeEscape()
    elif isNameCodePoint(r):
      result &= r
    else:
      state.reconsume()
      return result

proc consumeNumberSign(state: var CSSTokenizerState): CSSToken =
  if state.has():
    let r = state.consume()
    if isNameCodePoint(r) or state.isValidEscape():
      result = CSSToken(tokenType: CSS_HASH_TOKEN)
      if state.startsWithIdentifier():
        result.tflaga = TFLAGA_ID
      
      state.reconsume()
      result.value = consumeName(state)
  else:
    let r = state.consume()
    result = CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)

proc consumeNumber(state: var CSSTokenizerState): tuple[t: tflagb, val: float64] =
  var t = TFLAGB_INTEGER
  var repr: seq[Rune]
  if state.has():
    if state.curr() == Rune('+') or state.curr() == Rune('-'):
      repr &= state.consume()

  while state.has() and isDigitAscii(state.curr()):
    repr &= state.consume()

  if state.has(1):
    if state.curr() == Rune('.') and isDigitAscii(state.peek(1)):
      repr &= state.consume()
      repr &= state.consume()
      t = TFLAGB_NUMBER
      while state.has() and isDigitAscii(state.curr()):
        repr &= state.consume()

  if state.has(1):
    if state.curr() == Rune('E') or state.curr() == Rune('e'):
      var j = 2
      if state.peek(1) == Rune('-') or state.peek(1) == Rune('+'):
        inc j
      if state.has(j) and isDigitAscii(state.peek(j)):
        while j > 0:
          repr &= state.consume()
          dec j

        while state.has() and isDigitAscii(state.curr()):
          repr &= state.consume()

  let val = parseFloat64($repr)
  return (t, val)

proc consumeNumericToken(state: var CSSTokenizerState): CSSToken =
  let num = state.consumeNumber()
  if state.startsWithIdentifier():
    result = CSSToken(tokenType: CSS_DIMENSION_TOKEN, nvalue: num.val, tflagb: num.t)
    result.unit = state.consumeName()
  elif state.has() and state.curr() == Rune('%'):
    discard state.consume()
    result = CSSToken(tokenType: CSS_PERCENTAGE_TOKEN, nvalue: num.val)
  else:
    result = CSSToken(tokenType: CSS_NUMBER_TOKEN, nvalue: num.val, tflagb: num.t)

proc consumeBadURL(state: var CSSTokenizerState) =
  while state.has(1):
    let r = state.consume()
    case r
    of Rune(')'):
      return
    elif state.isValidEscape():
      discard state.consumeEscape()
    else: discard

proc consumeURL(state: var CSSTokenizerState): CSSToken =
  result = CSSToken(tokenType: CSS_URL_TOKEN)
  while state.has(1) and state.peek(1).isWhitespace():
    discard state.consume()

  while state.has(1):
    let r = state.consume()
    case r
    of Rune(')'):
      return result
    of Rune('"'), Rune('\''), Rune('('):
      state.consumeBadURL()
      return CSSToken(tokenType: CSS_BAD_URL_TOKEN)
    of Rune('\\'):
      state.reconsume()
      if state.isValidEscape():
        result.value &= state.consumeEscape()
      else:
        state.consumeBadURL()
        return CSSToken(tokenType: CSS_BAD_URL_TOKEN)
    elif r.isWhitespace():
      while state.has(1) and state.peek(1).isWhitespace():
        discard state.consume()
    else:
      result.value &= r

proc consumeIdentLikeToken(state: var CSSTokenizerState): CSSToken =
  let s = state.consumeName()
  if s.toAsciiLower() == "url" and state.has() and state.curr() == Rune('('):
    discard state.consume()
    while state.has(1) and state.curr().isWhitespace() and state.peek(1).isWhitespace():
      discard state.consume()
    if state.curr() == Rune('\'') or state.curr() == Rune('"') or state.curr().isWhitespace():
      return CSSToken(tokenType: CSS_FUNCTION_TOKEN, value: s)
    else:
      return state.consumeURL()
  elif state.has() and state.curr() == Rune('('):
    discard state.consume()
    return CSSToken(tokenType: CSS_FUNCTION_TOKEN, value: s)

  return CSSToken(tokenType: CSS_IDENT_TOKEN, value: s)

proc consumeComments(state: var CSSTokenizerState) =
  if state.has(1) and state.curr() == Rune('/') and state.peek(1) == Rune('*'):
    discard state.consume()
    discard state.consume()
    while state.has(1) and not (state.curr() == Rune('*') and state.peek(1) == Rune('/')):
      discard state.consume()

    if state.has(1):
      discard state.consume()
    if state.has():
      discard state.consume()

proc consumeToken(state: var CSSTokenizerState): CSSToken =
  state.consumeComments()
  let r = state.consume()
  case r
  of Rune('\n'), Rune('\t'), Rune(' '), Rune('\f'), Rune('\r'):
    while state.has() and state.curr().isWhitespace():
      discard state.consume()
    return CSSToken(tokenType: CSS_WHITESPACE_TOKEN)
  of Rune('"'), Rune('\''):
    return consumeString(state)
  of Rune('#'):
    return consumeNumberSign(state)
  of Rune('('):
    return CSSToken(tokenType: CSS_LPAREN_TOKEN)
  of Rune(')'):
    return CSSToken(tokenType: CSS_RPAREN_TOKEN)
  of Rune('['):
    return CSSToken(tokenType: CSS_LBRACKET_TOKEN)
  of Rune(']'):
    return CSSToken(tokenType: CSS_RBRACKET_TOKEN)
  of Rune('{'):
    return CSSToken(tokenType: CSS_LBRACE_TOKEN)
  of Rune('}'):
    return CSSToken(tokenType: CSS_RBRACE_TOKEN)
  of Rune(','):
    return CSSToken(tokenType: CSS_COMMA_TOKEN)
  of Rune(':'):
    return CSSToken(tokenType: CSS_COLON_TOKEN)
  of Rune(';'):
    return CSSToken(tokenType: CSS_SEMICOLON_TOKEN)
  of Rune('+'):
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)
  of Rune('-'):
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      if state.has(2) and state.peek(1) == Rune('-') and state.peek(2) == Rune('>'):
        discard state.consume()
        discard state.consume()
        return CSSToken(tokenType: CSS_CDC_TOKEN)
      elif state.startsWithIdentifier():
        state.reconsume()
        result = state.consumeIdentLikeToken()
      else:
        return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)
  of Rune('.'):
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)
  of Rune('<'):
    if state.has(3) and state.peek(1) == Rune('!') and state.peek(2) == Rune('-') and state.peek(3) == Rune('-'):
      discard state.consume()
      discard state.consume()
      discard state.consume()
      return CSSToken(tokenType: CSS_CDO_TOKEN)
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)
  of Rune('@'):
    if state.startsWithIdentifier():
      let name = state.consumeName()
      return CSSToken(tokenType: CSS_AT_KEYWORD_TOKEN, value: name)
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)
  elif isDigitAscii(r):
    state.reconsume()
    return state.consumeNumericToken()
  elif isNameStartCodePoint(r):
    state.reconsume()
    return state.consumeIdentLikeToken()
  else:
    return CSSToken(tokenType: CSS_DELIM_TOKEN, rvalue: r)

proc tokenizeCSS*(inputStream: Stream): seq[CSSParsedItem] =
  var state: CSSTokenizerState
  state.stream = inputStream
  state.buf = state.stream.readLine().toRunes()
  while state.has():
    result.add(state.consumeToken())

  inputStream.close()

proc consume(state: var CSSParseState): CSSParsedItem =
  result = state.tokens[state.at]
  inc state.at

proc reconsume(state: var CSSParseState) =
  dec state.at

func has(state: CSSParseState, i: int): bool =
  return state.at + i < state.tokens.len

func curr(state: CSSParseState): CSSParsedItem =
  return state.tokens[state.at]

func has(state: CSSParseState): bool =
  return state.at < state.tokens.len

proc consumeComponentValue(state: var CSSParseState): CSSComponentValue

proc consumeSimpleBlock(state: var CSSParseState): CSSSimpleBlock =
  state.reconsume()
  let t = CSSToken(state.consume())
  var ending: CSSTokenType
  case t.tokenType
  of CSS_LBRACE_TOKEN: ending = CSS_RBRACE_TOKEN
  of CSS_LPAREN_TOKEN: ending = CSS_RPAREN_TOKEN
  of CSS_LBRACKET_TOKEN: ending = CSS_RBRACKET_TOKEN
  else: raise newException(Exception, "Parse error!")
  
  result = CSSSimpleBlock(token: t)
  while state.at < state.tokens.len:
    let t = state.consume()
    if t == ending:
      return result
    else:
      if t == CSS_LBRACE_TOKEN or t == CSS_LBRACKET_TOKEN or t == CSS_LPAREN_TOKEN:
        result.value.add(state.consumeSimpleBlock())
      else:
        state.reconsume()
        result.value.add(state.consumeComponentValue())
  return result

proc consumeFunction(state: var CSSParseState): CSSFunction =
  let t = (CSSToken)state.consume()
  result = CSSFunction(name: t.value)
  while state.at < state.tokens.len:
    let t = state.consume()
    if t == CSS_RPAREN_TOKEN:
      return result
    else:
      state.reconsume()
      result.value.add(state.consumeComponentValue())

proc consumeComponentValue(state: var CSSParseState): CSSComponentValue =
  let t = state.consume()
  if t == CSS_LBRACE_TOKEN or t == CSS_LBRACKET_TOKEN or t == CSS_LPAREN_TOKEN:
    return state.consumeSimpleBlock()
  elif t == CSS_FUNCTION_TOKEN:
    state.reconsume()
    return state.consumeFunction()
  return CSSComponentValue(t)

proc consumeQualifiedRule(state: var CSSParseState): Option[CSSQualifiedRule] =
  var r = CSSQualifiedRule()
  while state.has():
    let t = state.consume()
    if t of CSSSimpleBlock:
      r.oblock = state.consumeSimpleBlock()
      return some(r)
    elif t == CSS_LBRACE_TOKEN:
      r.oblock = state.consumeSimpleBlock()
      return some(r)
    else:
      state.reconsume()
      r.prelude.add(state.consumeComponentValue())
  return none(CSSQualifiedRule)


proc consumeAtRule(state: var CSSParseState): CSSAtRule =
  let t = CSSToken(state.consume())
  result = CSSAtRule(name: t.value)

  while state.at < state.tokens.len:
    let t = state.consume()
    if t of CSSSimpleBlock:
      result.oblock = state.consumeSimpleBlock()
    elif t == CSS_SEMICOLON_TOKEN:
      return result
    elif t ==  CSS_LBRACE_TOKEN:
      result.oblock = state.consumeSimpleBlock()
      return result
    else:
      state.reconsume()
      result.prelude.add(state.consumeComponentValue())

proc consumeDeclaration(state: var CSSParseState): Option[CSSDeclaration] =
  let t = CSSToken(state.consume())
  var decl = CSSDeclaration(name: t.value)
  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has() or state.curr() != CSS_COLON_TOKEN:
    return none(CSSDeclaration)
  discard state.consume()
  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()

  while state.has():
    decl.value.add(state.consumeComponentValue())

  var i = decl.value.len - 1
  var j = 2
  var k = 0
  var l = 0
  while i >= 0 and j > 0:
    if decl.value[i] != CSS_WHITESPACE_TOKEN:
      dec j
      if decl.value[i] == CSS_IDENT_TOKEN and k == 0:
        if CSSToken(decl.value[i]).value.toAsciiLower() == "important":
          inc k
          l = i
      elif k == 1 and decl.value[i] == CSS_DELIM_TOKEN:
        if CSSToken(decl.value[i]).rvalue == Rune('!'):
          decl.important = true
          decl.value.del(l)
          decl.value.del(i)
          break
    dec i

  while decl.value.len > 0 and decl.value[^1] == CSS_WHITESPACE_TOKEN:
    decl.value.del(decl.value.len - 1)
  return some(decl)

#> Note: Despite the name, this actually parses a mixed list of declarations
#> and at-rules, as CSS 2.1 does for @page. Unexpected at-rules (which could be
#> all of them, in a given context) are invalid and should be ignored by the
#> consumer.
#Wow this is ugly.
proc consumeListOfDeclarations(state: var CSSParseState): seq[CSSParsedItem] =
  while state.has():
    let t = state.consume()
    if t == CSS_wHITESPACE_TOKEN or t == CSS_SEMICOLON_TOKEN:
      continue
    elif t == CSS_AT_KEYWORD_TOKEN:
      state.reconsume()
      result.add(state.consumeAtRule())
    elif t == CSS_IDENT_TOKEN:
      var tempList: seq[CSSParsedItem]
      tempList.add(CSSToken(t))
      while state.has() and state.curr() != CSS_SEMICOLON_TOKEN:
        tempList.add(state.consumeComponentValue())

      var tempState = CSSParseState(at: 0, tokens: tempList)
      let decl = tempState.consumeDeclaration()
      if decl.isSome:
        result.add(decl.get)
    else:
      state.reconsume()
      if state.curr() != CSS_SEMICOLON_TOKEN:
        discard state.consumeComponentValue()

proc consumeListOfRules(state: var CSSParseState): seq[CSSRule] =
  while state.at < state.tokens.len:
    let t = state.consume()
    if t == CSS_WHITESPACE_TOKEN:
      continue
    elif t == CSS_CDO_TOKEN or t == CSS_CDC_TOKEN:
      if state.top_level:
        continue
      else:
        state.reconsume()
        let q = state.consumeQualifiedRule()
        if q.isSome:
          result.add(q.get)
    elif t == CSS_AT_KEYWORD_TOKEN:
      state.reconsume()
      result.add(state.consumeAtRule())
    else:
      state.reconsume()
      let q = state.consumeQualifiedRule()
      if q.isSome:
        result.add(q.get)

proc parseStylesheet(state: var CSSParseState): CSSStylesheet =
  state.top_level = true
  result.value.add(state.consumeListOfRules())

proc parseStylesheet(inputStream: Stream): CSSStylesheet =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseStylesheet()

proc parseListOfRules(state: var CSSParseState): seq[CSSRule] =
  return state.consumeListOfRules()

proc parseListOfRules(inputStream: Stream): seq[CSSRule] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfRules()

proc parseRule(state: var CSSParseState): CSSRule =
  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has():
    raise newException(SyntaxError, "EOF reached!")

  if state.curr() == CSS_AT_KEYWORD_TOKEN:
    result = state.consumeAtRule()
  else:
    let q = state.consumeQualifiedRule()
    if q.isSome:
      result = q.get
    else:
      raise newException(SyntaxError, "No qualified rule found!")

  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if state.has():
    raise newException(SyntaxError, "EOF not reached!")

proc parseRule(inputStream: Stream): CSSRule =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseRule()

proc parseDeclaration(state: var CSSParseState): CSSDeclaration =
  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()

  if not state.has() or state.curr() != CSS_IDENT_TOKEN:
    raise newException(SyntaxError, "No ident token found!")

  let d = state.consumeDeclaration()
  if d.isSome:
    return d.get

  raise newException(SyntaxError, "No declaration found!")

proc parseCSSDeclaration*(inputStream: Stream): CSSDeclaration =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseDeclaration()

proc parseListOfDeclarations(state: var CSSParseState): seq[CSSParsedItem] =
  return state.consumeListOfDeclarations()

proc parseCSSListOfDeclarations*(cvals: seq[CSSComponentValue]): seq[CSSParsedItem] =
  var state = CSSParseState()
  state.tokens = collect(newSeq):
    for cval in cvals:
      CSSParsedItem(cval)
  return state.consumeListOfDeclarations()

proc parseCSSListOfDeclarations*(inputStream: Stream): seq[CSSParsedItem] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfDeclarations()

proc parseComponentValue(state: var CSSParseState): CSSComponentValue =
  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has():
    raise newException(SyntaxError, "EOF reached!")

  result = state.consumeComponentValue()

  while state.has() and state.curr() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if state.has():
    raise newException(SyntaxError, "EOF not reached!")

proc parseCSSComponentValue*(inputStream: Stream): CSSComponentValue =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseComponentValue()

proc parseListOfComponentValues(state: var CSSParseState): seq[CSSComponentValue] =
  while state.has():
    result.add(state.consumeComponentValue())

proc parseCSSListOfComponentValues*(inputStream: Stream): seq[CSSComponentValue] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfComponentValues()

proc parseCommaSeparatedListOfComponentValues(state: var CSSParseState): seq[CSSComponentValue] =
  while state.has(1):
    let cvl = state.consumeComponentValue()
    if cvl != CSS_COMMA_TOKEN:
      result.add(state.consumeComponentValue())

proc parseCommaSeparatedListOfComponentValues(inputStream: Stream): seq[CSSComponentValue] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseCommaSeparatedListOfComponentValues()

func `$`*(c: CSSComponentValue): string =
  if c of CSSToken:
    case CSSToken(c).tokenType:
    of CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN, CSS_URL_TOKEN:
      result &= $CSSToken(c).tokenType & $CSSToken(c).value & '\n'
    of CSS_HASH_TOKEN:
      result &= '#' & $CSSToken(c).value
    of CSS_IDENT_TOKEN:
      result &= $CSSToken(c).value
    of CSS_STRING_TOKEN:
      result &= ("\"" & $CSSToken(c).value & "\"")
    of CSS_DELIM_TOKEN:
      result &= $CSSToken(c).rvalue
    of CSS_DIMENSION_TOKEN:
      result &= $CSSToken(c).tokenType & $CSSToken(c).nvalue & "unit" & $CSSToken(c).unit & $CSSToken(c).tflagb
    of CSS_NUMBER_TOKEN:
      result &= $CSSToken(c).nvalue & $CSSToken(c).unit
    of CSS_PERCENTAGE_TOKEN:
      result &= $CSSToken(c).nvalue & "%"
    of CSS_COLON_TOKEN:
      result &= ":"
    of CSS_WHITESPACE_TOKEN:
      result &= " "
    of CSS_SEMICOLON_TOKEN:
      result &= ";\n"
    of CSS_COMMA_TOKEN:
      result &= ","
    else:
      result &= $CSSToken(c).tokenType & '\n'
  elif c of CSSDeclaration:
    result &= $CSSDeclaration(c).name
    result &= ": "
    for s in CSSDeclaration(c).value:
      result &= $s
    result &= ";\n"
  elif c of CSSFunction:
    result &= $CSSFunction(c).name & "("
    for s in CSSFunction(c).value:
      result &= $s
    result &= ")"
  elif c of CSSSimpleBlock:
    case CSSSimpleBlock(c).token.tokenType
    of CSS_LBRACE_TOKEN: result &= "{\n"
    of CSS_LPAREN_TOKEN: result &= "("
    of CSS_LBRACKET_TOKEN: result &= "["
    else: discard
    for s in CSSSimpleBlock(c).value:
      result &= $s
    case CSSSimpleBlock(c).token.tokenType
    of CSS_LBRACE_TOKEN: result &= "\n}"
    of CSS_LPAREN_TOKEN: result &= ")"
    of CSS_LBRACKET_TOKEN: result &= "]"
    else: discard

proc parseCSS*(inputStream: Stream): CSSStylesheet =
  if inputStream.atEnd():
    return CSSStylesheet()
  return inputstream.parseStylesheet()

proc debugparseCSS*(inputStream: Stream) =
  let ss = inputStream.parseStylesheet()
  for v in ss.value:
    if v of CSSAtRule:
      eprint CSSAtRule(v).name
    else:
      for c in CSSQualifiedRule(v).prelude:
        eprint c
    case v.oblock.token.tokenType
    of CSS_LBRACE_TOKEN: eprint "\n{"
    of CSS_LPAREN_TOKEN: eprint "("
    of CSS_LBRACKET_TOKEN: eprint "["
    else: discard
    for s in v.oblock.value:
      eprint s
    case v.oblock.token.tokenType
    of CSS_LBRACE_TOKEN: eprint "\n}"
    of CSS_LPAREN_TOKEN: eprint ")"
    of CSS_LBRACKET_TOKEN: eprint "]"
    else: discard
