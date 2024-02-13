import std/strutils
import std/tables

import css/cssparser
import css/values
import types/opt
import utils/twtstr

type
  MediaQueryParser = object
    at: int
    cvals: seq[CSSComponentValue]

  MediaType* = enum
    MEDIA_TYPE_UNKNOWN = "unknown"
    MEDIA_TYPE_ALL = "all"
    MEDIA_TYPE_PRINT = "print"
    MEDIA_TYPE_SCREEN = "screen"
    MEDIA_TYPE_SPEECH = "speech"
    MEDIA_TYPE_TTY = "tty"

  MediaConditionType* = enum
    CONDITION_NOT, CONDITION_AND, CONDITION_OR, CONDITION_FEATURE,
    CONDITION_MEDIA

  MediaFeatureType* = enum
    FEATURE_COLOR, FEATURE_GRID, FEATURE_HOVER, FEATURE_PREFERS_COLOR_SCHEME,
    FEATURE_WIDTH, FEATURE_HEIGHT, FEATURE_SCRIPTING

  MediaFeature* = object
    case t*: MediaFeatureType
    of FEATURE_COLOR:
      range*: Slice[int]
    of FEATURE_GRID, FEATURE_HOVER, FEATURE_PREFERS_COLOR_SCHEME,
        FEATURE_SCRIPTING:
      b*: bool
    of FEATURE_WIDTH, FEATURE_HEIGHT:
      lengthrange*: Slice[CSSLength]
      lengthaeq*: bool
      lengthbeq*: bool

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

  MediaQueryComparison = enum
    COMPARISON_EQ, COMPARISON_GT, COMPARISON_LT, COMPARISON_GE, COMPARISON_LE

# for debugging
func `$`*(mf: MediaFeature): string =
  case mf.t
  of FEATURE_COLOR:
    return "color: " & $mf.range.a & ".." & $mf.range.b
  of FEATURE_GRID:
    return "grid: " & $mf.b
  of FEATURE_HOVER:
    return "hover: " & $mf.b
  of FEATURE_PREFERS_COLOR_SCHEME:
    return "prefers-color-scheme: " & $mf.b
  of FEATURE_WIDTH:
    result &= $mf.lengthrange.a
    result &= " <"
    if mf.lengthaeq:
      result &= "="
    result &= " width <"
    if mf.lengthbeq:
      result &= "="
    result &= " "
    result &= $mf.lengthrange.b
  of FEATURE_HEIGHT:
    result &= $mf.lengthrange.a
    result &= " <"
    if mf.lengthaeq:
      result &= "="
    result &= " width "
    result &= "<"
    if mf.lengthbeq:
      result &= "="
    result &= " "
    result &= $mf.lengthrange.b
  of FEATURE_SCRIPTING:
    return "scripting: " & (if mf.b: "enabled" else: "none")

func `$`*(mq: MediaQuery): string =
  case mq.t
  of CONDITION_MEDIA: return $mq.media
  of CONDITION_FEATURE: return $mq.feature
  of CONDITION_NOT: return "not (" & $mq.n
  of CONDITION_OR: return "(" & $mq.ora & ") or (" & $mq.orb & ")"
  of CONDITION_AND: return "(" & $mq.anda & ") or (" & $mq.andb & ")"

const MediaTypes = {
  "all": MEDIA_TYPE_ALL,
  "print": MEDIA_TYPE_PRINT,
  "screen": MEDIA_TYPE_SCREEN,
  "speech": MEDIA_TYPE_SPEECH,
  "tty": MEDIA_TYPE_TTY
}.toTable()

const RangeFeatures = {FEATURE_COLOR, FEATURE_WIDTH, FEATURE_HEIGHT}

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
    result.feature = MediaFeature(t: feature, range: 1..high(int))
  else:
    return nil

template skip_has(): bool =
  parser.skipBlanks()
  parser.has()

template get_tok(tok: untyped) =
  if not (cval of CSSToken): return nil
  tok = CSSToken(cval)

