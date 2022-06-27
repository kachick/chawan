import streams
import unicode
import strutils
import tables
import json
import macros
import options
import strformat

import utils/twtstr
import utils/radixtree
import html/dom
import html/entity
import html/tags
import css/sheet

type
  HTMLParseState = object
    in_comment: bool
    in_script: bool
    in_style: bool
    in_noscript: bool
    in_body: bool
    skip_lf: bool
    elementNode: Element
    textNode: Text
    commentNode: Comment
    document: Document
    formowners: seq[HTMLFormElement]

# Tokenizer
type
  Tokenizer = object
    state: TokenizerState
    rstate: TokenizerState
    curr: Rune
    tmp: string
    code: int
    tok: Token
    laststart: Token
    attrn: string
    attrv: string
    attr: bool

    istream: Stream
    sbuf: string
    sbuf_i: int
    sbuf_ip: int
    eof_i: int

  TokenType = enum
    DOCTYPE, START_TAG, END_TAG, COMMENT, CHARACTER, EOF

  TokenizerState = enum
    DATA, CHARACTER_REFERENCE, TAG_OPEN, RCDATA, RCDATA_LESS_THAN_SIGN,
    RAWTEXT, RAWTEXT_LESS_THAN_SIGN, SCRIPT_DATA, SCRIPT_DATA_LESS_THAN_SIGN,
    PLAINTEXT, MARKUP_DECLARATION_OPEN, END_TAG_OPEN, BOGUS_COMMENT, TAG_NAME,
    BEFORE_ATTRIBUTE_NAME, RCDATA_END_TAG_OPEN, RCDATA_END_TAG_NAME,
    RAWTEXT_END_TAG_OPEN, RAWTEXT_END_TAG_NAME, SELF_CLOSING_START_TAG,
    SCRIPT_DATA_END_TAG_OPEN, SCRIPT_DATA_ESCAPE_START,
    SCRIPT_DATA_END_TAG_NAME, SCRIPT_DATA_ESCAPE_START_DASH,
    SCRIPT_DATA_ESCAPED_DASH_DASH, SCRIPT_DATA_ESCAPED,
    SCRIPT_DATA_ESCAPED_DASH, SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN,
    SCRIPT_DATA_ESCAPED_END_TAG_OPEN, SCRIPT_DATA_DOUBLE_ESCAPE_START,
    SCRIPT_DATA_ESCAPED_END_TAG_NAME, SCRIPT_DATA_DOUBLE_ESCAPED,
    SCRIPT_DATA_DOUBLE_ESCAPED_DASH, SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN,
    SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH, SCRIPT_DATA_DOUBLE_ESCAPE_END,
    AFTER_ATTRIBUTE_NAME, ATTRIBUTE_NAME, BEFORE_ATTRIBUTE_VALUE,
    ATTRIBUTE_VALUE_DOUBLE_QUOTED, ATTRIBUTE_VALUE_SINGLE_QUOTED,
    ATTRIBUTE_VALUE_UNQUOTED, AFTER_ATTRIBUTE_VALUE_QUOTED, COMMENT_START,
    CDATA_SECTION, COMMENT_START_DASH, COMMENT, COMMENT_END,
    COMMENT_LESS_THAN_SIGN, COMMENT_END_DASH, COMMENT_LESS_THAN_SIGN_BANG,
    COMMENT_LESS_THAN_SIGN_BANG_DASH, COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH,
    COMMENT_END_BANG, DOCTYPE, BEFORE_DOCTYPE_NAME, DOCTYPE_NAME,
    AFTER_DOCTYPE_NAME, AFTER_DOCTYPE_PUBLIC_KEYWORD,
    AFTER_DOCTYPE_SYSTEM_KEYWORD, BOGUS_DOCTYPE,
    BEFORE_DOCTYPE_PUBLIC_IDENTIFIER, DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED,
    DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED, AFTER_DOCTYPE_PUBLIC_IDENTIFIER,
    BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS,
    DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED,
    DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED, BEFORE_DOCTYPE_SYSTEM_IDENTIFIER,
    AFTER_DOCTYPE_SYSTEM_IDENTIFIER, CDATA_SECTION_BRACKET, CDATA_SECTION_END,
    NAMED_CHARACTER_REFERENCE, NUMERIC_CHARACTER_REFERENCE,
    AMBIGUOUS_AMPERSAND_STATE, HEXADECIMAL_CHARACTER_REFERENCE_START,
    DECIMAL_CHARACTER_REFERENCE_START, HEXADECIMAL_CHARACTER_REFERENCE,
    DECIMAL_CHARACTER_REFERENCE, NUMERIC_CHARACTER_REFERENCE_END

  Token = ref object
    case t: TokenType
    of DOCTYPE:
      name: Option[string]
      pubid: Option[string]
      sysid: Option[string]
      quirks: bool
    of START_TAG, END_TAG:
      tagname: string
      selfclosing: bool
      attrs: Table[string, string]
    of CHARACTER:
      r: Rune
    of COMMENT:
      data: string
    of EOF: discard

func `$`*(tok: Token): string =
  case tok.t
  of DOCTYPE: fmt"{tok.t} {tok.name} {tok.pubid} {tok.sysid} {tok.quirks}"
  of START_TAG, END_TAG: fmt"{tok.t} {tok.tagname} {tok.selfclosing} {tok.attrs}"
  of CHARACTER: fmt"{tok.t} {tok.r}"
  of COMMENT: fmt"{tok.t} {tok.data}"
  of EOF: fmt"{tok.t}"

const bufSize = 512
const copyBufSize = 16
proc newTokenizer(s: Stream): Tokenizer =
  result.sbuf = newString(bufSize)
  result.istream = s
  if result.istream.atEnd:
    result.eof_i = 0
  else:
    let n = s.readDataStr(result.sbuf, 0..bufSize-1)
    result.eof_i = n

func atEof(t: Tokenizer): bool =
  t.eof_i != -1 and t.sbuf_i >= t.eof_i

proc consume(t: var Tokenizer): char {.inline.} =
  if t.sbuf_i >= bufSize-copyBufSize:
    var sbuf2 = newString(copyBufSize)
    var i = 0
    while t.sbuf_i + i < bufSize:
      sbuf2[i] = t.sbuf[t.sbuf_i + i]
      inc i
    let n = t.istream.readDataStr(t.sbuf, i..bufSize-1)
    if n != bufSize - i:
      t.eof_i = i + n
    t.sbuf_i = 0

    var j = 0
    while j < i:
      t.sbuf[j] = sbuf2[j]
      inc j

  assert t.eof_i == -1 or t.sbuf_i < t.eof_i # not consuming eof...
  t.sbuf_ip = t.sbuf_i # save previous pointer for potential reconsume

  # Normalize newlines (\r\n -> \n, single \r -> \n)
  if t.sbuf[t.sbuf_i] == '\r':
    inc t.sbuf_i
    if t.sbuf[t.sbuf_i] != '\n':
      # \r
      result = '\n'
      t.curr = Rune('\n')
      return
    # else, \r\n so just return the \n

  result = t.sbuf[t.sbuf_i]
  fastRuneAt(t.sbuf, t.sbuf_i, t.curr)

proc reconsume(t: var Tokenizer) =
  t.sbuf_i = t.sbuf_ip

