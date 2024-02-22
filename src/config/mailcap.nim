# See https://www.rfc-editor.org/rfc/rfc1524

import std/osproc
import std/streams
import std/strutils

import types/url
import types/opt
import utils/twtstr

import chagashi/charset

type
  MailcapParser = object
    stream: Stream
    hasbuf: bool
    buf: char

  MailcapFlags* = enum
    NEEDSTERMINAL = "needsterminal"
    COPIOUSOUTPUT = "copiousoutput"
    HTMLOUTPUT = "x-htmloutput" # from w3m

  MailcapEntry* = object
    mt*: string
    subt*: string
    cmd*: string
    flags*: set[MailcapFlags]
    nametemplate*: string
    edit*: string
    test*: string

  Mailcap* = seq[MailcapEntry]

proc has(state: MailcapParser): bool {.inline.} =
  return not state.stream.atEnd

proc consume(state: var MailcapParser): char =
  if state.hasbuf:
    state.hasbuf = false
    return state.buf
  return state.stream.readChar()

proc reconsume(state: var MailcapParser, c: char) =
  state.buf = c
  state.hasbuf = true

proc skipBlanks(state: var MailcapParser, c: var char): bool =
  while state.has():
    c = state.consume()
    if c notin AsciiWhitespace - {'\n'}:
      return true

proc skipBlanks(state: var MailcapParser) =
  var c: char
  if state.skipBlanks(c):
    state.reconsume(c)

proc skipLine(state: var MailcapParser) =
  while state.has():
    let c = state.consume()
    if c == '\n':
      break

proc consumeTypeField(state: var MailcapParser): Result[string, string] =
  var s = ""
  # type
  while state.has():
    let c = state.consume()
    if c == '/':
      s &= c
      break
    if c notin AsciiAlphaNumeric + {'-', '*'}:
      return err("Invalid character encountered in type field")
    s &= c.toLowerAscii()
  if not state.has():
    return err("Missing subtype")
  # subtype
  while state.has():
    let c = state.consume()
    if c in AsciiWhitespace + {';'}:
      state.reconsume(c)
      break
    if c notin AsciiAlphaNumeric + {'-', '.', '*', '_', '+'}:
      return err("Invalid character encountered in subtype field")
    s &= c.toLowerAscii()
  var c: char
  if not state.skipBlanks(c) or c != ';':
    return err("Semicolon not found")
  return ok(s)

proc consumeCommand(state: var MailcapParser): Result[string, string] =
  state.skipBlanks()
  var quoted = false
  var s = ""
  while state.has():
    let c = state.consume()
    if not quoted:
      if c == '\r':
        continue
      if c == ';' or c == '\n':
        state.reconsume(c)
        return ok(s)
      if c == '\\':
        quoted = true
        continue
      if c notin Ascii - Controls:
        return err("Invalid character encountered in command")
    else:
      quoted = false
    s &= c
  return ok(s)

type NamedField = enum
  NO_NAMED_FIELD, NAMED_FIELD_TEST, NAMED_FIELD_NAMETEMPLATE, NAMED_FIELD_EDIT

proc parseFieldKey(entry: var MailcapEntry, k: string): NamedField =
  case k
  of "needsterminal":
    entry.flags.incl(NEEDSTERMINAL)
  of "copiousoutput":
    entry.flags.incl(COPIOUSOUTPUT)
  of "x-htmloutput":
    entry.flags.incl(HTMLOUTPUT)
  of "test":
    return NAMED_FIELD_TEST
  of "nametemplate":
    return NAMED_FIELD_NAMETEMPLATE
  of "edit":
    return NAMED_FIELD_EDIT
  return NO_NAMED_FIELD

proc consumeField(state: var MailcapParser, entry: var MailcapEntry):
    Result[bool, string] =
  state.skipBlanks()
  if not state.has():
    return ok(false)
  var buf = ""
  while state.has():
    let c = state.consume()
    case c
    of ';', '\n':
      if parseFieldKey(entry, buf) != NO_NAMED_FIELD:
        return err("Expected command")
      return ok(c == ';')
    of '\r':
      continue
    of '=':
      let f = parseFieldKey(entry, buf)
      let cmd = ?state.consumeCommand()
      case f
      of NO_NAMED_FIELD:
        discard
      of NAMED_FIELD_TEST:
        entry.test = cmd
      of NAMED_FIELD_NAMETEMPLATE:
        entry.nametemplate = cmd
      of NAMED_FIELD_EDIT:
        entry.edit = cmd
      return ok(state.consume() == ';')
    else:
      if c in Controls:
        return err("Invalid character encountered in field")
      buf &= c

proc parseMailcap*(stream: Stream): Result[Mailcap, string] =
  var state = MailcapParser(stream: stream)
  var mailcap: Mailcap
  while not stream.atEnd():
    let c = state.consume()
    if c == '#':
      state.skipLine()
      continue
    state.reconsume(c)
    state.skipBlanks()
    let c2 = state.consume()
    if c2 == '\n' or c2 == '\r':
      continue
    state.reconsume(c2)
    let t = ?state.consumeTypeField()
    let mt = t.until('/') #TODO this could be more efficient
    let subt = t[mt.len + 1 .. ^1]
    var entry = MailcapEntry(
      mt: mt,
      subt: subt,
      cmd: ?state.consumeCommand()
    )
    if state.consume() == ';':
      while ?state.consumeField(entry):
        discard
    mailcap.add(entry)
  return ok(mailcap)

