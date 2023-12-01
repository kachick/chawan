import std/options
import std/os
import std/posix

import js/error
import js/fromjs
import js/javascript
import js/tojs
import types/opt
import utils/twtstr

type ChaPath* = distinct string

func `$`*(p: ChaPath): string =
  return string(p)

type
  UnquoteContext = object
    state: UnquoteState
    s: string
    p: string
    i: int
    identStr: string
    subChar: char
    hasColon: bool
    terminal: Option[char]

  UnquoteState = enum
    STATE_NORMAL, STATE_TILDE, STATE_DOLLAR, STATE_IDENT, STATE_BSLASH,
    STATE_CURLY_START, STATE_CURLY, STATE_CURLY_HASH, STATE_CURLY_PERC,
    STATE_CURLY_COLON, STATE_CURLY_EXPAND, STATE_DONE

  ChaPathError = string

  ChaPathResult[T] = Result[T, ChaPathError]

proc unquote(p: string, starti: var int, terminal: Option[char]):
    ChaPathResult[string]

proc stateNormal(ctx: var UnquoteContext, c: char) =
  case c
  of '$': ctx.state = STATE_DOLLAR
  of '\\': ctx.state = STATE_BSLASH
  of '~':
    if ctx.i == 0:
      ctx.state = STATE_TILDE
    else:
      ctx.s &= c
  elif ctx.terminal.isSome and ctx.terminal.get == c:
    ctx.state = STATE_DONE
  else:
    ctx.s &= c

proc flushTilde(ctx: var UnquoteContext) =
  if ctx.identStr == "":
    ctx.s &= getHomeDir()
  else:
    let p = getpwnam(cstring(ctx.identStr))
    if p != nil:
      ctx.s &= $p.pw_dir
    ctx.identStr = ""
  ctx.state = STATE_NORMAL

proc stateTilde(ctx: var UnquoteContext, c: char) =
  if c != '/':
    ctx.identStr &= c
  else:
    ctx.flushTilde()

# Kind of a hack. We special case `\$' (backslash-dollar) in TOML, so that
# it produces itself in dquote strings.
# Thus by applying stateBSlash we get '\$' -> "$", but also "\$" -> "$".
proc stateBSlash(ctx: var UnquoteContext, c: char) =
  if c != '$':
    ctx.s &= '\\'
  ctx.s &= c
  ctx.state = STATE_NORMAL