iterator tokenize(tokenizer: var Tokenizer): Token =
  template emit(tok: Token) =
    if tok.t == START_TAG:
      tokenizer.laststart = tok
    yield tok
  template emit(tok: TokenType) = emit Token(t: tok)
  template emit(rn: Rune) = emit Token(t: CHARACTER, r: rn)
  template emit(ch: char) = emit Token(t: CHARACTER, r: Rune(ch))
  template emit_eof =
    emit EOF
    break
  template emit_tok =
    if tokenizer.attr:
      tokenizer.tok.attrs[tokenizer.attrn] = tokenizer.attrv
    emit tokenizer.tok
  template emit_current =
    if tokenizer.atEof:
      emit_eof
    else:
      emit Token(t: CHARACTER, r: tokenizer.curr)
  template emit_replacement = emit Rune(0xFFFD)
  template switch_state(s: TokenizerState) =
    tokenizer.state = s
  template switch_state_return(s: TokenizerState) =
    tokenizer.rstate = tokenizer.state
    tokenizer.state = s
  template reconsume_in(s: TokenizerState) =
    tokenizer.reconsume()
    switch_state s
  template parse_error(error: untyped) = discard # does nothing for now... TODO?
  template is_appropriate_end_tag_token(): bool =
    tokenizer.laststart != nil and tokenizer.laststart.data == tokenizer.tok.data
  template start_new_attribute =
    if tokenizer.attr:
      tokenizer.tok.attrs[tokenizer.attrn] = tokenizer.attrv
    tokenizer.attrn = ""
    tokenizer.attrv = ""
    tokenizer.attr = true
  template leave_attribute_name_state =
    if tokenizer.attrn in tokenizer.tok.attrs:
      tokenizer.attr = false
  template append_to_current_attr_value(c: typed) =
    if tokenizer.attr:
      tokenizer.attrv &= c
  template peek_str(s: string): bool =
    # WARNING: will break on strings with copyBufSize + 4 bytes
    assert s.len < copyBufSize - 4 and s.len > 0
    if tokenizer.sbuf_i + s.len > tokenizer.eof_i:
      false
    else:
      let slice = tokenizer.sbuf[tokenizer.sbuf_i..tokenizer.sbuf_i+s.high]
      s == slice
  template peek_str_nocase(s: string): bool =
    # WARNING: will break on strings with copyBufSize + 4 bytes
    # WARNING: only works with UPPER CASE ascii
    assert s.len < copyBufSize - 4 and s.len > 0
    if tokenizer.sbuf_i + s.len > tokenizer.eof_i:
      false
    else:
      let slice = tokenizer.sbuf[tokenizer.sbuf_i..tokenizer.sbuf_i+s.high]
      s == slice.toUpperAscii()
  template peek_char(): char = tokenizer.sbuf[tokenizer.sbuf_i]
  template has_adjusted_current_node(): bool = false #TODO implement this
  template consume_and_discard(n: int) = #TODO optimize
    var i = 0
    while i < n:
      discard tokenizer.consume()
      inc i
  template consumed_as_an_attribute(): bool =
    tokenizer.rstate in {ATTRIBUTE_VALUE_DOUBLE_QUOTED, ATTRIBUTE_VALUE_SINGLE_QUOTED, ATTRIBUTE_VALUE_UNQUOTED}
  template flush_code_points_consumed_as_a_character_reference() =
    if consumed_as_an_attribute:
      append_to_current_attr_value tokenizer.tmp
    else:
      for r in tokenizer.tmp.runes:
        emit r
  template new_token(t: Token) =
    if tokenizer.attr:
      tokenizer.attr = false
    tokenizer.tok = t

  # Fake EOF as an actual character. Also replace anything_else with the else
  # branch.
  # Yes this is kind of ugly but it works and I'm too lazy to come up with
  # anything better.
  macro stateMachine(states: varargs[untyped]): untyped =
    var maincase = newNimNode(nnkCaseStmt).add(quote do: tokenizer.state)
    for state in states:
      if state.kind == nnkOfBranch:
        let mainstmtlist = findChild(state, it.kind == nnkStmtList)
        if mainstmtlist[0].kind == nnkIdent and mainstmtlist[0].strVal == "ignore_eof":
          maincase.add(state)
          continue

        var hasanythingelse = false
        if mainstmtlist[0].kind == nnkIdent and mainstmtlist[0].strVal == "has_anything_else":
          hasanythingelse = true

        let childcase = findChild(mainstmtlist, it.kind == nnkCaseStmt)
        var haseof = false
        var eofstmts: NimNode
        var elsestmts: NimNode

        for i in countdown(childcase.len-1, 0):
          let childof = childcase[i]
          if childof.kind == nnkOfBranch:
            for j in countdown(childof.len-1, 0):
              if childof[j].kind == nnkIdent and childof[j].strVal == "eof":
                haseof = true
                eofstmts = childof.findChild(it.kind == nnkStmtList)
                if childof.findChild(it.kind == nnkIdent and it.strVal != "eof") != nil:
                  childof.del(j)
                else:
                  childcase.del(i)
          elif childof.kind == nnkElse:
            elsestmts = childof.findChild(it.kind == nnkStmtList)

        if not haseof:
          eofstmts = elsestmts
        let fake_eof = quote do:
          if tokenizer.atEof:
            `eofstmts`
            continue
        mainstmtlist.insert(0, fake_eof)
        if hasanythingelse:
          let fake_anything_else = quote do:
            template anything_else =
              `elsestmts`
          mainstmtlist.insert(0, fake_anything_else)
      maincase.add(state)
    result = newNimNode(nnkStmtList)
    result.add(maincase)

  template ignore_eof = discard # does nothing
  template has_anything_else = discard # does nothing

  const null = char(0)
  const whitespace = {'\t', '\n', '\f', ' '}

  while true:
    {.computedGoto.}
    let c = tokenizer.consume()
    stateMachine: # => case tokenizer.state
    of DATA:
      case c
      of '&': switch_state_return CHARACTER_REFERENCE
      of '<': switch_state TAG_OPEN
      of null:
        parse_error unexpected_null_character
        emit_current
      of eof: emit_eof
      else: emit_current

    of RCDATA:
      case c
      of '&': switch_state_return CHARACTER_REFERENCE
      of '<': switch_state RCDATA_LESS_THAN_SIGN
      of null: parse_error unexpected_null_character
      of eof: emit_eof
      else: emit_current

    of RAWTEXT:
      case c
      of '<': switch_state RAWTEXT_LESS_THAN_SIGN
      of null:
        parse_error unexpected_null_character
        emit_replacement
      of eof: emit_eof
      else: emit_current

    of SCRIPT_DATA:
      case c
      of '<': switch_state SCRIPT_DATA_LESS_THAN_SIGN
      of null:
        parse_error unexpected_null_character
        emit_replacement
      of eof: emit_eof
      else: emit_current

    of PLAINTEXT:
      case c
      of null:
        parse_error unexpected_null_character
        emit_replacement
      of eof: emit_eof
      else: emit_current

    of TAG_OPEN:
      case c
      of '!': switch_state MARKUP_DECLARATION_OPEN
      of '/': switch_state END_TAG_OPEN
      of AsciiAlpha:
        new_token Token(t: START_TAG)
        reconsume_in TAG_NAME
      of '?':
        parse_error unexpected_question_mark_instead_of_tag_name
        new_token Token(t: COMMENT)
        reconsume_in BOGUS_COMMENT
      of eof:
        parse_error eof_before_tag_name
        emit '<'
        emit_eof
      else:
        parse_error invalid_first_character_of_tag_name
        emit '<'
        reconsume_in DATA

    of END_TAG_OPEN:
      case c
      of AsciiAlpha: new_token Token(t: END_TAG)
      of '>':
        parse_error missing_end_tag_name
        switch_state DATA
      of eof:
        parse_error eof_before_tag_name
        emit '<'
        emit '/'
        emit_eof
      else:
        parse_error invalid_first_character_of_tag_name
        new_token Token(t: COMMENT)
        reconsume_in BOGUS_COMMENT

    of TAG_NAME:
      case c
      of whitespace: switch_state BEFORE_ATTRIBUTE_NAME
      of '/': switch_state SELF_CLOSING_START_TAG
      of '>':
        switch_state DATA
        emit_tok
      of AsciiUpperAlpha: tokenizer.tok.tagname &= char(tokenizer.curr).tolower()
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.tagname &= Rune(0xFFFD)
      of eof:
        parse_error eof_in_tag
        emit_eof
      else: tokenizer.tok.tagname &= tokenizer.curr

    of RCDATA_LESS_THAN_SIGN:
      case c
      of '/':
        tokenizer.tmp = ""
        switch_state RCDATA_END_TAG_OPEN
      else:
        emit '<'
        reconsume_in RCDATA

    of RCDATA_END_TAG_OPEN:
      case c
      of AsciiAlpha:
        new_token Token(t: END_TAG)
        reconsume_in RCDATA_END_TAG_NAME
      else:
        emit '<'
        emit '/'
        reconsume_in RCDATA

    of RCDATA_END_TAG_NAME:
      has_anything_else
      case c
      of whitespace:
        if is_appropriate_end_tag_token:
          switch_state BEFORE_ATTRIBUTE_NAME
        else:
          anything_else
      of '/':
        if is_appropriate_end_tag_token:
          switch_state SELF_CLOSING_START_TAG
        else:
          anything_else
      of '>':
        if is_appropriate_end_tag_token:
          switch_state DATA
      of AsciiAlpha: # note: merged upper & lower
        tokenizer.tok.tagname &= char(tokenizer.curr).tolower()
        tokenizer.tmp &= tokenizer.curr
      else:
        new_token nil #TODO
        emit '<'
        emit '/'
        for r in tokenizer.tmp.runes:
          emit r
        reconsume_in RCDATA

    of RAWTEXT_LESS_THAN_SIGN:
      case c
      of '/':
        tokenizer.tmp = ""
        switch_state RAWTEXT_END_TAG_OPEN
      else:
        emit '<'
        reconsume_in RAWTEXT

    of RAWTEXT_END_TAG_OPEN:
      case c
      of AsciiAlpha:
        new_token Token(t: END_TAG)
        reconsume_in RAWTEXT_END_TAG_NAME
      else:
        emit '<'
        emit '/'
        reconsume_in RAWTEXT

    of RAWTEXT_END_TAG_NAME:
      has_anything_else
      case c
      of whitespace:
        if is_appropriate_end_tag_token:
          switch_state BEFORE_ATTRIBUTE_NAME
        else:
          anything_else
      of '/':
        if is_appropriate_end_tag_token:
          switch_state SELF_CLOSING_START_TAG
        else:
          anything_else
      of '>':
        if is_appropriate_end_tag_token:
          switch_state DATA
          emit_tok
        else:
          anything_else
      of AsciiAlpha: # note: merged upper & lower
        tokenizer.tok.tagname &= char(tokenizer.curr).tolower()
        tokenizer.tmp &= tokenizer.curr
      else:
        new_token nil #TODO
        emit '<'
        emit '/'
        for r in tokenizer.tmp.runes:
          emit r
        reconsume_in RAWTEXT

    of SCRIPT_DATA_LESS_THAN_SIGN:
      case c
      of '/':
        tokenizer.tmp = ""
        switch_state SCRIPT_DATA_END_TAG_OPEN
      of '!':
        switch_state SCRIPT_DATA_ESCAPE_START
        emit '<'
        emit '!'
      else:
        emit '<'
        reconsume_in SCRIPT_DATA

    of SCRIPT_DATA_END_TAG_OPEN:
      case c
      of AsciiAlpha:
        new_token Token(t: END_TAG)
        reconsume_in SCRIPT_DATA_END_TAG_NAME
      else:
        emit '<'
        emit '/'
        reconsume_in SCRIPT_DATA

    of SCRIPT_DATA_END_TAG_NAME:
      has_anything_else
      case c
      of whitespace:
        if is_appropriate_end_tag_token:
          switch_state BEFORE_ATTRIBUTE_NAME
        else:
          anything_else
      of '/':
        if is_appropriate_end_tag_token:
          switch_state SELF_CLOSING_START_TAG
        else:
          anything_else
      of '>':
        if is_appropriate_end_tag_token:
          switch_state DATA
          emit_tok
        else:
          anything_else
      of AsciiAlpha: # note: merged upper & lower
        tokenizer.tok.tagname &= char(tokenizer.curr).tolower()
        tokenizer.tmp &= tokenizer.curr
      else:
        emit '<'
        emit '/'
        for r in tokenizer.tmp.runes:
          emit r
        reconsume_in SCRIPT_DATA

    of SCRIPT_DATA_ESCAPE_START:
      case c
      of '-':
        switch_state SCRIPT_DATA_ESCAPE_START_DASH
        emit '-'
      else:
        reconsume_in SCRIPT_DATA

    of SCRIPT_DATA_ESCAPE_START_DASH:
      case c
      of '-':
        switch_state SCRIPT_DATA_ESCAPED_DASH_DASH
        emit '-'
      else:
        reconsume_in SCRIPT_DATA

    of SCRIPT_DATA_ESCAPED:
      case c
      of '-':
        switch_state SCRIPT_DATA_ESCAPED_DASH
        emit '-'
      of '<':
        switch_state SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN
      of null:
        parse_error unexpected_null_character
        emit_replacement
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else:
        emit_current

    of SCRIPT_DATA_ESCAPED_DASH:
      case c
      of '-':
        switch_state SCRIPT_DATA_ESCAPED_DASH_DASH
        emit '-'
      of '<':
        switch_state SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN
      of null:
        parse_error unexpected_null_character
        switch_state SCRIPT_DATA_ESCAPED
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else:
        switch_state SCRIPT_DATA_ESCAPED
        emit_current

    of SCRIPT_DATA_ESCAPED_DASH_DASH:
      case c
      of '-':
        emit '-'
      of '<':
        switch_state SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN
      of '>':
        switch_state SCRIPT_DATA
        emit '>'
      of null:
        parse_error unexpected_null_character
        switch_state SCRIPT_DATA_ESCAPED
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else:
        switch_state SCRIPT_DATA_ESCAPED
        emit_current

    of SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN:
      case c
      of '/':
        tokenizer.tmp = ""
        switch_state SCRIPT_DATA_ESCAPED_END_TAG_OPEN
      of AsciiAlpha:
        tokenizer.tmp = ""
        emit '<'
        reconsume_in SCRIPT_DATA_DOUBLE_ESCAPE_START
      else:
        emit '<'
        reconsume_in SCRIPT_DATA_ESCAPED

    of SCRIPT_DATA_ESCAPED_END_TAG_OPEN:
      case c
      of AsciiAlpha:
        new_token Token(t: START_TAG)
        reconsume_in SCRIPT_DATA_ESCAPED_END_TAG_NAME
      else:
        emit '<'
        emit '/'
        reconsume_in SCRIPT_DATA_ESCAPED

    of SCRIPT_DATA_ESCAPED_END_TAG_NAME:
      has_anything_else
      case c
      of whitespace:
        if is_appropriate_end_tag_token:
          switch_state BEFORE_ATTRIBUTE_NAME
        else:
          anything_else
      of '/':
        if is_appropriate_end_tag_token:
          switch_state SELF_CLOSING_START_TAG
        else:
          anything_else
      of '>':
        if is_appropriate_end_tag_token:
          switch_state DATA
        else:
          anything_else
      of AsciiAlpha:
        tokenizer.tok.tagname &= char(tokenizer.curr).tolower()
        tokenizer.tmp &= tokenizer.curr
      else:
        emit '<'
        emit '/'
        for r in tokenizer.tmp.runes:
          emit r
        reconsume_in SCRIPT_DATA_ESCAPED

    of SCRIPT_DATA_DOUBLE_ESCAPE_START:
      case c
      of whitespace, '/', '>':
        if tokenizer.tmp == "script":
          switch_state SCRIPT_DATA_DOUBLE_ESCAPED
        else:
          switch_state SCRIPT_DATA_ESCAPED
          emit_current
      of AsciiAlpha: # note: merged upper & lower
        tokenizer.tmp &= c.tolower()
        emit_current
      else: reconsume_in SCRIPT_DATA_ESCAPED

    of SCRIPT_DATA_DOUBLE_ESCAPED:
      case c
      of '-':
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED_DASH
        emit '-'
      of '<':
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN
        emit '<'
      of null:
        parse_error unexpected_null_character
        emit_replacement
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else: emit_current

    of SCRIPT_DATA_DOUBLE_ESCAPED_DASH:
      case c
      of '-':
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH
        emit '-'
      of '<':
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN
        emit '<'
      of null:
        parse_error unexpected_null_character
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED
        emit_replacement
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else:
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED
        emit_current

    of SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH:
      case c
      of '-': emit '-'
      of '<':
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN
        emit '<'
      of '>':
        switch_state SCRIPT_DATA
        emit '>'
      of null:
        parse_error unexpected_null_character
        switch_state SCRIPT_DATA_DOUBLE_ESCAPED
        emit_replacement
      of eof:
        parse_error eof_in_script_html_comment_like_text
        emit_eof
      else: switch_state SCRIPT_DATA_DOUBLE_ESCAPED

    of SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN:
      case c
      of '/':
        tokenizer.tmp = ""
        switch_state SCRIPT_DATA_DOUBLE_ESCAPE_END
        emit '/'
      else: reconsume_in SCRIPT_DATA_DOUBLE_ESCAPED

    of SCRIPT_DATA_DOUBLE_ESCAPE_END:
      case c
      of whitespace, '/', '>':
        if tokenizer.tmp == "script":
          switch_state SCRIPT_DATA_ESCAPED
        else:
          switch_state SCRIPT_DATA_DOUBLE_ESCAPED
          emit_current
      of AsciiAlpha: # note: merged upper & lower
        tokenizer.tmp &= c.tolower()
        emit_current
      else:
        reconsume_in SCRIPT_DATA_DOUBLE_ESCAPED

    of BEFORE_ATTRIBUTE_NAME:
      case c
      of whitespace: discard
      of '/', '>', eof: reconsume_in AFTER_ATTRIBUTE_NAME
      of '=':
        parse_error unexpected_equals_sign_before_attribute_name
        start_new_attribute
        switch_state ATTRIBUTE_NAME
      else:
        start_new_attribute
        reconsume_in ATTRIBUTE_NAME

    of ATTRIBUTE_NAME:
      has_anything_else
      case c
      of whitespace, '/', '>', eof:
        leave_attribute_name_state
        reconsume_in AFTER_ATTRIBUTE_NAME
      of '=':
        leave_attribute_name_state
        switch_state BEFORE_ATTRIBUTE_VALUE
      of AsciiUpperAlpha:
        tokenizer.attrn &= c.tolower()
      of null:
        parse_error unexpected_null_character
        tokenizer.attrn &= Rune(0xFFFD)
      of '"', '\'', '<':
        parse_error unexpected_character_in_attribute_name
        anything_else
      else:
        tokenizer.attrn &= tokenizer.curr

    of AFTER_ATTRIBUTE_NAME:
      case c
      of whitespace: discard
      of '/': switch_state SELF_CLOSING_START_TAG
      of '=': switch_state BEFORE_ATTRIBUTE_VALUE
      of '>':
        switch_state DATA
        emit '>'
      of eof:
        parse_error eof_in_tag
        emit_eof
      else:
        start_new_attribute
        reconsume_in ATTRIBUTE_NAME

    of BEFORE_ATTRIBUTE_VALUE:
      case c
      of whitespace: discard
      of '"': switch_state ATTRIBUTE_VALUE_DOUBLE_QUOTED
      of '\'': switch_state ATTRIBUTE_VALUE_SINGLE_QUOTED
      of '>':
        parse_error missing_attribute_value
        switch_state DATA
        emit '>'
      else: reconsume_in ATTRIBUTE_VALUE_UNQUOTED

    of ATTRIBUTE_VALUE_DOUBLE_QUOTED:
      case c
      of '"': switch_state AFTER_ATTRIBUTE_VALUE_QUOTED
      of '&': switch_state_return CHARACTER_REFERENCE
      of null:
        parse_error unexpected_null_character
        append_to_current_attr_value Rune(0xFFFD)
      of eof:
        parse_error eof_in_tag
        emit_eof
      else: append_to_current_attr_value tokenizer.curr

    of ATTRIBUTE_VALUE_SINGLE_QUOTED:
      case c
      of '\'': switch_state AFTER_ATTRIBUTE_VALUE_QUOTED
      of '&': switch_state_return CHARACTER_REFERENCE
      of null:
        parse_error unexpected_null_character
        append_to_current_attr_value Rune(0xFFFD)
      of eof:
        parse_error eof_in_tag
        emit_eof
      else: append_to_current_attr_value tokenizer.curr

    of ATTRIBUTE_VALUE_UNQUOTED:
      case c
      of whitespace: switch_state BEFORE_ATTRIBUTE_NAME
      of '&': switch_state_return CHARACTER_REFERENCE
      of '>': switch_state DATA
      of null:
        parse_error unexpected_null_character
        append_to_current_attr_value Rune(0xFFFD)
      of '"', '\'', '<', '=', '`':
        parse_error unexpected_character_in_unquoted_attribute_value
        append_to_current_attr_value c
      of eof:
        parse_error eof_in_tag
        emit_eof
      else: append_to_current_attr_value tokenizer.curr

    of AFTER_ATTRIBUTE_VALUE_QUOTED:
      case c
      of whitespace:
        switch_state BEFORE_ATTRIBUTE_NAME
      of '/':
        switch_state SELF_CLOSING_START_TAG
      of '>':
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_tag
        emit_eof
      else: append_to_current_attr_value tokenizer.curr

    of SELF_CLOSING_START_TAG:
      case c
      of '>':
        tokenizer.tok.selfclosing = true
        switch_state DATA
        emit '>'
      of eof:
        parse_error eof_in_tag
        emit_eof
      else:
        parse_error unexpected_solidus_in_tag
        reconsume_in BEFORE_ATTRIBUTE_NAME

    of BOGUS_COMMENT:
      assert tokenizer.tok.t == COMMENT
      case c
      of '>':
        switch_state DATA
        emit_tok
      of eof:
        emit_tok
        emit_eof
      of null: parse_error unexpected_null_character
      else: tokenizer.tok.data &= tokenizer.curr

    of MARKUP_DECLARATION_OPEN: # note: rewritten to fit case model as we consume a char anyway
      has_anything_else
      case c
      of '-':
        if peek_char == '-':
          new_token Token(t: COMMENT)
          tokenizer.state = COMMENT_START
          consume_and_discard 1
        else: anything_else
      of 'D', 'd':
        if peek_str_nocase("OCTYPE"):
          consume_and_discard "OCTYPE".len
          switch_state DOCTYPE
        else: anything_else
      of '[':
        if peek_str("CDATA["):
          consume_and_discard "CDATA[".len
          if has_adjusted_current_node: #TODO and it is not an element in the HTML namespace
            switch_state CDATA_SECTION
          else:
            parse_error cdata_in_html_content
            new_token Token(t: COMMENT, data: "[CDATA[")
            switch_state BOGUS_COMMENT
        else: anything_else
      else:
        parse_error incorrectly_opened_comment
        new_token Token(t: COMMENT)
        reconsume_in BOGUS_COMMENT

    of COMMENT_START:
      case c
      of '-': switch_state COMMENT_START_DASH
      of '>':
        parse_error abrupt_closing_of_empty_comment
        switch_state DATA
        emit_tok
      else: reconsume_in COMMENT

    of COMMENT_START_DASH:
      case c
      of '-': switch_state COMMENT_END
      of '>':
        parse_error abrupt_closing_of_empty_comment
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_comment
        emit_tok
        emit_eof
      else:
        tokenizer.tok.data &= '-'
        reconsume_in COMMENT

    of COMMENT:
      case c
      of '<':
        tokenizer.tok.data &= c
        switch_state COMMENT_LESS_THAN_SIGN
      of '-': switch_state COMMENT_END_DASH
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.data &= Rune(0xFFFD)
      of eof:
        parse_error eof_in_comment
        emit_tok
        emit_eof
      else: tokenizer.tok.data &= tokenizer.curr

    of COMMENT_LESS_THAN_SIGN:
      case c
      of '!':
        tokenizer.tok.data &= c
        switch_state COMMENT_LESS_THAN_SIGN_BANG
      of '<': tokenizer.tok.data &= c
      else: reconsume_in COMMENT

    of COMMENT_LESS_THAN_SIGN_BANG:
      case c
      of '-': switch_state COMMENT_LESS_THAN_SIGN_BANG_DASH
      else: reconsume_in COMMENT

    of COMMENT_LESS_THAN_SIGN_BANG_DASH:
      case c
      of '-': switch_state COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH
      else: reconsume_in COMMENT_END_DASH

    of COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH:
      case c
      of '>', eof: reconsume_in COMMENT_END
      else:
        parse_error nested_comment
        reconsume_in COMMENT_END

    of COMMENT_END_DASH:
      case c
      of '-': switch_state COMMENT_END
      of eof:
        parse_error eof_in_comment
        emit_tok
        emit_eof
      else:
        tokenizer.tok.data &= '-'
        reconsume_in COMMENT

    of COMMENT_END:
      case c
      of '>': switch_state DATA
      of '!': switch_state COMMENT_END_BANG
      of '-': tokenizer.tok.data &= '-'
      of eof:
        parse_error eof_in_comment
        emit_tok
        emit_eof
      else:
        tokenizer.tok.data &= "--"
        reconsume_in COMMENT

    of COMMENT_END_BANG:
      case c
      of '-':
        tokenizer.tok.data &= "--!"
        switch_state COMMENT_END_DASH
      of '>':
        parse_error incorrectly_closed_comment
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_comment
        emit_tok
        emit_eof
      else:
        tokenizer.tok.data &= "--!"
        reconsume_in COMMENT

    of DOCTYPE:
      case c
      of whitespace: switch_state BEFORE_DOCTYPE_NAME
      of '>': reconsume_in BEFORE_DOCTYPE_NAME
      of eof:
        parse_error eof_in_doctype
        new_token Token(t: DOCTYPE, quirks: true)
        emit_tok
        emit_eof
      else:
        parse_error missing_whitespace_before_doctype_name
        reconsume_in BEFORE_DOCTYPE_NAME

    of BEFORE_DOCTYPE_NAME:
      case c
      of whitespace: discard
      of AsciiUpperAlpha:
        new_token Token(t: DOCTYPE, name: some($c.tolower()))
        switch_state DOCTYPE_NAME
      of null:
        parse_error unexpected_null_character
        new_token Token(t: DOCTYPE, name: some($Rune(0xFFFD)))
      of '>':
        parse_error missing_doctype_name
        new_token Token(t: DOCTYPE, quirks: true)
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        new_token Token(t: DOCTYPE, quirks: true)
        emit_tok
        emit_eof
      else:
        new_token Token(t: DOCTYPE, name: some($tokenizer.curr))
        switch_state DOCTYPE_NAME

    of DOCTYPE_NAME:
      case c
      of whitespace: switch_state AFTER_DOCTYPE_NAME
      of '>':
        switch_state DATA
        emit_tok
      of AsciiUpperAlpha:
        tokenizer.tok.name.get &= c.tolower()
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.name.get &= Rune(0xFFFD)
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        tokenizer.tok.name.get &= tokenizer.curr

    of AFTER_DOCTYPE_NAME: # note: rewritten to fit case model as we consume a char anyway
      has_anything_else
      case c
      of whitespace: discard
      of '>':
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      of 'p', 'P':
        if peek_str("UBLIC"):
          consume_and_discard "UBLIC".len
          switch_state AFTER_DOCTYPE_PUBLIC_KEYWORD
        else:
          anything_else
      of 's', 'S':
        if peek_str("YSTEM"):
          consume_and_discard "YSTEM".len
          switch_state AFTER_DOCTYPE_SYSTEM_KEYWORD
        else:
          anything_else
      else:
        parse_error invalid_character_sequence_after_doctype_name
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of AFTER_DOCTYPE_PUBLIC_KEYWORD:
      case c
      of whitespace: switch_state BEFORE_DOCTYPE_PUBLIC_IDENTIFIER
      of '"':
        parse_error missing_whitespace_after_doctype_public_keyword
        tokenizer.tok.pubid = some("")
        switch_state DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED
      of '>':
        parse_error missing_doctype_public_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_public_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of BEFORE_DOCTYPE_PUBLIC_IDENTIFIER:
      case c
      of whitespace: discard
      of '"':
        tokenizer.tok.pubid = some("")
        switch_state DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED
      of '\'':
        tokenizer.tok.pubid = some("")
        switch_state DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED
      of '>':
        parse_error missing_doctype_public_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_public_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED:
      case c
      of '"': switch_state AFTER_DOCTYPE_PUBLIC_IDENTIFIER
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.pubid.get &= Rune(0xFFFD)
      of '>':
        parse_error abrupt_doctype_public_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        tokenizer.tok.pubid.get &= tokenizer.curr

    of DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED:
      case c
      of '\'': switch_state AFTER_DOCTYPE_PUBLIC_IDENTIFIER
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.pubid.get &= Rune(0xFFFD)
      of '>':
        parse_error abrupt_doctype_public_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        tokenizer.tok.pubid.get &= tokenizer.curr

    of AFTER_DOCTYPE_PUBLIC_IDENTIFIER:
      case c
      of whitespace: switch_state BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS
      of '>':
        switch_state DATA
        emit_tok
      of '"':
        parse_error missing_whitespace_between_doctype_public_and_system_identifiers
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED
      of '\'':
        parse_error missing_whitespace_between_doctype_public_and_system_identifiers
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_system_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS:
      case c
      of whitespace: discard
      of '>':
        switch_state DATA
        emit_tok
      of '"':
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED
      of '\'':
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_system_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of AFTER_DOCTYPE_SYSTEM_KEYWORD:
      case c
      of whitespace: switch_state BEFORE_DOCTYPE_SYSTEM_IDENTIFIER
      of '"':
        parse_error missing_whitespace_after_doctype_system_keyword
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED
      of '\'':
        parse_error missing_whitespace_after_doctype_system_keyword
        tokenizer.tok.sysid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED
      of '>':
        parse_error missing_doctype_system_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_system_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of BEFORE_DOCTYPE_SYSTEM_IDENTIFIER:
      case c
      of whitespace: discard
      of '"':
        tokenizer.tok.pubid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED
      of '\'':
        tokenizer.tok.pubid = some("")
        switch_state DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED
      of '>':
        parse_error missing_doctype_system_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error missing_quote_before_doctype_system_identifier
        tokenizer.tok.quirks = true
        reconsume_in BOGUS_DOCTYPE

    of DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED:
      case c
      of '"': switch_state AFTER_DOCTYPE_SYSTEM_IDENTIFIER
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.sysid.get &= Rune(0xFFFD)
      of '>':
        parse_error abrupt_doctype_system_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        tokenizer.tok.sysid.get &= tokenizer.curr

    of DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED:
      case c
      of '\'': switch_state AFTER_DOCTYPE_SYSTEM_IDENTIFIER
      of null:
        parse_error unexpected_null_character
        tokenizer.tok.sysid.get &= Rune(0xFFFD)
      of '>':
        parse_error abrupt_doctype_system_identifier
        tokenizer.tok.quirks = true
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        tokenizer.tok.sysid.get &= tokenizer.curr

    of AFTER_DOCTYPE_SYSTEM_IDENTIFIER:
      case c
      of whitespace: discard
      of '>':
        switch_state DATA
        emit_tok
      of eof:
        parse_error eof_in_doctype
        tokenizer.tok.quirks = true
        emit_tok
        emit_eof
      else:
        parse_error unexpected_character_after_doctype_system_identifier
        reconsume_in BOGUS_DOCTYPE

    of BOGUS_DOCTYPE:
      case c
      of '>':
        switch_state DATA
        emit_tok
      of null: parse_error unexpected_null_character
      of eof:
        emit_tok
        emit_eof
      else: discard

    of CDATA_SECTION:
      case c
      of ']': switch_state CDATA_SECTION_BRACKET
      of eof:
        parse_error eof_in_cdata
        emit_eof
      else:
        emit_current

    of CDATA_SECTION_BRACKET:
      case c
      of ']': switch_state CDATA_SECTION_END
      of '>': switch_state DATA
      else:
        emit ']'
        reconsume_in CDATA_SECTION

    of CDATA_SECTION_END:
      case c
      of ']': emit ']'
      of '>': switch_state DATA
      else:
        emit ']'
        emit ']'
        reconsume_in CDATA_SECTION

    of CHARACTER_REFERENCE:
      tokenizer.tmp = "&"
      case c
      of AsciiAlpha: reconsume_in NAMED_CHARACTER_REFERENCE
      of '#':
        tokenizer.tmp &= '#'
        switch_state NUMERIC_CHARACTER_REFERENCE
      else:
        flush_code_points_consumed_as_a_character_reference
        reconsume_in tokenizer.rstate

    of NAMED_CHARACTER_REFERENCE:
      ignore_eof # we check for eof ourselves
      tokenizer.reconsume() #TODO optimize this away
      var buf = ""
      var node = entityMap
      var value = none(string) # last value
      var match = true
      #TODO interfacing with RadixNode is suffering
      # plus this doesn't look very efficient either
      while not tokenizer.atEof:
        let c = tokenizer.consume()
        buf &= c
        if not node.hasPrefix(buf):
          break
        let prevnode = node
        node = node{buf}
        if node != prevnode:
          buf = ""
          if node.value.issome:
            value = node.value
        tokenizer.tmp &= tokenizer.curr
      if value.issome:
        if consumed_as_an_attribute and tokenizer.tmp[^1] != ';' and peek_char in {';'} + AsciiAlpha:
          flush_code_points_consumed_as_a_character_reference
          switch_state tokenizer.rstate
        else:
          if tokenizer.tmp[^1] != ';':
            parse_error missing_semicolon_after_character_reference_parse_error
            tokenizer.tmp = node.value.get
            flush_code_points_consumed_as_a_character_reference
            switch_state tokenizer.rstate
      else:
        flush_code_points_consumed_as_a_character_reference
        switch_state AMBIGUOUS_AMPERSAND_STATE

    of AMBIGUOUS_AMPERSAND_STATE:
      case c
      of AsciiAlpha:
        if consumed_as_an_attribute:
          append_to_current_attr_value c
        else:
          emit_current
      of ';':
        parse_error unknown_named_character_reference
        reconsume_in tokenizer.rstate
      else: reconsume_in tokenizer.rstate

    of NUMERIC_CHARACTER_REFERENCE:
      tokenizer.code = 0
      case c
      of 'x', 'X':
        tokenizer.tmp &= c
        switch_state HEXADECIMAL_CHARACTER_REFERENCE_START
      else: reconsume_in DECIMAL_CHARACTER_REFERENCE_START

    of HEXADECIMAL_CHARACTER_REFERENCE_START:
      case c
      of AsciiHexDigit: reconsume_in HEXADECIMAL_CHARACTER_REFERENCE
      else:
        parse_error absence_of_digits_in_numeric_character_reference
        flush_code_points_consumed_as_a_character_reference
        reconsume_in tokenizer.rstate

    of DECIMAL_CHARACTER_REFERENCE_START:
      case c
      of AsciiDigit: reconsume_in DECIMAL_CHARACTER_REFERENCE
      else:
        parse_error absence_of_digits_in_numeric_character_reference
        flush_code_points_consumed_as_a_character_reference
        reconsume_in tokenizer.rstate

    of HEXADECIMAL_CHARACTER_REFERENCE:
      case c
      of AsciiHexDigit: # note: merged digit, upper hex, lower hex
        tokenizer.code *= 0x10
        tokenizer.code += hexValue(c)
      of ';': switch_state NUMERIC_CHARACTER_REFERENCE_END
      else:
        parse_error missing_semicolon_after_character_reference
        reconsume_in NUMERIC_CHARACTER_REFERENCE_END

    of DECIMAL_CHARACTER_REFERENCE:
      case c
      of AsciiDigit:
        tokenizer.code *= 10
        tokenizer.code += decValue(c)
      of ';': switch_state NUMERIC_CHARACTER_REFERENCE_END
      else:
        parse_error missing_semicolon_after_character_reference
        reconsume_in NUMERIC_CHARACTER_REFERENCE_END

    of NUMERIC_CHARACTER_REFERENCE_END:
      ignore_eof # we reconsume anyway
      case tokenizer.code
      of 0x00:
        parse_error null_character_reference
        tokenizer.code = 0xFFFD
      elif tokenizer.code > 0x10FFFF:
        parse_error character_reference_outside_unicode_range
        tokenizer.code = 0xFFFD
      elif Rune(tokenizer.code).isSurrogate():
        parse_error surrogate_character_reference
        tokenizer.code = 0xFFFD
      elif Rune(tokenizer.code).isNonCharacter():
        parse_error noncharacter_character_reference
        # do nothing
      elif tokenizer.code in 0..255 and char(tokenizer.code) in ((Controls - AsciiWhitespace) + {chr(0x0D)}):
        const ControlMapTable = [
          (0x80, 0x20AC), (0x82, 0x201A), (0x83, 0x0192), (0x84, 0x201E),
          (0x85, 0x2026), (0x86, 0x2020), (0x87, 0x2021), (0x88, 0x02C6),
          (0x89, 0x2030), (0x8A, 0x0160), (0x8B, 0x2039), (0x8C, 0x0152),
          (0x8E, 0x017D), (0x91, 0x2018), (0x92, 0x2019), (0x93, 0x201C),
          (0x94, 0x201D), (0x95, 0x2022), (0x96, 0x2013), (0x97, 0x2014),
          (0x98, 0x02DC), (0x99, 0x2122), (0x9A, 0x0161), (0x9B, 0x203A),
          (0x9C, 0x0153), (0x9E, 0x017E), (0x9F, 0x0178),
        ].toTable()
        if ControlMapTable.hasKey(tokenizer.code):
          tokenizer.code = ControlMapTable[tokenizer.code]
      tokenizer.tmp = $Rune(tokenizer.code)
      flush_code_points_consumed_as_a_character_reference #TODO optimize so we flush directly
      reconsume_in tokenizer.rstate # we unnecessarily consumed once so reconsume