# Mostly based on w3m's mailcap quote/unquote
type UnquoteState = enum
  STATE_NORMAL, STATE_QUOTED, STATE_PERC, STATE_ATTR, STATE_ATTR_QUOTED,
  STATE_DOLLAR

type UnquoteResult* = object
  canpipe*: bool
  cmd*: string

type QuoteState = enum
  QS_NORMAL, QS_DQUOTED, QS_SQUOTED

proc quoteFile(file: string, qs: QuoteState): string =
  var s = ""
  for c in file:
    case c
    of '$', '`', '"', '\\':
      if qs != QS_SQUOTED:
        s &= '\\'
    of '\'':
      if qs == QS_SQUOTED:
        s &= "'\\'" # then re-open the quote by appending c
      elif qs == QS_NORMAL:
        s &= '\\'
      # double-quoted: append normally
    of AsciiAlphaNumeric, '_', '.', ':', '/':
      discard # no need to quote
    elif qs == QS_NORMAL:
      s &= '\\'
    s &= c
  return s

proc unquoteCommand*(ecmd, contentType, outpath: string, url: URL,
    charset: Charset, canpipe: var bool): string =
  var cmd = ""
  var attrname = ""
  var state: UnquoteState
  var qss = @[QS_NORMAL] # quote state stack. len >1
  template qs: var QuoteState = qss[^1]
  for c in ecmd:
    case state
    of STATE_QUOTED:
      cmd &= c
      state = STATE_NORMAL
    of STATE_ATTR_QUOTED:
      attrname &= c.toLowerAscii()
      state = STATE_ATTR
    of STATE_NORMAL, STATE_DOLLAR:
      let prev_dollar = state == STATE_DOLLAR
      state = STATE_NORMAL
      case c
      of '%':
        state = STATE_PERC
      of '\\':
        state = STATE_QUOTED
      of '\'':
        if qs == QS_SQUOTED:
          qs = QS_NORMAL
        else:
          qs = QS_SQUOTED
        cmd &= c
      of '"':
        if qs == QS_DQUOTED:
          qs = QS_NORMAL
        else:
          qs = QS_DQUOTED
        cmd &= c
      of '$':
        if qs != QS_SQUOTED:
          state = STATE_DOLLAR
        cmd &= c
      of '(':
        if prev_dollar:
          qss.add(QS_NORMAL)
        cmd &= c
      of ')':
        if qs != QS_SQUOTED:
          if qss.len > 1:
            qss.setLen(qss.len - 1)
          else:
            # mismatched parens; probably an invalid shell command...
            qss[0] = QS_NORMAL
        cmd &= c
      else:
        cmd &= c
    of STATE_PERC:
      if c == '%':
        cmd &= c
      elif c == 's':
        cmd &= quoteFile(outpath, qs)
        canpipe = false
      elif c == 't':
        cmd &= quoteFile(contentType.until(';'), qs)
      elif c == 'u': # extension
        cmd &= quoteFile($url, qs)
      elif c == '{':
        state = STATE_ATTR
        continue
      state = STATE_NORMAL
    of STATE_ATTR:
      if c == '}':
        if attrname == "charset":
          cmd &= quoteFile($charset, qs)
          continue
        #TODO this is broken, because content-type is stripped of ; fields
        let kvs = contentType.after(';').toLowerAscii()
        var i = kvs.find(attrname)
        var s = ""
        if i != -1 and kvs.len > i + attrname.len and
            kvs[i + attrname.len] == '=':
          i = skipBlanks(kvs, i + attrname.len + 1)
          var q = false
          for j in i ..< kvs.len:
            if not q and kvs[j] == '\\':
              q = true
            elif not q and (kvs[j] == ';' or kvs[j] in AsciiWhitespace):
              break
            else:
              s &= kvs[j]
        cmd &= quoteFile(s, qs)
        attrname = ""
      elif c == '\\':
        state = STATE_ATTR_QUOTED
      else:
        attrname &= c
  return cmd

proc unquoteCommand*(ecmd, contentType, outpath: string, url: URL,
    charset: Charset): string =
  var canpipe: bool
  return unquoteCommand(ecmd, contentType, outpath, url, charset, canpipe)

proc getMailcapEntry*(mailcap: Mailcap, mimeType, outpath: string,
    url: URL, charset: Charset): ptr MailcapEntry =
  let mt = mimeType.until('/')
  if mt.len + 1 >= mimeType.len:
    return nil
  let st = mimeType[mt.len + 1 .. ^1]
  for entry in mailcap:
    if not (entry.mt.len == 1 and entry.mt[0] == '*') and
        entry.mt != mt:
      continue
    if not (entry.subt.len == 1 and entry.subt[0] == '*') and
        entry.subt != st:
      continue
    if entry.test != "":
      var canpipe = true
      let cmd = unquoteCommand(entry.test, mimeType, outpath, url, charset,
        canpipe)
      #TODO TODO TODO if not canpipe ...
      if execCmd(cmd) != 0:
        continue
    return unsafeAddr entry