template get_idtok(tok: untyped) =
  get_tok(tok)
  if tok.tokenType != CSS_IDENT_TOKEN: return nil

template consume_token(): CSSToken =
  let cval = parser.consume()
  if not (cval of CSSToken): return nil
  CSSToken(cval)

template skip_consume(): CSSToken =
  parser.skipBlanks()
  consume_token()

template expect_int(i: var int) =
  let cval = parser.consume()
  if not (cval of CSSToken): return nil
  let tok = CSSToken(cval)
  if tok.tokenType == CSS_NUMBER_TOKEN and tok.tflagb == TFLAGB_INTEGER:
    i = int(tok.nvalue)
  else:
    return nil

template expect_mq_int(b: bool, ifalse: int, itrue: int) =
  var i: int
  expect_int(i)
  if i == ifalse: b = false
  elif i == itrue: b = true
  else: return nil

template expect_bool(b: bool, sfalse, strue: string) =
  let tok = consume_token()
  if tok.tokenType != CSS_IDENT_TOKEN: return nil
  let s = tok.value
  case s
  of strue: b = true
  of sfalse: b = false
  else: return nil

template expect_bool(b: bool, sfalse, sfalse2, strue: string) =
  let tok = consume_token()
  if tok.tokenType != CSS_IDENT_TOKEN: return nil
  let s = tok.value
  case s
  of strue: b = true
  of sfalse, sfalse2: b = false
  else: return nil

template expect_comparison(comparison: var MediaQueryComparison) =
  let tok = consume_token()
  if tok != CSS_DELIM_TOKEN: return nil
  let c = tok.cvalue
  if c notin {'=', '<', '>'}: return nil
  block parse:
    case c
    of '<':
      if parser.has():
        let tok = skip_consume()
        if tok == CSS_DELIM_TOKEN and tok.cvalue == '=':
          comparison = COMPARISON_LE
          break parse
        parser.reconsume()
      comparison = COMPARISON_LT
    of '>':
      if parser.has():
        let tok = skip_consume()
        if tok == CSS_DELIM_TOKEN and tok.cvalue == '=':
          comparison = COMPARISON_GE
          break parse
        parser.reconsume()
      comparison = COMPARISON_GT
    of '=':
      comparison = COMPARISON_EQ
    else: return nil

template expect_int_range(range: var Slice[int], ismin, ismax: bool) =
  if ismin:
    expect_int(range.a)
  elif ismax:
    expect_int(range.b)
  else:
    let tok = consume_token
    parser.reconsume()
    if tok.tokenType == CSS_DELIM_TOKEN:
      var comparison: MediaQueryComparison
      expect_comparison(comparison)
      if not skip_has: return nil
      case comparison
      of COMPARISON_EQ:
        expect_int(range.a) #TODO should be >= 0 (for color at least)
        range.b = range.a
      of COMPARISON_GT:
        expect_int(range.a)
        range.b = high(int)
      of COMPARISON_GE:
        expect_int(range.a)
        range.b = high(int)
      of COMPARISON_LT:
        expect_int(range.b)
      of COMPARISON_LE:
        expect_int(range.b)
    else:
      return nil

template expect_length(length: var CSSLength) =
  let cval = parser.consume()
  let r = cssLength(cval)
  if r.isErr:
    return nil
  length = r.get

