import options
import streams
import unicode

import js/domexception
import types/opt
import utils/twtstr

type
  CSSTokenType* = enum
    CSS_NO_TOKEN, CSS_IDENT_TOKEN, CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN,
    CSS_HASH_TOKEN, CSS_STRING_TOKEN, CSS_BAD_STRING_TOKEN, CSS_URL_TOKEN,
    CSS_BAD_URL_TOKEN, CSS_DELIM_TOKEN, CSS_NUMBER_TOKEN, CSS_PERCENTAGE_TOKEN,
    CSS_DIMENSION_TOKEN, CSS_WHITESPACE_TOKEN, CSS_CDO_TOKEN, CSS_CDC_TOKEN,
    CSS_COLON_TOKEN, CSS_SEMICOLON_TOKEN, CSS_COMMA_TOKEN, CSS_RBRACKET_TOKEN,
    CSS_LBRACKET_TOKEN, CSS_LPAREN_TOKEN, CSS_RPAREN_TOKEN, CSS_LBRACE_TOKEN,
    CSS_RBRACE_TOKEN

  CSSTokenizerState = object
    at: int
    stream: Stream
    buf: string
    curr: char

  CSSParseState = object
    tokens: seq[CSSParsedItem]
    at: int

  tflaga* = enum
    TFLAGA_UNRESTRICTED, TFLAGA_ID
  tflagb* = enum
    TFLAGB_INTEGER, TFLAGB_NUMBER

  CSSParsedItem* = ref object of RootObj
  CSSComponentValue* = ref object of CSSParsedItem

  CSSToken* = ref object of CSSComponentValue
    case tokenType*: CSSTokenType
    of CSS_IDENT_TOKEN, CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN,
       CSS_HASH_TOKEN, CSS_STRING_TOKEN, CSS_URL_TOKEN:
      value*: string
      tflaga*: tflaga
    of CSS_DELIM_TOKEN:
      cvalue*: char
    of CSS_NUMBER_TOKEN, CSS_PERCENTAGE_TOKEN, CSS_DIMENSION_TOKEN:
      nvalue*: float64
      tflagb*: tflagb
      unit*: string
    else: discard

  CSSRule* = ref object of CSSParsedItem
    prelude*: seq[CSSComponentValue]
    oblock*: CSSSimpleBlock

  CSSAtRule* = ref object of CSSRule
    name*: string

  CSSQualifiedRule* = ref object of CSSRule

  CSSDeclaration* = ref object of CSSComponentValue
    name*: string
    value*: seq[CSSComponentValue]
    important*: bool

  CSSFunction* = ref object of CSSComponentValue
    name*: string
    value*: seq[CSSComponentValue]

  CSSSimpleBlock* = ref object of CSSComponentValue
    token*: CSSToken
    value*: seq[CSSComponentValue]

  CSSRawStylesheet* = object
    value*: seq[CSSRule]

  CSSAnB* = tuple[A, B: int]

