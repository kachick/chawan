import tables
import unicode

import css/cssparser

type
  MediaQueryParser = object
    at: int
    cvals: seq[CSSComponentValue]

  MediaType* = enum
    MEDIA_TYPE_UNKNOWN, MEDIA_TYPE_ALL, MEDIA_TYPE_PRINT, MEDIA_TYPE_SCREEN,
    MEDIA_TYPE_SPEECH, MEDIA_TYPE_TTY

  MediaConditionType* = enum
    CONDITION_NOT, CONDITION_AND, CONDITION_OR, CONDITION_FEATURE,
    CONDITION_MEDIA

  MediaFeatureType* = enum
    FEATURE_COLOR, FEATURE_GRID, FEATURE_HOVER, FEATURE_PREFERS_COLOR_SCHEME

  MediaFeature* = object
    case t*: MediaFeatureType
    of FEATURE_COLOR:
      color*: Slice[int]
    of FEATURE_GRID, FEATURE_HOVER, FEATURE_PREFERS_COLOR_SCHEME:
      b*: bool

  MediaQuery* = ref object
    case t*: MediaConditionType
    of CONDITION_MEDIA:
      media*: MediaType
    of CONDITION_FEATURE:
      feature*: MediaFeature
    of CONDITION_NOT:
      n*: MediaQuery
    of CONDITION_OR:
      ora*: MediaQuery
      orb*: MediaQuery
    of CONDITION_AND:
      anda*: MediaQuery
      andb*: MediaQuery

  MediaQueryList* = seq[MediaQuery]

const MediaTypes = {
  "all": MEDIA_TYPE_ALL,
  "print": MEDIA_TYPE_PRINT,
  "screen": MEDIA_TYPE_SCREEN,
  "speech": MEDIA_TYPE_SPEECH,
  "tty": MEDIA_TYPE_TTY
}.toTable()

proc has(parser: MediaQueryParser, i = 0): bool {.inline.} =
  return parser.cvals.len > parser.at + i

proc consume(parser: var MediaQueryParser): CSSComponentValue {.inline.} =
  result = parser.cvals[parser.at]
  inc parser.at

proc reconsume(parser: var MediaQueryParser) {.inline.} =
  dec parser.at

proc peek(parser: MediaQueryParser, i = 0): CSSComponentValue {.inline.} =
  return parser.cvals[parser.at + i]

proc skipBlanks(parser: var MediaQueryParser) {.inline.} =
  while parser.has():
    let cval = parser.peek()
    if cval of CSSToken and CSSToken(cval).tokenType == CSS_WHITESPACE_TOKEN:
      inc parser.at
    else:
      break

proc getBoolFeature(feature: MediaFeatureType): MediaQuery =
  result = MediaQuery(t: CONDITION_FEATURE)
  case feature
  of FEATURE_GRID, FEATURE_HOVER, FEATURE_PREFERS_COLOR_SCHEME:
    result.feature = MediaFeature(t: feature, b: true)
  of FEATURE_COLOR:
    result.feature = MediaFeature(t: feature, color: 1..high(int))

template get_tok(tok: untyped) =
  if not (cval of CSSToken): return nil
  tok = CSSToken(cval)

template get_idtok(tok: untyped) =
  get_tok(tok)
  if tok.tokenType != CSS_IDENT_TOKEN: return nil

template expect_mq_int(b: bool, ifalse: int, itrue: int) =
  let cval = parser.consume()
  if not (cval of CSSToken): return nil
  let tok = CSSToken(cval)
  if tok.tokenType != CSS_NUMBER_TOKEN: return nil
  let i = int(tok.nvalue)
  if i == ifalse: b = false
  elif i == itrue: b = true
  else: return nil

template expect_bool(b: bool, sfalse: string, strue: string) =
  let cval = parser.consume()
  if not (cval of CSSToken): return nil
  let tok = CSSToken(cval)
  if tok.tokenType != CSS_IDENT_TOKEN: return nil
  let s = $tok.value
  case s
  of strue: b = true
  of sfalse: b = false
  else: return nil

proc parseFeature(parser: var MediaQueryParser, feature: MediaFeatureType): MediaQuery =
  if not parser.has(): return getBoolFeature(feature)
  let cval = parser.consume()
  var tok: CSSToken
  get_tok(tok)
  if tok.tokenType != CSS_COLON_TOKEN: return nil
  parser.skipBlanks()
  case feature
  of FEATURE_GRID:
    var b: bool
    expect_mq_int(b, 0, 1)
    result = MediaQuery(t: CONDITION_FEATURE, feature: MediaFeature(t: feature, b: b))
  of FEATURE_HOVER:
    var b: bool
    expect_bool(b, "none", "hover")
    result = MediaQuery(t: CONDITION_FEATURE, feature: MediaFeature(t: feature, b: b))
  of FEATURE_PREFERS_COLOR_SCHEME:
    var b: bool
    expect_bool(b, "light", "dark")
    result = MediaQuery(t: CONDITION_FEATURE, feature: MediaFeature(t: feature, b: b))
  else: return nil

  parser.skipBlanks()
  if parser.has():
    return nil

