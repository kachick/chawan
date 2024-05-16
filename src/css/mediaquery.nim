import std/strutils
import std/tables

import css/cssparser
import css/cssvalues
import types/opt
import utils/twtstr

type
  MediaQueryParser = object
    at: int
    cvals: seq[CSSComponentValue]

  MediaType* = enum
    mtUnknown = "unknown"
    mtAll = "all"
    mtPrint = "print"
    mtScreen = "screen"
    mtSpeech = "speech"
    mtTty = "tty"

  MediaConditionType* = enum
    mctNot, mctAnd, mctOr, mctFeature, mctMedia

  MediaFeatureType* = enum
    mftColor, mftGrid, mftHover, mftPrefersColorScheme, mftWidth, mftHeight,
    mftScripting

  MediaFeature* = object
    case t*: MediaFeatureType
    of mftColor:
      range*: Slice[int]
    of mftGrid, mftHover, mftPrefersColorScheme,
        mftScripting:
      b*: bool
    of mftWidth, mftHeight:
      lengthrange*: Slice[CSSLength]
      lengthaeq*: bool
      lengthbeq*: bool

  MediaQuery* = ref object
    case t*: MediaConditionType
    of mctMedia:
      media*: MediaType
    of mctFeature:
      feature*: MediaFeature
    of mctNot:
      n*: MediaQuery
    of mctOr:
      ora*: MediaQuery
      orb*: MediaQuery
    of mctAnd:
      anda*: MediaQuery
      andb*: MediaQuery

  MediaQueryList* = seq[MediaQuery]

  MediaQueryComparison = enum
    mqcEq, mqcGt, mqcLt, mqcGe, mqcLe

# for debugging
func `$`*(mf: MediaFeature): string =
  case mf.t
  of mftColor:
    return "color: " & $mf.range.a & ".." & $mf.range.b
  of mftGrid:
    return "grid: " & $mf.b
  of mftHover:
    return "hover: " & $mf.b
  of mftPrefersColorScheme:
    return "prefers-color-scheme: " & $mf.b
  of mftWidth:
    result &= $mf.lengthrange.a
    result &= " <"
    if mf.lengthaeq:
      result &= "="
    result &= " width <"
    if mf.lengthbeq:
      result &= "="
    result &= " "
    result &= $mf.lengthrange.b
  of mftHeight:
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
  of mftScripting:
    return "scripting: " & (if mf.b: "enabled" else: "none")

func `$`*(mq: MediaQuery): string =
  case mq.t
  of mctMedia: return $mq.media
  of mctFeature: return $mq.feature
  of mctNot: return "not (" & $mq.n
  of mctOr: return "(" & $mq.ora & ") or (" & $mq.orb & ")"
  of mctAnd: return "(" & $mq.anda & ") or (" & $mq.andb & ")"

const MediaTypes = {
  "all": mtAll,
  "print": mtPrint,
  "screen": mtScreen,
  "speech": mtSpeech,
  "tty": mtTty
}.toTable()

const RangeFeatures = {mftColor, mftWidth, mftHeight}

proc has(parser: MediaQueryParser; i = 0): bool {.inline.} =
  return parser.cvals.len > parser.at + i

proc consume(parser: var MediaQueryParser): CSSComponentValue {.inline.} =
  result = parser.cvals[parser.at]
  inc parser.at

proc reconsume(parser: var MediaQueryParser) {.inline.} =
  dec parser.at

proc peek(parser: MediaQueryParser; i = 0): CSSComponentValue {.inline.} =
  return parser.cvals[parser.at + i]

proc skipBlanks(parser: var MediaQueryParser) {.inline.} =
  while parser.has():
    let cval = parser.peek()
    if cval of CSSToken and CSSToken(cval).tokenType == cttWhitespace:
      inc parser.at
    else:
      break

proc getBoolFeature(feature: MediaFeatureType): MediaQuery =
  result = MediaQuery(t: mctFeature)
  case feature
  of mftGrid, mftHover, mftPrefersColorScheme:
    result.feature = MediaFeature(t: feature, b: true)
  of mftColor:
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
  if tok.tokenType != cttIdent: return nil

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
  if tok.tokenType == cttNumber and tok.tflagb == tflagbInteger:
    i = int(tok.nvalue)
  else:
    return nil