# For debugging
proc `$`*(c: CSSParsedItem): string =
  if c of CSSToken:
    let c = CSSToken(c)
    case c.tokenType:
    of CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN:
      result &= $c.tokenType & c.value & '\n'
    of CSS_URL_TOKEN:
      result &= "url(" & c.value & ")"
    of CSS_HASH_TOKEN:
      result &= '#' & c.value
    of CSS_IDENT_TOKEN:
      result &= c.value
    of CSS_STRING_TOKEN:
      result &= ("\"" & c.value & "\"")
    of CSS_DELIM_TOKEN:
      if c.cvalue != char(128):
        result &= c.cvalue
      else:
        result &= "<UNICODE>"
    of CSS_DIMENSION_TOKEN:
      case c.tflagb
      of TFLAGB_NUMBER:
        result &= $c.nvalue & c.unit
      of TFLAGB_INTEGER:
        result &= $int64(c.nvalue) & c.unit
    of CSS_NUMBER_TOKEN:
      result &= $c.nvalue & c.unit
    of CSS_PERCENTAGE_TOKEN:
      result &= $c.nvalue & "%"
    of CSS_COLON_TOKEN:
      result &= ":"
    of CSS_WHITESPACE_TOKEN:
      result &= " "
    of CSS_SEMICOLON_TOKEN:
      result &= ";\n"
    of CSS_COMMA_TOKEN:
      result &= ","
    else:
      result &= $c.tokenType & '\n'
  elif c of CSSDeclaration:
    let decl = CSSDeclaration(c)
    result &= decl.name
    result &= ": "
    for s in decl.value:
      result &= $s
    if decl.important:
      result &= " !important"
    result &= ";\n"
  elif c of CSSFunction:
    result &= CSSFunction(c).name & "("
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
  elif c of CSSRule:
    if c of CSSAtRule:
      result &= CSSAtRule(c).name & " "
    result &= $CSSRule(c).prelude & "\n"
    result &= $CSSRule(c).oblock

func `==`*(a: CSSParsedItem, b: CSSTokenType): bool =
  return a of CSSToken and CSSToken(a).tokenType == b

const IdentStart = AsciiAlpha + NonAscii + {'_'}
const Ident = IdentStart + AsciiDigit + {'-'}

proc consume(state: var CSSTokenizerState): char =
  state.curr = state.buf[state.at]
  inc state.at
  return state.curr

proc consumeRChar(state: var CSSTokenizerState): char =
  var r: Rune
  fastRuneAt(state.buf, state.at, r)
  if r.isAscii():
    return cast[char](r)
  return char(128)

proc reconsume(state: var CSSTokenizerState) =
  dec state.at

func peek(state: CSSTokenizerState, i: int = 0): char =
  return state.buf[state.at + i]

proc has(state: var CSSTokenizerState, i: int = 0): bool =
  if state.at + i >= state.buf.len and not state.stream.atEnd():
    try:
      state.buf &= state.stream.readStr(256)
    except EOFError:
      return false
  return state.at + i < state.buf.len

proc isValidEscape(a, b: char): bool =
  return a == '\\' and b != '\n'

proc isValidEscape(state: var CSSTokenizerState): bool =
  return state.has() and isValidEscape(state.curr, state.peek())

# current + next + next(1)
proc startsWithIdentSequence(state: var CSSTokenizerState): bool =
  case state.curr
  of '-':
    return state.has() and state.peek() in IdentStart + {'-'} or state.has(1) and state.isValidEscape()
  of IdentStart:
    return true
  of '\\':
    return state.isValidEscape()
  else:
    return false

# next, next(1), next(2)
proc next3startsWithIdentSequence(state: var CSSTokenizerState): bool =
  if not state.has():
    return false

  case state.peek()
  of '-':
    return state.has(1) and state.peek(1) in IdentStart + {'-'} or
      state.has(2) and isValidEscape(state.peek(1), state.peek(2))
  of IdentStart:
    return true
  of '\\':
    return state.has(1) and isValidEscape(state.peek(), state.peek(1))
  else:
    return false

proc startsWithNumber(state: var CSSTokenizerState): bool =
  if state.has():
    case state.peek()
    of '+', '-':
      if state.has(1):
        if state.peek(1) in AsciiDigit:
          return true
        elif state.peek(1) == '.':
          if state.has(2) and state.peek(2) in AsciiDigit:
            return true
    of '.':
      if state.has(1) and state.peek(1) in AsciiDigit:
        return true
    elif state.peek() in AsciiDigit:
      return true
    else:
      return false
  return false