func inputSize*(str: string): int =
  if str.len == 0:
    return 20
  for c in str:
    if not c.isDigit:
      return 20
  return str.parseInt()

#w3m's getescapecmd and parse_tag, transpiled to nim and heavily modified.
#(C) Copyright 1994-2002 by Akinori Ito
#(C) Copyright 2002-2011 by Akinori Ito, Hironori Sakamoto, Fumitoshi Ukai
#
#Use, modification and redistribution of this software is hereby granted,
#provided that this entire copyright notice is included on any copies of
#this software and applications and derivations thereof.
#
#This software is provided on an "as is" basis, without warranty of any
#kind, either expressed or implied, as to any matter including, but not
#limited to warranty of fitness of purpose, or merchantability, or
#results obtained from use of this software.
proc getescapecmd(buf: string, at: var int): string =
  var i = at

  if buf[i] == '#': #num
    inc i
    var num: int
    if buf[i].tolower() == 'x': #hex
      inc i
      if not isdigit(buf[i]):
        at = i
        return "&"

      num = hexValue(buf[i])
      inc i
      while i < buf.len and hexValue(buf[i]) != -1:
        num *= 0x10
        num += hexValue(buf[i])
        inc i
    else: #dec
      if not isDigit(buf[i]):
        at = i
        return "&"

      num = decValue(buf[i])
      inc i
      while i < buf.len and isDigit(buf[i]):
        num *= 10
        num += decValue(buf[i])
        inc i

    if buf[i] == ';':
      inc i
    at = i
    return $(Rune(num))
  elif not isAlphaAscii(buf[i]):
    return "&"

  var n = entityMap
  var s = ""
  while true:
    s &= buf[i]
    if not n.hasPrefix(s):
      break
    let pn = n
    n = n{s}
    if n != pn:
      s = ""
    inc i

  if n.value.issome:
    at = i
    return n.value.get

  return "&"