template expect_mq_int(b: bool; ifalse, itrue: int) =
  var i: int
  expect_int(i)
  if i == ifalse: b = false
  elif i == itrue: b = true
  else: return nil

template expect_bool(b: bool; sfalse, strue: string) =
  let tok = consume_token()
  if tok.tokenType != cttIdent: return nil
  let s = tok.value
  case s
  of strue: b = true
  of sfalse: b = false
  else: return nil

template expect_bool(b: bool; sfalse, sfalse2, strue: string) =
  let tok = consume_token()
  if tok.tokenType != cttIdent: return nil
  let s = tok.value
  case s
  of strue: b = true
  of sfalse, sfalse2: b = false
  else: return nil

template expect_comparison(comparison: var MediaQueryComparison) =
  let tok = consume_token()
  if tok != cttDelim: return nil
  let c = tok.cvalue
  if c notin {'=', '<', '>'}: return nil
  block parse:
    case c
    of '<':
      if parser.has():
        let tok = skip_consume()
        if tok == cttDelim and tok.cvalue == '=':
          comparison = mqcLe
          break parse
        parser.reconsume()
      comparison = mqcLt
    of '>':
      if parser.has():
        let tok = skip_consume()
        if tok == cttDelim and tok.cvalue == '=':
          comparison = mqcGe
          break parse
        parser.reconsume()
      comparison = mqcGt
    of '=':
      comparison = mqcEq
    else: return nil

template expect_int_range(range: var Slice[int]; ismin, ismax: bool) =
  if ismin:
    expect_int(range.a)
  elif ismax:
    expect_int(range.b)
  else:
    let tok = consume_token
    parser.reconsume()
    if tok.tokenType == cttDelim:
      var comparison: MediaQueryComparison
      expect_comparison(comparison)
      if not skip_has: return nil
      case comparison
      of mqcEq:
        expect_int(range.a) #TODO should be >= 0 (for color at least)
        range.b = range.a
      of mqcGt:
        expect_int(range.a)
        range.b = high(int)
      of mqcGe:
        expect_int(range.a)
        range.b = high(int)
      of mqcLt:
        expect_int(range.b)
      of mqcLe:
        expect_int(range.b)
    else:
      return nil

template expect_length(length: var CSSLength) =
  let cval = parser.consume()
  let r = cssLength(cval)
  if r.isNone:
    return nil
  length = r.get

template expect_length_range(range: var Slice[CSSLength];
    lengthaeq, lengthbeq: var bool; ismin, ismax: bool) =
  if ismin:
    expect_length(range.a)
    range.b = CSSLength(num: Inf, unit: cuPx)
    lengthaeq = true
  elif ismax:
    range.a = CSSLength(num: 0, unit: cuPx)
    expect_length(range.b)
    lengthbeq = true
  else:
    let tok = consume_token
    parser.reconsume()
    if tok.tokenType == cttDelim:
      var comparison: MediaQueryComparison
      expect_comparison(comparison)
      if not skip_has: return nil
      expect_length(range.a)
      if not skip_has: return nil
      expect_length(range.b)
      case comparison
      of mqcEq:
        expect_length(range.a)
        range.b = range.a
        lengthaeq = true
        lengthbeq = true
      of mqcGt:
        expect_length(range.a)
        range.b = CSSLength(num: Inf, unit: cuPx)
      of mqcGe:
        expect_length(range.a)
        range.b = CSSLength(num: Inf, unit: cuPx)
        lengthaeq = true
      of mqcLt:
        range.a = CSSLength(num: 0, unit: cuPx)
        expect_length(range.b)
      of mqcLe:
        range.a = CSSLength(num: 0, unit: cuPx)
        expect_length(range.b)
        lengthbeq = true
    else:
      return nil