proc consumeEscape(state: var CSSTokenizerState): string =
  if not state.has():
    return $Rune(0xFFFD)
  let c = state.consume()
  if c in AsciiHexDigit:
    var num = hexValue(c)
    var i = 0
    while i <= 5 and state.has():
      let c = state.consume()
      if hexValue(c) == -1:
        state.reconsume()
        break
      num *= 0x10
      num += hexValue(c)
      inc i
    if state.peek() in AsciiWhitespace:
      discard state.consume()
    if num == 0 or num > 0x10FFFF or num in 0xD800..0xDFFF:
      return $Rune(0xFFFD)
    else:
      return $Rune(num)
  else:
    return $c #NOTE this assumes the caller doesn't care about non-ascii

proc consumeString(state: var CSSTokenizerState): CSSToken =
  var s: string
  let ending = state.curr

  while state.has():
    let c = state.consume()
    case c
    of '\n':
      state.reconsume()
      return CSSToken(tokenType: CSS_BAD_STRING_TOKEN)
    of '\\':
      if not state.has():
        continue
      elif state.peek() == '\n':
        discard state.consume()
      else:
        s &= consumeEscape(state)
    elif c == ending:
      break
    else:
      s &= c
  return CSSToken(tokenType: CSS_STRING_TOKEN, value: s)

proc consumeIdentSequence(state: var CSSTokenizerState): string =
  while state.has():
    let c = state.consume()
    if state.isValidEscape():
      result &= state.consumeEscape()
    elif c in Ident:
      result &= c
    else:
      state.reconsume()
      return result

proc consumeNumber(state: var CSSTokenizerState): (tflagb, float64) =
  var t = TFLAGB_INTEGER
  var repr: string
  if state.has() and state.peek() in {'+', '-'}:
    repr &= state.consume()

  while state.has() and state.peek() in AsciiDigit:
    repr &= state.consume()

  if state.has(1) and state.peek() == '.' and state.peek(1) in AsciiDigit:
    repr &= state.consume()
    repr &= state.consume()
    t = TFLAGB_NUMBER
    while state.has() and state.peek() in AsciiDigit:
      repr &= state.consume()

  if state.has(1) and state.peek() in {'E', 'e'} and state.peek(1) in AsciiDigit or
      state.has(2) and state.peek() in {'E', 'e'} and state.peek(1) in {'-', '+'} and state.peek(2) in AsciiDigit:
    repr &= state.consume()
    if state.peek() in {'-', '+'}:
      repr &= state.consume()
      repr &= state.consume()
    else:
      repr &= state.consume()
    t = TFLAGB_NUMBER
    while state.has() and state.peek() in AsciiDigit:
      repr &= state.consume()

  let val = parseFloat64($repr)
  return (t, val)

proc consumeNumericToken(state: var CSSTokenizerState): CSSToken =
  let (t, val) = state.consumeNumber()
  if state.next3startsWithIdentSequence():
    result = CSSToken(tokenType: CSS_DIMENSION_TOKEN, nvalue: val, tflagb: t)
    result.unit = state.consumeIdentSequence()
  elif state.has() and state.peek() == '%':
    discard state.consume()
    result = CSSToken(tokenType: CSS_PERCENTAGE_TOKEN, nvalue: val)
  else:
    result = CSSToken(tokenType: CSS_NUMBER_TOKEN, nvalue: val, tflagb: t)

proc consumeBadURL(state: var CSSTokenizerState) =
  while state.has():
    let c = state.consume()
    case c
    of ')':
      return
    elif state.isValidEscape():
      discard state.consumeEscape()
    else: discard

const NonPrintable = {char(0x00)..char(0x08), char(0x0B), char(0x0E)..char(0x1F), char(0x7F)}