type
  DOMParsedTag = object
    tagid: TagType
    attrs: Table[string, string]
    open: bool

proc parse_tag(buf: string, at: var int): DOMParsedTag =
  var tag = DOMParsedTag()
  tag.open = true

  #Parse tag name
  var tagname = ""
  inc at
  if buf[at] == '/':
    inc at
    tag.open = false
    at = skipBlanks(buf, at)

  while at < buf.len and not buf[at].isWhitespace() and not (tag.open and buf[at] == '/') and buf[at] != '>' and buf[at].isAscii():
    tagname &= buf[at].tolower()
    inc at

  tag.tagid = tagType(tagname)
  at = skipBlanks(buf, at)

  while at < buf.len and buf[at] != '>':
    var value = ""
    var attrname = ""
    while at < buf.len and buf[at] != '=' and not buf[at].isWhitespace() and buf[at] != '>':
      var r: Rune
      fastRuneAt(buf, at, r)
      if r.isAscii():
        attrname &= char(r).tolower()
      else:
        attrname &= r

    at = skipBlanks(buf, at)
    if at < buf.len and buf[at] == '=':
      inc at
      at = skipBlanks(buf, at)
      if at < buf.len and (buf[at] == '"' or buf[at] == '\''):
        let startc = buf[at]
        inc at
        while at < buf.len and buf[at] != startc:
          if buf[at] == '&':
            inc at
            value &= getescapecmd(buf, at)
          else:
            value &= buf[at]
            inc at
        if at < buf.len:
          inc at
      elif at < buf.len:
        while at < buf.len and not buf[at].isWhitespace() and buf[at] != '>':
          var r: Rune
          fastRuneAt(buf, at, r)
          value &= $r

    if attrname.len > 0:
      tag.attrs[attrname] = value

  while at < buf.len and buf[at] != '>':
    inc at

  if at < buf.len and buf[at] == '>':
    inc at
  return tag