proc parseFeature(parser: var MediaQueryParser; t: MediaFeatureType;
    ismin, ismax: bool): MediaQuery =
  if not parser.has(): return getBoolFeature(t)
  let cval = parser.consume()
  var tok: CSSToken
  get_tok(tok)
  if tok.tokenType != cttColon: return nil
  parser.skipBlanks()
  if (ismin or ismax) and t notin RangeFeatures:
    return nil
  if not parser.has(): return nil
  let feature = case t
  of mftGrid:
    var b: bool
    expect_mq_int(b, 0, 1)
    MediaFeature(t: t, b: b)
  of mftHover:
    var b: bool
    expect_bool(b, "none", "hover")
    MediaFeature(t: t, b: b)
  of mftPrefersColorScheme:
    var b: bool
    expect_bool(b, "light", "dark")
    MediaFeature(t: t, b: b)
  of mftColor:
    var range: Slice[int]
    expect_int_range(range, ismin, ismax)
    MediaFeature(t: t, range: range)
  of mftWidth, mftHeight:
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
  of mftScripting:
    if ismin or ismax:
      return nil
    var b: bool
    expect_bool(b, "none", "initial-only", "enabled")
    MediaFeature(t: t, b: b)
  parser.skipBlanks()
  if parser.has():
    return nil
  return MediaQuery(t: mctFeature, feature: feature)

proc parseMediaCondition(parser: var MediaQueryParser; non = false;
  noor = false): MediaQuery

proc parseMediaInParens(parser: var MediaQueryParser): MediaQuery =
  var fparser: MediaQueryParser
  block:
    let cval = parser.consume()
    if not (cval of CSSSimpleBlock): return nil

    let sb = CSSSimpleBlock(cval)
    if sb.token.tokenType != cttLparen: return nil

    fparser.cvals = sb.value
    fparser.skipBlanks()

  block:
    let cval = fparser.consume()
    var tok: CSSToken
    get_tok(tok)
    fparser.skipBlanks()
    if tok.tokenType == cttIdent:
      var tokval = tok.value
      let ismin = tokval.startsWith("min-")
      let ismax = tokval.startsWith("max-")
      if ismin or ismax:
        tokval = tokval.substr(4)
      case tokval
      of "not":
        return fparser.parseMediaCondition(true)
      of "color":
        return fparser.parseFeature(mftColor, ismin, ismax)
      of "width":
        return fparser.parseFeature(mftWidth, ismin, ismax)
      of "grid":
        return fparser.parseFeature(mftGrid, ismin, ismax)
      of "hover":
        return fparser.parseFeature(mftHover, ismin, ismax)
      of "prefers-color-scheme":
        return fparser.parseFeature(mftPrefersColorScheme, ismin, ismax)
      of "scripting":
        return fparser.parseFeature(mftScripting, ismin, ismax)
      else: discard
  return nil

proc parseMediaOr(parser: var MediaQueryParser; left: MediaQuery): MediaQuery =
  let right = parser.parseMediaCondition()
  if right != nil:
    return MediaQuery(t: mctOr, ora: left, orb: right)
  return nil

proc parseMediaAnd(parser: var MediaQueryParser; left: MediaQuery): MediaQuery =
  let right = parser.parseMediaCondition()
  if right != nil:
    return MediaQuery(t: mctAnd, anda: left, andb: right)
  return nil

proc parseMediaCondition(parser: var MediaQueryParser; non = false;
    noor = false): MediaQuery =
  var non = non
  if not non:
    let cval = parser.consume()
    if cval of CSSToken and CSSToken(cval).tokenType == cttIdent:
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
    result = MediaQuery(t: mctNot, n: result)

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
      if tok.tokenType == cttIdent:
        let tokval = tok.value
        case tokval
        of "not":
          non = true
        of "only":
          discard
        elif tokval in MediaTypes:
          result = MediaQuery(t: mctMedia, media: MediaTypes[tokval])
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
      if tok.tokenType == cttIdent:
        let tokval = tok.value
        if result == nil:
          if tokval in MediaTypes:
            let mq = MediaQuery(t: mctMedia, media: MediaTypes[tokval])
            if non:
              result = MediaQuery(t: mctNot, n: mq)
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
      if tok.tokenType != cttIdent or tok.value != "and":
        return nil
    parser.skipBlanks()
    if not parser.has():
      return nil
    parser.reconsume()
    return parser.parseMediaAnd(result)

proc parseMediaQueryList*(cvals: seq[CSSComponentValue]): MediaQueryList =
  let cseplist = cvals.parseCommaSepComponentValues()
  for list in cseplist:
    var parser = MediaQueryParser(cvals: list)
    let query = parser.parseMediaQuery()
    if query != nil:
      result.add(query)