proc consumeURL(state: var CSSTokenizerState): CSSToken =
  result = CSSToken(tokenType: CSS_URL_TOKEN)
  while state.has() and state.peek() in AsciiWhitespace:
    discard state.consume()

  while state.has():
    let c = state.consume()
    case c
    of ')':
      return result
    of '"', '\'', '(', NonPrintable:
      state.consumeBadURL()
      return CSSToken(tokenType: CSS_BAD_URL_TOKEN)
    of AsciiWhitespace:
      while state.has() and state.peek() in AsciiWhitespace:
        discard state.consume()
      if not state.has():
        return result
      if state.peek() == ')':
        discard state.consume()
        return result
      state.consumeBadURL()
      return CSSToken(tokenType: CSS_BAD_URL_TOKEN)
    of '\\':
      state.reconsume()
      if state.isValidEscape():
        result.value &= state.consumeEscape()
      else:
        state.consumeBadURL()
        return CSSToken(tokenType: CSS_BAD_URL_TOKEN)
    else:
      result.value &= c

proc consumeIdentLikeToken(state: var CSSTokenizerState): CSSToken =
  let s = state.consumeIdentSequence()
  if s.equalsIgnoreCase("url") and state.has() and state.peek() == '(':
    discard state.consume()
    while state.has(1) and state.peek() in AsciiWhitespace and
        state.peek(1) in AsciiWhitespace:
      discard state.consume()
    if state.has() and state.peek() in {'"', '\''} or
        state.has(1) and state.peek() in {'"', '\''} + AsciiWhitespace and state.peek(1) in {'"', '\''}:
      return CSSToken(tokenType: CSS_FUNCTION_TOKEN, value: s)
    else:
      return state.consumeURL()
  elif state.has() and state.peek() == '(':
    discard state.consume()
    return CSSToken(tokenType: CSS_FUNCTION_TOKEN, value: s)

  return CSSToken(tokenType: CSS_IDENT_TOKEN, value: s)

proc consumeComments(state: var CSSTokenizerState) =
  if state.has(1) and state.peek() == '/' and state.peek(1) == '*':
    discard state.consume()
    discard state.consume()
    while state.has() and not (state.has(1) and state.peek() == '*' and state.peek(1) == '/'):
      discard state.consume()
    if state.has(1):
      discard state.consume()
    if state.has():
      discard state.consume()

proc consumeToken(state: var CSSTokenizerState): CSSToken =
  state.consumeComments()
  if not state.has():
    return
  let c = state.consume()
  case c
  of AsciiWhitespace:
    while state.has() and state.peek() in AsciiWhitespace:
      discard state.consume()
    return CSSToken(tokenType: CSS_WHITESPACE_TOKEN)
  of '"', '\'':
    return consumeString(state)
  of '#':
    if state.has() and state.peek() in Ident or state.isValidEscape():
      result = CSSToken(tokenType: CSS_HASH_TOKEN)
      if state.startsWithIdentSequence():
        result.tflaga = TFLAGA_ID
      result.value = consumeIdentSequence(state)
    else:
      state.reconsume()
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: state.consumeRChar())
  of '(': return CSSToken(tokenType: CSS_LPAREN_TOKEN)
  of ')': return CSSToken(tokenType: CSS_RPAREN_TOKEN)
  of '{': return CSSToken(tokenType: CSS_LBRACE_TOKEN)
  of '}': return CSSToken(tokenType: CSS_RBRACE_TOKEN)
  of '+':
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of ',': return CSSToken(tokenType: CSS_COMMA_TOKEN)
  of '-':
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      if state.has(1) and state.peek() == '-' and state.peek(1) == '>':
        discard state.consume()
        discard state.consume()
        return CSSToken(tokenType: CSS_CDC_TOKEN)
      elif state.startsWithIdentSequence():
        state.reconsume()
        return state.consumeIdentLikeToken()
      else:
        return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of '.':
    if state.startsWithNumber():
      state.reconsume()
      return state.consumeNumericToken()
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of ':': return CSSToken(tokenType: CSS_COLON_TOKEN)
  of ';': return CSSToken(tokenType: CSS_SEMICOLON_TOKEN)
  of '<':
    if state.has(2) and state.peek() == '!' and state.peek(1) == '-' and state.peek(2) == '-':
      discard state.consume()
      discard state.consume()
      discard state.consume()
      return CSSToken(tokenType: CSS_CDO_TOKEN)
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of '@':
    if state.next3startsWithIdentSequence():
      let name = state.consumeIdentSequence()
      return CSSToken(tokenType: CSS_AT_KEYWORD_TOKEN, value: name)
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of '[': return CSSToken(tokenType: CSS_LBRACKET_TOKEN)
  of '\\':
    if state.isValidEscape():
      state.reconsume()
      return state.consumeIdentLikeToken()
    else:
      return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: c)
  of ']': return CSSToken(tokenType: CSS_RBRACKET_TOKEN)
  of AsciiDigit:
    state.reconsume()
    return state.consumeNumericToken()
  of IdentStart:
    state.reconsume()
    return state.consumeIdentLikeToken()
  else:
    state.reconsume()
    return CSSToken(tokenType: CSS_DELIM_TOKEN, cvalue: state.consumeRChar())

