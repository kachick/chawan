import streams
import tables
import times
import strutils
import strformat
import unicode

import utils/twtstr

type
  ValueType = enum
    VALUE_STRING, VALUE_INTEGER, VALUE_FLOAT, VALUE_BOOLEAN, VALUE_DATE_TIME,
    VALUE_TABLE, VALUE_ARRAY VALUE_TABLE_ARRAY

  SyntaxError = object of ValueError

  TomlParser = object
    at: int
    line: int
    stream: Stream
    buf: string
    root: TomlTable
    node: TomlNode
    currkey: seq[string]

  TomlValue* = ref object
    case vt*: ValueType
    of VALUE_STRING:
      s*: string
    of VALUE_INTEGER:
      i*: int64
    of VALUE_FLOAT:
      f*: float64
    of VALUE_BOOLEAN:
      b*: bool
    of VALUE_TABLE:
      t*: TomlTable
    of VALUE_DATE_TIME:
      dt*: DateTime
    of VALUE_ARRAY:
      a*: seq[TomlValue]
    of VALUE_TABLE_ARRAY:
      ta*: seq[TomlTable]

  TomlNode = ref object of RootObj
    comment: string

  TomlKVPair = ref object of TomlNode
    key*: seq[string]
    value*: TomlValue

  TomlTable = ref object of TomlNode
    key: seq[string]
    nodes: seq[TomlNode]
    map: Table[string, TomlValue]

func `[]`*(val: TomlValue, key: string): TomlValue =
  return val.t.map[key]

iterator pairs*(val: TomlValue): (string, TomlValue) =
  for k, v in val.t.map.pairs:
    yield (k, v)

func contains*(val: TomlValue, key: string): bool =
  return key in val.t.map

func isBare(c: char): bool =
  return c == '-' or c == '_' or c.isAlphaNumeric()

func peek(state: TomlParser, i: int): char =
  return state.buf[state.at + i]

func peek(state: TomlParser, i: int, len: int): string =
  return state.buf.substr(state.at + i, state.at + i + len)

proc syntaxError(state: TomlParser, msg: string) =
  raise newException(SyntaxError, fmt"on line {state.line}: {msg}")

proc valueError(state: TomlParser, msg: string) =
  raise newException(ValueError, fmt"on line {state.line}: {msg}")

proc consume(state: var TomlParser): char =
  result = state.buf[state.at]
  inc state.at

proc reconsume(state: var TomlParser) =
  dec state.at

proc has(state: var TomlParser, i: int = 0): bool =
  if state.at + i >= state.buf.len and not state.stream.atEnd():
    state.buf &= state.stream.readLine() & '\n'
  return state.at + i < state.buf.len

proc consumeEscape(state: var TomlParser, c: char): Rune =
  var len = 4
  if c == 'U':
    len = 8
  let c = state.consume()
  var num = hexValue(c)
  if num != -1:
    var i = 0
    while state.has() and i < len:
      let c = state.peek(0)
      if hexValue(c) == -1:
        break
      discard state.consume()
      num *= 0x10
      num += hexValue(c)
      inc i
    if i != len - 1:
      state.syntaxError(fmt"invalid escaped length ({i}, needs {len})")
    if num > 0x10FFFF or num in {0xD800..0xDFFF}:
      state.syntaxError(fmt"invalid escaped codepoint {num}")
    else:
      return Rune(num)
  else:
    state.syntaxError(fmt"invalid escaped codepoint {c}")

proc consumeString(state: var TomlParser, first: char): string =
  var multiline = false

  if first == '"':
    if state.has(1):
      let s = state.peek(0, 2)
      if s == "\"\"":
        multiline = true
  elif first == '\'':
    if state.has(1):
      let s = state.peek(0, 2)
      if s == "''":
        multiline = true

  if multiline:
    let c = state.peek(0)
    if c == '\n':
      discard state.consume()

  var escape = false
  var ml_trim = false
  while state.has():
    let c = state.consume()
    if c == '\n' and not multiline:
      state.syntaxError(fmt"newline in string")
    elif c == first:
      if multiline and state.has(1):
        let c2 = state.peek(0)
        let c3 = state.peek(1)
        if c2 == first and c3 == first:
          break
      else:
        break
    elif first == '"' and c == '\\':
      escape = true
    elif escape:
      case c
      of 'b': result &= '\b'
      of 't': result &= '\t'
      of 'n': result &= '\n'
      of 'f': result &= '\f'
      of 'r': result &= '\r'
      of '"': result &= '"'
      of '\\': result &= '\\'
      of 'u', 'U': result &= state.consumeEscape(c)
      of '\n': ml_trim = true
      else: state.syntaxError(fmt"invalid escape sequence \{c}")
      escape = false
    elif ml_trim:
      if not (c in {'\n', ' ', '\t'}):
        result &= c
        ml_trim = false
    else:
      result &= c

proc consumeBare(state: var TomlParser, c: char): string =
  result &= c
  while state.has():
    let c = state.consume()
    case c
    of ' ', '\t': break
    of '.', '=', ']', '\n':
      state.reconsume()
      break
    elif c.isBare():
      result &= c
    else:
      state.syntaxError(fmt"invalid value in token: {c}")

proc flushLine(state: var TomlParser) =
  if state.node != nil:
    if state.node of TomlKVPair:
      var i = 0
      let keys = state.currkey & TomlKVPair(state.node).key
      var table = state.root
      while i < keys.len - 1:
        if keys[i] in table.map:
          let node = table.map[keys[i]]
          if node.vt != VALUE_TABLE:
            let s = keys.join(".")
            state.valueError(fmt"re-definition of node {s}")
          else:
            table = node.t
        else:
          let node = TomlTable()
          table.map[keys[i]] = TomlValue(vt: VALUE_TABLE, t: node)
          table = node
        inc i

      if keys[i] in table.map:
        let s = keys.join(".")
        state.valueError(fmt"re-definition of node {s}")

      table.map[keys[i]] = TomlKVPair(state.node).value
      table.nodes.add(state.node)
    state.node = nil
  inc state.line