proc parseMediaCondition(parser: var MediaQueryParser, non = false, noor = false): MediaQuery

proc parseMediaInParens(parser: var MediaQueryParser): MediaQuery =
  var fparser: MediaQueryParser
  block:
    let cval = parser.consume()
    if not (cval of CSSSimpleBlock): return nil

    let sb = CSSSimpleBlock(cval)
    if sb.token.tokenType != CSS_LPAREN_TOKEN: return nil

    fparser.cvals = sb.value
    fparser.skipBlanks()

  block:
    let cval = fparser.consume()
    var tok: CSSToken
    get_tok(tok)
    fparser.skipBlanks()
    if tok.tokenType == CSS_IDENT_TOKEN:
      let tokval = $tok.value
      case tokval
      of "not":
        return fparser.parseMediaCondition(true)
      of "color":
        return fparser.parseFeature(FEATURE_COLOR)
      of "grid":
        return fparser.parseFeature(FEATURE_GRID)
      of "hover":
        return fparser.parseFeature(FEATURE_HOVER)
      of "prefers-color-scheme":
        return fparser.parseFeature(FEATURE_PREFERS_COLOR_SCHEME)
      else: discard
  return nil

proc parseMediaOr(parser: var MediaQueryParser, left: MediaQuery): MediaQuery =
  let right = parser.parseMediaCondition()
  if right != nil:
    return MediaQuery(t: CONDITION_OR, ora: left, orb: right)
  return nil

proc parseMediaAnd(parser: var MediaQueryParser, left: MediaQuery): MediaQuery =
  let right = parser.parseMediaCondition()
  if right != nil:
    return MediaQuery(t: CONDITION_AND, anda: left, andb: right)
  return nil

proc parseMediaCondition(parser: var MediaQueryParser, non = false, noor = false): MediaQuery =
  var non = non
  if not non:
    let cval = parser.consume()
    if cval of CSSToken and CSSToken(cval).tokenType == CSS_IDENT_TOKEN:
      if $CSSToken(cval).value == "not":
        non = true
    else:
      parser.reconsume()

  if not parser.has():
    return nil

  result = parser.parseMediaInParens()

  if result == nil:
    return nil

  if non:
    result = MediaQuery(t: CONDITION_NOT, n: result)

  parser.skipBlanks()
  if not parser.has():
    return result

  let cval = parser.consume()
  var tok: CSSToken
  get_idtok(tok)
  parser.skipBlanks()
  let tokval = $tok.value
  case tokval
  of "and":
    return parser.parseMediaAnd(result)
  of "or":
    if noor:
      return nil
    return parser.parseMediaOr(result)
  else: discard

proc parseMediaQuery(parser: var MediaQueryParser): MediaQuery =
  parser.skipBlanks()
  if not parser.has():
    return nil
  var non = false
  block:
    let cval = parser.consume()
    if cval of CSSToken:
      let tok = CSSToken(cval)
      if tok.tokenType == CSS_IDENT_TOKEN: 
        let tokval = $tok.value
        case tokval
        of "not":
          non = true
        of "only":
          discard
        elif tokval in MediaTypes:
          result = MediaQuery(t: CONDITION_MEDIA, media: MediaTypes[tokval])
        else:
          return nil
      else:
        return nil
    else:
      parser.reconsume()
      return parser.parseMediaCondition()

  parser.skipBlanks()
  if not parser.has():
    return result

  block:
    let cval = parser.consume()
    if cval of CSSToken:
      let tok = CSSToken(cval)
      if tok.tokenType == CSS_IDENT_TOKEN: 
        let tokval = $tok.value
        if result == nil:
          if tokval in MediaTypes:
            let mq = MediaQuery(t: CONDITION_MEDIA, media: MediaTypes[tokval])
            if non:
              result = MediaQuery(t: CONDITION_NOT, n: mq)
            else:
              result = mq
          else:
            return nil
        else:
          if tokval == "and":
            parser.reconsume()
            return parser.parseMediaAnd(result)
          else:
            return nil
      else:
        return nil
    else:
      parser.reconsume()
      return parser.parseMediaCondition(non)

  parser.skipBlanks()
  if not parser.has():
    return result

  block:
    let cval = parser.consume()
    if cval of CSSToken:
      let tok = CSSToken(cval)
      if tok.tokenType == CSS_IDENT_TOKEN: 
        let tokval = $tok.value
        if tokval != "and":
          return nil
      else:
        return nil

    parser.skipBlanks()
    if not parser.has():
      return nil

    parser.reconsume()
    return parser.parseMediaAnd(result)

proc parseMediaQueryList*(cvals: seq[CSSComponentValue]): MediaQueryList =
  let cseplist = cvals.parseCommaSeparatedListOfComponentValues()
  for list in cseplist:
    var parser: MediaQueryParser
    parser.cvals = list
    let query = parser.parseMediaQuery()
    if query != nil:
      result.add(query)