proc tokenizeCSS*(inputStream: Stream): seq[CSSParsedItem] =
  var state: CSSTokenizerState
  state.stream = inputStream
  try:
    state.buf = state.stream.readStr(256)
  except EOFError:
    discard
  while state.has():
    let tok = state.consumeToken()
    if tok != nil:
      result.add(tok)

  inputStream.close()

proc consume(state: var CSSParseState): CSSParsedItem =
  result = state.tokens[state.at]
  inc state.at

proc reconsume(state: var CSSParseState) =
  dec state.at

func has(state: CSSParseState, i: int = 0): bool =
  return state.at + i < state.tokens.len

func peek(state: CSSParseState): CSSParsedItem =
  return state.tokens[state.at]

proc consumeComponentValue(state: var CSSParseState): CSSComponentValue

proc consumeSimpleBlock(state: var CSSParseState): CSSSimpleBlock =
  state.reconsume()
  let t = CSSToken(state.consume())
  var ending: CSSTokenType
  case t.tokenType
  of CSS_LBRACE_TOKEN: ending = CSS_RBRACE_TOKEN
  of CSS_LPAREN_TOKEN: ending = CSS_RPAREN_TOKEN
  of CSS_LBRACKET_TOKEN: ending = CSS_RBRACKET_TOKEN
  else: doAssert false

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
    if t of CSSSimpleBlock and CSSSimpleBlock(t).token == CSS_LBRACE_TOKEN:
      r.oblock = CSSSimpleBlock(t)
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
      result.oblock = CSSSimpleBlock(t)
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
  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has() or state.peek() != CSS_COLON_TOKEN:
    return none(CSSDeclaration)
  discard state.consume()
  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
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
        if CSSToken(decl.value[i]).value.equalsIgnoreCase("important"):
          inc k
          l = i
      elif k == 1 and decl.value[i] == CSS_DELIM_TOKEN:
        if CSSToken(decl.value[i]).cvalue == '!':
          decl.important = true
          decl.value.delete(l)
          decl.value.delete(i)
          break
    dec i

  while decl.value.len > 0 and decl.value[^1] == CSS_WHITESPACE_TOKEN:
    decl.value.setLen(decl.value.len - 1)
  return some(decl)

#> Note: Despite the name, this actually parses a mixed list of declarations
#> and at-rules, as CSS 2.1 does for @page. Unexpected at-rules (which could be
#> all of them, in a given context) are invalid and should be ignored by the
#> consumer.
#So we have two versions, one with at rules and one without.
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
      while state.has() and state.peek() != CSS_SEMICOLON_TOKEN:
        tempList.add(state.consumeComponentValue())

      var tempState = CSSParseState(at: 0, tokens: tempList)
      let decl = tempState.consumeDeclaration()
      if decl.isSome:
        result.add(decl.get)
    else:
      state.reconsume()
      if state.peek() != CSS_SEMICOLON_TOKEN:
        discard state.consumeComponentValue()