proc consumeComment(state: var TomlParser) =
  state.node = TomlNode()
  while state.has():
    let c = state.consume()
    if c == '\n':
      state.reconsume()
      break
    else:
      state.node.comment &= c

proc consumeKey(state: var TomlParser): seq[string] =
  var str = ""
  while state.has():
    let c = state.consume()
    case c
    of '"', '\'':
      if str.len > 0:
        state.syntaxError("multiple strings without dot")
      str = state.consumeString(c)
    of '=', ']':
      if str.len != 0:
        result.add(str)
        str = ""
      return result
    of '.':
      if str.len == 0: #TODO empty strings are allowed, only empty keys aren't
        state.syntaxError("redundant dot")
      else:
        result.add(str)
        str = ""
    of ' ', '\t': discard
    of '\n':
      if state.node != nil:
        state.syntaxError("newline without value")
      else:
        state.flushLine()
    elif c.isBare():
      if str.len > 0:
        state.syntaxError(fmt"multiple strings without dot: {str}")
      str = state.consumeBare(c)
    else: state.syntaxError(fmt"invalid character in key: {c}")

  state.syntaxError("key without value")

proc consumeTable(state: var TomlParser): TomlTable =
  new(result)
  while state.has():
    let c = state.peek(0)
    case c
    of ' ', '\t': discard
    of '\n':
      return result
    of '[':
      #TODO table array
      state.syntaxError("arrays of tables are not supported yet")
    of '"', '\'':
      result.key = state.consumeKey()
    elif c.isBare():
      result.key = state.consumeKey()
    else: state.syntaxError(fmt"invalid character before key: {c}")
  state.syntaxError("unexpected end of file")

proc consumeNoState(state: var TomlParser): bool =
  while state.has():
    let c = state.peek(0)
    case c
    of '#', '\n':
      return false
    of ' ', '\t': discard
    of '[':
      discard state.consume()
      let table = state.consumeTable()
      state.currkey = table.key
      state.node = table
      return false
    elif c == '"' or c == '\'' or c.isBare():
      let kvpair = TomlKVPair()
      kvpair.key = state.consumeKey()
      state.node = kvpair
      return true
    else: state.syntaxError(fmt"invalid character before key: {c}")
  state.syntaxError("unexpected end of file")

proc consumeNumber(state: var TomlParser): TomlValue =
  var repr: string
  var isfloat = false
  if state.has():
    if state.peek(0) == '+' or state.peek(0) == '-':
      repr &= state.consume()

  while state.has() and isDigit(state.peek(0)):
    repr &= state.consume()

  if state.has(1):
    if state.peek(0) == '.' and isDigit(state.peek(1)):
      repr &= state.consume()
      repr &= state.consume()
      isfloat = true
      while state.has() and isDigit(state.peek(0)):
        repr &= state.consume()

  if state.has(1):
    if state.peek(0) == 'E' or state.peek(0) == 'e':
      var j = 2
      if state.peek(1) == '-' or state.peek(1) == '+':
        inc j
      if state.has(j) and isDigit(state.peek(j)):
        while j > 0:
          repr &= state.consume()
          dec j

        while state.has() and isDigit(state.peek(0)):
          repr &= state.consume()

  if isfloat:
    let val = parseFloat64(repr)
    return TomlValue(vt: VALUE_FLOAT, f: val)

  let val = parseInt64(repr)
  return TomlValue(vt: VALUE_INTEGER, i: val)

proc consumeValue(state: var TomlParser): TomlValue

proc consumeArray(state: var TomlParser): TomlValue =
  result = TomlValue(vt: VALUE_ARRAY)
  var val: TomlValue
  while state.has():
    let c = state.consume()
    case c
    of ' ', '\t', '\n': discard
    of ']':
      if val != nil:
        result.a.add(val)
      break
    of ',':
      if val == nil:
        state.syntaxError("comma without element")
      result.a.add(val)
    else:
      state.reconsume()
      val = state.consumeValue()

proc consumeValue(state: var TomlParser): TomlValue =
  while state.has():
    let c = state.consume()
    case c
    of '"', '\'':
      return TomlValue(vt: VALUE_STRING, s: state.consumeString(c))
    of ' ', '\t': discard
    of '\n':
      state.syntaxError("newline without value")
    of '#':
      state.syntaxError("comment without value")
    of '+', '-', '0'..'9':
      return state.consumeNumber()
      #TODO date-time
    of '[':
      return state.consumeArray()
    elif c.isBare():
      let s = state.consumeBare(c)
      case s
      of "true": return TomlValue(vt: VALUE_BOOLEAN, b: true)
      of "false": return TomlValue(vt: VALUE_BOOLEAN, b: false)
      else: state.syntaxError(fmt"invalid token {s}")
    else:
      state.syntaxError(fmt"invalid character in value: {c}")

proc parseToml*(inputStream: Stream): TomlValue =
  var state: TomlParser
  state.stream = inputStream
  state.line = 1
  state.root = TomlTable()

  while state.has():
    if state.consumeNoState():
      let kvpair = TomlKVPair(state.node)
      kvpair.value = state.consumeValue()

    while state.has():
      let c = state.consume()
      case c
      of '\n':
        state.flushLine()
        break
      of '#':
        state.consumeComment()
      of '\t', ' ': discard
      else: state.syntaxError(fmt"invalid character after value: {c}")

  return TomlValue(vt: VALUE_TABLE, t: state.root)