proc insertNode(parent, node: Node) =
  parent.childNodes.add(node)

  if parent.childNodes.len > 1:
    let prevSibling = parent.childNodes[^2]
    prevSibling.nextSibling = node
    node.previousSibling = prevSibling

  node.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    node.parentElement = Element(parent)

  if parent.ownerDocument != nil:
    node.ownerDocument = parent.ownerDocument
  elif parent.nodeType == DOCUMENT_NODE:
    node.ownerDocument = Document(parent)

  if node.nodeType == ELEMENT_NODE:
    parent.children.add(Element(node))

    let element = (Element(node))
    if element.ownerDocument != nil:
      element.ownerDocument.type_elements[element.tagType].add(element)
      if element.id != "":
        if not (element.id in element.ownerDocument.id_elements):
          element.ownerDocument.id_elements[element.id] = newSeq[Element]()
        element.ownerDocument.id_elements[element.id].add(element)

      for c in element.classList:
        if not (c in element.ownerDocument.class_elements):
          element.ownerDocument.class_elements[c] = newSeq[Element]()
        element.ownerDocument.class_elements[c].add(element)

proc processDocumentBody(state: var HTMLParseState) =
  if not state.in_body:
    state.in_body = true
    if state.elementNode.ownerDocument != nil:
      state.elementNode = state.elementNode.ownerDocument.body