proc consumeListOfDeclarations2(state: var CSSParseState): seq[CSSDeclaration] =
  while state.has():
    let t = state.consume()
    if t == CSS_wHITESPACE_TOKEN or t == CSS_SEMICOLON_TOKEN:
      continue
    elif t == CSS_AT_KEYWORD_TOKEN:
      state.reconsume()
      discard state.consumeAtRule()
    elif t == CSS_IDENT_TOKEN:
      var tempList: seq[CSSParsedItem]
      let tok = CSSToken(t)
      tempList.add(tok)
      while state.has() and state.peek() != CSS_SEMICOLON_TOKEN:
        tempList.add(state.consumeComponentValue())

      var tempState = CSSParseState(at: 0, tokens: tempList)
      let decl = tempState.consumeDeclaration()
      if decl.isSome:
        result.add(decl.get)
    else:
      state.reconsume()
      if state.peek() != CSS_SEMICOLON_TOKEN:
        discard state.consumeComponentValue()

proc consumeListOfRules(state: var CSSParseState, topLevel = false): seq[CSSRule] =
  while state.at < state.tokens.len:
    let t = state.consume()
    if t == CSS_WHITESPACE_TOKEN:
      continue
    elif t == CSS_CDO_TOKEN or t == CSS_CDC_TOKEN:
      if topLevel:
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

proc parseStylesheet(state: var CSSParseState): CSSRawStylesheet =
  result.value.add(state.consumeListOfRules(true))

proc parseStylesheet(inputStream: Stream): CSSRawStylesheet =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  inputStream.close()
  return state.parseStylesheet()

proc parseListOfRules(state: var CSSParseState): seq[CSSRule] =
  return state.consumeListOfRules()

proc parseListOfRules*(cvals: seq[CSSComponentValue]): seq[CSSRule] =
  var state = CSSParseState()
  state.tokens = cast[seq[CSSParsedItem]](cvals)
  return state.parseListOfRules()

proc parseRule(state: var CSSParseState): DOMResult[CSSRule] =
  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has():
    return err(newDOMException("Unexpected EOF", "SyntaxError"))

  var res: CSSRule
  if state.peek() == CSS_AT_KEYWORD_TOKEN:
    res = state.consumeAtRule()
  else:
    let q = state.consumeQualifiedRule()
    if q.isSome:
      res = q.get
    else:
      return err(newDOMException("No qualified rule found!", "SyntaxError"))

  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if state.has():
    return err(newDOMException("EOF not reached", "SyntaxError"))
  return ok(res)

proc parseRule*(inputStream: Stream): DOMResult[CSSRule] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseRule()

proc parseDeclaration(state: var CSSParseState): DOMResult[CSSDeclaration] =
  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()

  if not state.has() or state.peek() != CSS_IDENT_TOKEN:
    return err(newDOMException("No ident token found", "SyntaxError"))

  let d = state.consumeDeclaration()
  if d.isSome:
    return ok(d.get)

  return err(newDOMException("No declaration found", "SyntaxError"))

proc parseDeclaration*(inputStream: Stream): DOMResult[CSSDeclaration] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseDeclaration()

proc parseListOfDeclarations(state: var CSSParseState): seq[CSSParsedItem] =
  return state.consumeListOfDeclarations()

proc parseListOfDeclarations*(cvals: seq[CSSComponentValue]): seq[CSSParsedItem] =
  var state: CSSParseState
  state.tokens = cast[seq[CSSParsedItem]](cvals)
  return state.consumeListOfDeclarations()

proc parseListOfDeclarations*(inputStream: Stream): seq[CSSParsedItem] =
  var state: CSSParseState
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfDeclarations()

proc parseListOfDeclarations2(state: var CSSParseState): seq[CSSDeclaration] =
  return state.consumeListOfDeclarations2()