proc stateDollar(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # $
  case c
  of '$':
    ctx.s &= $getCurrentProcessId()
    ctx.state = STATE_NORMAL
  of '0':
    # Note: we intentionally use getAppFileName so that any symbolic links
    # are resolved.
    ctx.s &= getAppFileName()
    ctx.state = STATE_NORMAL
  of '1'..'9':
    return err("Parameter substitution is not supported")
  of AsciiAlpha:
    ctx.identStr = $c
    ctx.state = STATE_IDENT
  of '{':
    ctx.state = STATE_CURLY_START
  else:
    # > If an unquoted '$' is followed by a character that is not one of
    # > the following: [...] the result is unspecified.
    # just error out here to be safe
    return err("Invalid dollar substitution")
  ok()

proc flushIdent(ctx: var UnquoteContext) =
  ctx.s &= getEnv(ctx.identStr)
  ctx.identStr = ""

const BareChars = AsciiAlphaNumeric + {'_'}

proc stateIdent(ctx: var UnquoteContext, c: char) =
  # $ident
  if c in BareChars:
    ctx.identStr &= c
  else:
    ctx.flushIdent()
    dec ctx.i
    ctx.state = STATE_NORMAL

proc stateCurlyStart(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${
  case c
  of '#':
    ctx.state = STATE_CURLY_HASH
  of '%':
    ctx.state = STATE_CURLY_PERC
  of BareChars:
    ctx.state = STATE_CURLY
    dec ctx.i
  else:
    return err("unexpected character in substitution: '" & c & "'")
  return ok()

proc stateCurly(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${ident
  case c
  of '}':
    ctx.s &= $getEnv(ctx.identStr)
    ctx.state = STATE_NORMAL
    return ok()
  of '$': # allow $ as first char only
    if ctx.identStr.len > 0:
      return err("unexpected dollar sign in substitution")
    ctx.identStr &= c
    return ok()
  of ':', '-', '?', '+': # note: we don't support `=' (assign)
    if ctx.identStr.len > 0:
      return err("substitution without parameter name")
    if c == ':':
      ctx.state = STATE_CURLY_COLON
    else:
      ctx.subChar = c
      ctx.state = STATE_CURLY_EXPAND
    return ok()
  of '1'..'9':
    return err("Parameter substitution is not supported")
  of BareChars - {'1'..'9'}:
    ctx.identStr &= c
    return ok()
  else:
    return err("unexpected character in substitution: '" & c & "'")

proc stateCurlyHash(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${#ident
  if c == '}':
    let s = getEnv(ctx.identStr)
    ctx.s &= $s.len
    ctx.identStr = ""
    ctx.state = STATE_NORMAL
    return ok()
  if c == '$': # allow $ as first char only
    if ctx.identStr.len > 0:
      return err("unexpected dollar sign in substitution")
    # fall through
  elif c notin BareChars:
    return err("unexpected character in substitution: '" & c & "'")
  ctx.identStr &= c
  return ok()

proc stateCurlyPerc(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${%ident
  if c == '}':
    if ctx.identStr == "CHA_BIN_DIR":
      ctx.s &= getAppFileName().beforeLast('/')
    else:
      return err("Unknown internal variable " & ctx.identStr)
    ctx.identStr = ""
    ctx.state = STATE_NORMAL
    return ok()
  if c notin BareChars:
    return err("unexpected character in substitution: '" & c & "'")
  ctx.identStr &= c
  return ok()

proc stateCurlyColon(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${ident:
  if c notin {'-', '?', '+'}: # Note: we don't support `=' (assign)
    return err("unexpected character after colon: '" & c & "'")
  ctx.hasColon = true
  ctx.subChar = c
  ctx.state = STATE_CURLY_EXPAND
  return ok()

proc flushCurlyExpand(ctx: var UnquoteContext, word: string):
    ChaPathResult[void] =
  case ctx.subChar
  of '-':
    if ctx.hasColon:
      ctx.s &= getEnv(ctx.identStr, word)
    else:
      if existsEnv(ctx.identStr):
        ctx.s &= getEnv(ctx.identStr)
      else:
        ctx.s &= word
  of '?':
    if ctx.hasColon:
      let s = getEnv(ctx.identStr)
      if s.len == 0:
        return err(word)
      ctx.s &= s
    else:
      if not existsEnv(ctx.identStr):
        return err(word)
      ctx.s &= getEnv(ctx.identStr)
  of '+':
    if ctx.hasColon:
      if getEnv(ctx.identStr).len > 0:
        ctx.s &= word
    else:
      if existsEnv(ctx.identStr):
        ctx.s &= word
  else: assert false
  ctx.subChar = '\0'
  ctx.hasColon = false

proc stateCurlyExpand(ctx: var UnquoteContext, c: char): ChaPathResult[void] =
  # ${ident:-[word], ${ident:=[word], ${ident:?[word], ${ident:+[word]
  # word must be unquoted too.
  let word = ?unquote(ctx.p, ctx.i, some('}'))
  ctx.flushCurlyExpand(word)

proc unquote(p: string, starti: var int, terminal: Option[char]):
    ChaPathResult[string] =
  var ctx = UnquoteContext(p: p, i: starti, terminal: terminal)
  while ctx.i < p.len:
    let c = p[ctx.i]
    case ctx.state
    of STATE_NORMAL: ctx.stateNormal(c)
    of STATE_TILDE: ctx.stateTilde(c)
    of STATE_BSLASH: ctx.stateBSlash(c)
    of STATE_DOLLAR: ?ctx.stateDollar(c)
    of STATE_IDENT: ctx.stateIdent(c)
    of STATE_CURLY_START: ?ctx.stateCurlyStart(c)
    of STATE_CURLY: ?ctx.stateCurly(c)
    of STATE_CURLY_HASH: ?ctx.stateCurlyHash(c)
    of STATE_CURLY_PERC: ?ctx.stateCurlyPerc(c)
    of STATE_CURLY_COLON: ?ctx.stateCurlyColon(c)
    of STATE_CURLY_EXPAND: ?ctx.stateCurlyExpand(c)
    of STATE_DONE: break
    inc ctx.i
  case ctx.state
  of STATE_NORMAL, STATE_DONE: discard
  of STATE_TILDE: ctx.flushTilde()
  of STATE_BSLASH: ctx.s &= '\\'
  of STATE_DOLLAR: ctx.s &= '$'
  of STATE_IDENT: ctx.flushIdent()
  of STATE_CURLY_START, STATE_CURLY, STATE_CURLY_HASH, STATE_CURLY_PERC,
      STATE_CURLY_COLON:
    return err("} expected")
  of STATE_CURLY_EXPAND:
    ?ctx.flushCurlyExpand("")
  starti = ctx.i
  return ok(ctx.s)

proc unquote(p: string): ChaPathResult[string] =
  var dummy = 0
  return unquote(p, dummy, none(char))

proc toJS*(ctx: JSContext, p: ChaPath): JSValue =
  toJS(ctx, $p)

proc fromJS2*(ctx: JSContext, val: JSValue, o: var JSResult[ChaPath]) =
  o = cast[JSResult[ChaPath]](fromJS[string](ctx, val))

proc unquote*(p: ChaPath): ChaPathResult[string] =
  let s = ?unquote(string(p))
  return ok(normalizedPath(s))