#TODO this adds text nodes to head
proc processDocumentAddNode(state: var HTMLParseState, newNode: Node) =
  if state.elementNode.tagType == TAG_HTML:
    if state.in_body:
      state.elementNode = state.elementNode.ownerDocument.body
    else:
      state.elementNode = state.elementNode.ownerDocument.head

  insertNode(state.elementNode, newNode)

proc processDocumentEndNode(state: var HTMLParseState) =
  if state.elementNode == nil or state.elementNode.nodeType == DOCUMENT_NODE:
    return
  state.elementNode = state.elementNode.parentElement

proc processDocumentText(state: var HTMLParseState) =
  if state.textNode == nil:
    state.textNode = newText()
    processDocumentAddNode(state, state.textNode)

proc processDocumentStartElement(state: var HTMLParseState, element: Element, tag: DOMParsedTag) =
  var add = true

  for k, v in tag.attrs:
    element.attributes[k] = v
  
  element.id = element.attr("id")
  if element.attributes.hasKey("class"):
    for w in unicode.split(element.attributes["class"], Rune(' ')):
      element.classList.add(w)

  case element.tagType
  of TAG_SCRIPT:
    state.in_script = true
  of TAG_NOSCRIPT:
    state.in_noscript = true
  of TAG_STYLE:
    state.in_style = true
  of TAG_SELECT:
    HTMLSelectElement(element).name = element.attr("name")
    HTMLSelectElement(element).value = element.attr("value")
  of TAG_INPUT:
    let element = HTMLInputElement(element)
    element.value = element.attr("value")
    element.inputType = element.attr("type").inputType()
    element.size = element.attr("size").inputSize()
    element.checked = element.attrb("checked")
    if state.formowners.len > 0:
      element.form = state.formowners[^1]
      element.form.inputs.add(element)
  of TAG_A:
    HTMLAnchorElement(element).href = element.attr("href")
  of TAG_OPTION:
    HTMLOptionElement(element).value = element.attr("href")
  of TAG_OL:
    HTMLOListElement(element).start = element.attri("start") 
    HTMLOListElement(element).ordinalcounter = HTMLOListElement(element).start.get(1)
  of TAG_LI:
    HTMLLIElement(element).value = element.attri("value")
  of TAG_HTML:
    add = false
  of TAG_HEAD:
    add = false
    state.in_body = false
    if state.elementNode.ownerDocument != nil:
      state.elementNode = state.elementNode.ownerDocument.head
  of TAG_BODY:
    add = false
  of TAG_PRE:
    state.skip_lf = true
  of TAG_H1:
    HTMLHeadingElement(element).rank = 1
  of TAG_H2:
    HTMLHeadingElement(element).rank = 2
  of TAG_H3:
    HTMLHeadingElement(element).rank = 3
  of TAG_H4:
    HTMLHeadingElement(element).rank = 4
  of TAG_H5:
    HTMLHeadingElement(element).rank = 5
  of TAG_H6:
    HTMLHeadingElement(element).rank = 6
  of TAG_LINK:
    HTMLLinkElement(element).href = element.attr("href")
    HTMLLinkElement(element).rel = element.attr("rel")
  of TAG_FORM:
    let element = HTMLFormElement(element)
    element.name = element.attr("name")
    element.smethod = element.attr("method")
    element.enctype = element.attr("enctype")
    element.target = element.attr("target")
    element.novalidate = element.attrb("novalidate")
    state.formowners.add(element)
  else: discard

  if not state.in_body and not (element.tagType in HeadTagTypes):
    processDocumentBody(state)

  if state.elementNode.nodeType == ELEMENT_NODE:
    if element.tagType in SelfClosingTagTypes:
      if state.elementNode.tagType == element.tagType:
        processDocumentEndNode(state)

    if state.elementNode.tagType == TAG_P and element.tagType in PClosingTagTypes:
      processDocumentEndNode(state)

  if add:
    processDocumentAddNode(state, element)
    state.elementNode = element

    case element.tagType
    of VoidTagTypes:
      processDocumentEndNode(state)
    of TAG_LI:
      HTMLLIElement(element).applyOrdinal() #needs to know parent
    else: discard