proc parseListOfDeclarations2*(cvals: seq[CSSComponentValue]): seq[CSSDeclaration] =
  var state: CSSParseState
  state.tokens = cast[seq[CSSParsedItem]](cvals)
  return state.consumeListOfDeclarations2()

proc parseListOfDeclarations2*(inputStream: Stream): seq[CSSDeclaration] =
  var state: CSSParseState
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfDeclarations2()

proc parseComponentValue(state: var CSSParseState):
    DOMResult[CSSComponentValue] =
  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if not state.has():
    return err(newDOMException("Unexpected EOF", "SyntaxError"))

  let res = state.consumeComponentValue()

  while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
    discard state.consume()
  if state.has():
    return err(newDOMException("EOF not reached", "SyntaxError"))
  return ok(res)

proc parseComponentValue*(inputStream: Stream): DOMResult[CSSComponentValue] =
  var state: CSSParseState
  state.tokens = tokenizeCSS(inputStream)
  return state.parseComponentValue()

proc parseListOfComponentValues(state: var CSSParseState): seq[CSSComponentValue] =
  while state.has():
    result.add(state.consumeComponentValue())

proc parseListOfComponentValues*(inputStream: Stream): seq[CSSComponentValue] =
  var state = CSSParseState()
  state.tokens = tokenizeCSS(inputStream)
  return state.parseListOfComponentValues()

proc parseCommaSeparatedListOfComponentValues(state: var CSSParseState): seq[seq[CSSComponentValue]] =
  if state.has():
    result.add(newSeq[CSSComponentValue]())

  while state.has():
    let cvl = state.consumeComponentValue()
    if cvl != CSS_COMMA_TOKEN:
      result[^1].add(cvl)
    else:
      result.add(newSeq[CSSComponentValue]())

proc parseCommaSeparatedListOfComponentValues*(cvals: seq[CSSComponentValue]): seq[seq[CSSComponentValue]] =
  var state: CSSParseState
  state.tokens = cast[seq[CSSParsedItem]](cvals)
  return state.parseCommaSeparatedListOfComponentValues()