template expect_length_range(range: var Slice[CSSLength], lengthaeq, lengthbeq:
    var bool, ismin, ismax: bool) =
  if ismin:
    expect_length(range.a)
    range.b = CSSLength(num: Inf, unit: UNIT_PX)
    lengthaeq = true
  elif ismax:
    range.a = CSSLength(num: 0, unit: UNIT_PX)
    expect_length(range.b)
    lengthbeq = true
  else:
    let tok = consume_token
    parser.reconsume()
    if tok.tokenType == CSS_DELIM_TOKEN:
      var comparison: MediaQueryComparison
      expect_comparison(comparison)
      if not skip_has: return nil
      expect_length(range.a)
      if not skip_has: return nil
      expect_length(range.b)
      case comparison
      of COMPARISON_EQ:
        expect_length(range.a)
        range.b = range.a
        lengthaeq = true
        lengthbeq = true
      of COMPARISON_GT:
        expect_length(range.a)
        range.b = CSSLength(num: Inf, unit: UNIT_PX)
      of COMPARISON_GE:
        expect_length(range.a)
        range.b = CSSLength(num: Inf, unit: UNIT_PX)
        lengthaeq = true
      of COMPARISON_LT:
        range.a = CSSLength(num: 0, unit: UNIT_PX)
        expect_length(range.b)
      of COMPARISON_LE:
        range.a = CSSLength(num: 0, unit: UNIT_PX)
        expect_length(range.b)
        lengthbeq = true
    else:
      return nil

proc parseFeature(parser: var MediaQueryParser, t: MediaFeatureType,
    ismin, ismax: bool): MediaQuery =
  if not parser.has(): return getBoolFeature(t)
  let cval = parser.consume()
  var tok: CSSToken
  get_tok(tok)
  if tok.tokenType != CSS_COLON_TOKEN: return nil
  parser.skipBlanks()
  if (ismin or ismax) and t notin RangeFeatures:
    return nil
  if not parser.has(): return nil
  let feature = case t
  of FEATURE_GRID:
    var b: bool
    expect_mq_int(b, 0, 1)
    MediaFeature(t: t, b: b)
  of FEATURE_HOVER:
    var b: bool
    expect_bool(b, "none", "hover")
    MediaFeature(t: t, b: b)
  of FEATURE_PREFERS_COLOR_SCHEME:
    var b: bool
    expect_bool(b, "light", "dark")
    MediaFeature(t: t, b: b)
  of FEATURE_COLOR:
    var range: Slice[int]
    expect_int_range(range, ismin, ismax)
    MediaFeature(t: t, range: range)
  of FEATURE_WIDTH, FEATURE_HEIGHT:
    var range: Slice[CSSLength]
    var lengthaeq: bool
    var lengthbeq: bool
    expect_length_range(range, lengthaeq, lengthbeq, ismin, ismax)
    MediaFeature(
      t: t,
      lengthrange: range,
      lengthaeq: lengthaeq,
      lengthbeq: lengthbeq
    )
  of FEATURE_SCRIPTING:
    if ismin or ismax:
      return nil
    var b: bool
    expect_bool(b, "none", "initial-only", "enabled")
    MediaFeature(t: t, b: b)
  parser.skipBlanks()
  if parser.has():
    return nil
  return MediaQuery(t: CONDITION_FEATURE, feature: feature)

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
      var tokval = tok.value
      let ismin = tokval.startsWith("min-")
      let ismax = tokval.startsWith("max-")
      if ismin or ismax:
        tokval = tokval.substr(4)
      case tokval
      of "not":
        return fparser.parseMediaCondition(true)
      of "color":
        return fparser.parseFeature(FEATURE_COLOR, ismin, ismax)
      of "width":
        return fparser.parseFeature(FEATURE_WIDTH, ismin, ismax)
      of "grid":
        return fparser.parseFeature(FEATURE_GRID, ismin, ismax)
      of "hover":
        return fparser.parseFeature(FEATURE_HOVER, ismin, ismax)
      of "prefers-color-scheme":
        return fparser.parseFeature(FEATURE_PREFERS_COLOR_SCHEME, ismin, ismax)
      of "scripting":
        return fparser.parseFeature(FEATURE_SCRIPTING, ismin, ismax)
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
      if CSSToken(cval).value == "not":
        non = true
    else:
      parser.reconsume()

  parser.skipBlanks()
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
  let tokval = tok.value
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
        let tokval = tok.value
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
        let tokval = tok.value
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
        let tokval = tok.value
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