proc processDocumentEndElement(state: var HTMLParseState, tag: DOMParsedTag) =
  if tag.tagid != state.elementNode.tagType:
    if state.elementNode.tagType in SelfClosingTagTypes:
      processDocumentEndNode(state)
      processDocumentEndNode(state)
  else:
    case tag.tagid
    of VoidTagTypes:
      return
    of TAG_HEAD:
      processDocumentBody(state)
      return
    of TAG_BODY:
      return
    of TAG_FORM:
      if state.formowners.len > 0:
        discard state.formowners.pop()
    of TAG_STYLE:
      let style = HTMLStyleElement(state.elementNode)
      var str = ""
      for child in style.textNodes:
        str &= child.data
      let sheet = newStringStream(str).parseStylesheet()
      style.parentElement.sheets.add(sheet)
    else: discard
    processDocumentEndNode(state)

proc processDocumentTag(state: var HTMLParseState, tag: DOMParsedTag) =
  if state.in_script:
    if not tag.open and tag.tagid == TAG_SCRIPT:
      state.in_script = false
    else:
      return

  if state.in_style:
    if not tag.open and tag.tagid == TAG_STYLE:
      state.in_style = false
    else:
      return

  if not tag.open and state.in_noscript:
    if tag.tagid == TAG_NOSCRIPT:
      state.in_noscript = false
    else:
      return

  if tag.open:
    processDocumentStartElement(state, state.document.newHtmlElement(tag.tagid), tag)
  else:
    processDocumentEndElement(state, tag)