proc parseAnB*(state: var CSSParseState): Option[CSSAnB] =
  template is_eof: bool =
    not state.has() or not (state.peek() of CSSToken)
  template fail_eof =
    if is_eof:
      return none(CSSAnB)
  template skip_whitespace =
    while state.has() and state.peek() == CSS_WHITESPACE_TOKEN:
      discard state.consume()
  template get_plus: bool =
    let tok = state.peek()
    if tok == CSS_DELIM_TOKEN and CSSToken(tok).cvalue == '+':
      discard state.consume()
      true
    else:
      false
  template get_tok: CSSToken =
    fail_eof
    skip_whitespace
    CSSToken(state.consume())
  template get_tok_nows: CSSToken =
    fail_eof
    CSSToken(state.consume())
  template fail_plus =
    if is_plus:
      return none(CSSAnB)
  template parse_sub_int(sub: string, skip: int): int =
    let s = sub.substr(skip)
    let x = parseInt32(s)
    if x.isNone:
      return none(CSSAnB)
    x.get
  template fail_non_integer(tok: CSSToken, res: Option[CSSAnB]) =
    if tok.tokenType != CSS_NUMBER_TOKEN:
      state.reconsume()
      return res
    if tok.tflagb != TFLAGB_INTEGER:
      state.reconsume()
      return res
    if int64(tok.nvalue) > high(int):
      state.reconsume()
      return res
  template fail_non_signless_integer(tok: CSSToken, res: Option[CSSAnB]) =
    fail_non_integer tok, res #TODO check if signless?

  fail_eof
  skip_whitespace
  fail_eof
  let is_plus = get_plus
  let tok = get_tok_nows
  case tok.tokenType
  of CSS_IDENT_TOKEN:
    case tok.value
    of "odd":
      fail_plus
      return some((2, 1))
    of "even":
      fail_plus
      return some((2, 0))
    of "n", "N":
      if is_eof:
        return some((1, 0))
      let tok2 = get_tok
      if tok2.tokenType == CSS_DELIM_TOKEN:
        let sign = case tok2.cvalue
        of '+': 1
        of '-': -1
        else: return none(CSSAnB)
        let tok3 = get_tok
        fail_non_signless_integer tok3, some((1, 0))
        return some((1, sign * int(tok3.nvalue)))
      else:
        fail_non_integer tok2, some((1, 0))
        return some((1, int(tok2.nvalue)))
    of "-n", "-N":
      fail_plus
      if is_eof:
        return some((-1, 0))
      let tok2 = get_tok
      if tok2.tokenType == CSS_DELIM_TOKEN:
        let sign = case tok2.cvalue
        of '+': 1
        of '-': -1
        else: return none(CSSAnB)
        let tok3 = get_tok
        fail_non_signless_integer tok3, some((-1, 0))
        return some((-1, sign * int(tok3.nvalue)))
      else:
        fail_non_integer tok2, some((-1, 0))
        return some((-1, int(tok2.nvalue)))
    of "n-", "N-":
      let tok2 = get_tok
      fail_non_signless_integer tok2, none(CSSAnB)
      return some((1, -int(tok2.nvalue)))
    of "-n-", "-N-":
      fail_plus
      let tok2 = get_tok
      fail_non_signless_integer tok2, none(CSSAnB)
      return some((-1, -int(tok2.nvalue)))
    elif tok.unit.startsWithNoCase("n-"):
      return some((1, -parse_sub_int(tok.value, "n-".len)))
    elif tok.unit.startsWithNoCase("-n-"):
      fail_plus
      return some((-1, -parse_sub_int(tok.value, "n-".len)))
    else:
      return none(CSSAnB)
  of CSS_NUMBER_TOKEN:
    fail_plus
    if tok.tflagb != TFLAGB_INTEGER:
      return none(CSSAnB)
    if int64(tok.nvalue) > high(int):
      return none(CSSAnB)
    # <integer>
    return some((0, int(tok.nvalue)))
  of CSS_DIMENSION_TOKEN:
    fail_plus
    if int64(tok.nvalue) > high(int):
      return none(CSSAnB)
    if tok.tflagb != TFLAGB_INTEGER:
      return none(CSSAnB)
    case tok.unit
    of "n", "N":
      # <n-dimension>
      if is_eof:
        return some((int(tok.nvalue), 0))
      let tok2 = get_tok
      if tok2.tokenType == CSS_DELIM_TOKEN:
        let sign = case tok2.cvalue
        of '+': 1
        of '-': -1
        else: return none(CSSAnB)
        let tok3 = get_tok
        fail_non_signless_integer tok3, some((int(tok.nvalue), 0))
        return some((int(tok.nvalue), sign * int(tok3.nvalue)))
      else:
        fail_non_integer tok2, some((int(tok.nvalue), 0))
        return some((int(tok.nvalue), int(tok2.nvalue)))
    of "n-", "N-":
      # <ndash-dimension>
      let tok2 = get_tok
      fail_non_signless_integer tok2, none(CSSAnB)
      return some((int(tok.nvalue), -int(tok2.nvalue)))
    elif tok.unit.startsWithNoCase("n-"):
      # <ndashdigit-dimension>
      return some((int(tok.nvalue), -parse_sub_int(tok.unit, "n-".len)))
    else:
      return none(CSSAnB)
  else:
    return none(CSSAnB)

proc parseAnB*(cvals: seq[CSSComponentValue]): (Option[CSSAnB], int) =
  var state: CSSParseState
  state.tokens = cast[seq[CSSParsedItem]](cvals)
  let anb = state.parseAnB()
  return (anb, state.at)

proc parseCSS*(inputStream: Stream): CSSRawStylesheet =
  if inputStream.atEnd():
    return CSSRawStylesheet()
  return inputstream.parseStylesheet()