proc processDocumentPart(state: var HTMLParseState, buf: string) =
  var at = 0
  var max = 0
  var was_script = false

  max = buf.len

  template process_char(c: char) =
    if state.in_comment:
      state.commentNode.data &= c
    else:
      if not c.isWhitespace() and state.elementNode.tagType == TAG_HTML:
        state.textNode = nil
        processDocumentBody(state)
        processDocumentText(state)
      if not (state.skip_lf and c == '\n'):
        processDocumentText(state)
        state.textNode.data &= c
      state.skip_lf = false

  template process_text(s: string) =
    if state.in_comment:
      state.commentNode.data &= s
    else:
      if not (state.skip_lf and s[0] == '\n'):
        processDocumentText(state)
        state.textNode.data &= s
      state.skip_lf = false

  template has(buf: string, s: string): bool =
    (at + s.len < buf.len and buf.substr(at, at + 8) == "</script>")

  while at < max:
    case buf[at]
    of '&':
      inc at
      let p = getescapecmd(buf, at)
      process_text(p)
    of '<':
      if state.in_comment:
        state.commentNode.data &= buf[at]
        inc at
      else:
        var p = at
        inc p
        if p < max and buf[p] == '!':
          inc p
          if p < max and buf[p] == '-':
            inc p
            if p < max and buf[p] == '-':
              inc p
              at = p
              state.in_comment = true
              let comment = newComment()
              state.commentNode = comment
              processDocumentAddNode(state, comment)
              state.textNode = nil
          else:
            #TODO for doctype
            while p < max and buf[p] != '>':
              inc p
            at = p + 1
            continue

        if not state.in_comment:
          state.textNode = nil
          p = at
          if state.in_script:
            if buf.has("</script>"):
              var tag = parse_tag(buf, at)
              processDocumentTag(state, tag)
            else:
              process_char(buf[at])
              inc at
          else:
            var tag = parse_tag(buf, at)
            processDocumentTag(state, tag)
    elif buf[at] == '-' and state.in_comment:
      var p = at
      inc p
      if p < max and buf[p] == '-':
        inc p
        if p < max and buf[p] == '>':
          inc p
          at = p
          state.commentNode = nil
          state.in_comment = false

      if state.in_comment:
        state.commentNode.data &= buf[at]
        inc at
    else:
      process_char(buf[at])
      inc at

proc parseHtml5(inputStream: Stream, savesource: bool, source: var string): Document =
  #TODO implement HTML5 parsing
  var tokenizer = inputStream.newTokenizer()
  for tok in tokenizer.tokenize:
    eprint tok

proc parseHtml(inputStream: Stream, savesource: bool, source: var string): Document =
  let document = newDocument()
  insertNode(document, document.root)
  insertNode(document.root, document.head)
  insertNode(document.root, document.body)

  var state = HTMLParseState()
  state.document = document
  state.elementNode = document.root

  var till_when = false

  var buf = ""
  var lineBuf: string
  while not inputStream.atEnd():
    lineBuf = inputStream.readLine() & '\n'
    if savesource:
      source &= lineBuf
    buf &= lineBuf

    var at = 0
    while at < lineBuf.len:
      case lineBuf[at]
      of '<':
        till_when = true
      of '>':
        till_when = false
      else: discard
      inc at

    if till_when:
      continue

    processDocumentPart(state, buf)
    buf = ""

  inputStream.close()
  return document

proc parseHtml*(inputStream: Stream, source: var string): Document =
  return parseHtml(inputStream, true, source)

proc parseHtml*(inputStream: Stream): Document =
  var placeholder = ""
  return parseHtml(inputStream, false, placeholder)
