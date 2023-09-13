import streams
import tables
import times
import strutils
import unicode

import utils/opt
import utils/twtstr

type
  ValueType* = enum
    VALUE_STRING = "string"
    VALUE_INTEGER = "integer"
    VALUE_FLOAT = "float"
    VALUE_BOOLEAN = "boolean"
    VALUE_DATE_TIME = "datetime"
    VALUE_TABLE = "table"
    VALUE_ARRAY = "array"

  TomlError = string

  TomlResult = Result[TomlValue, TomlError]

  TomlParser = object
    filename: string
    at: int
    line: int
    buf: string
    root: TomlTable
    node: TomlNode
    currkey: seq[string]
    tarray: bool

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
      ad*: bool

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

iterator pairs*(val: TomlTable): (string, TomlValue) {.inline.} =
  for k, v in val.map.pairs:
    yield (k, v)

iterator pairs*(val: TomlValue): (string, TomlValue) {.inline.} =
  for k, v in val.t:
    yield (k, v)

iterator items*(val: TomlValue): TomlValue {.inline.} =
  for v in val.a:
    yield v

func contains*(val: TomlValue, key: string): bool =
  return key in val.t.map

func isBare(c: char): bool =
  return c == '-' or c == '_' or c.isAlphaNumeric()

func peek(state: TomlParser, i: int): char =
  return state.buf[state.at + i]

func peek(state: TomlParser, i: int, len: int): string =
  return state.buf.substr(state.at + i, state.at + i + len)

template err(state: TomlParser, msg: string): untyped =
  err(state.filename & "(" & $state.line & "):" & msg)

proc consume(state: var TomlParser): char =
  result = state.buf[state.at]
  inc state.at

proc reconsume(state: var TomlParser) =
  dec state.at

proc has(state: var TomlParser, i: int = 0): bool =
  return state.at + i < state.buf.len

proc consumeEscape(state: var TomlParser, c: char): Result[Rune, TomlError] =
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
      return state.err("invalid escaped length (" & $i & ", needs " & $len &
        ")")
    if num > 0x10FFFF or num in 0xD800..0xDFFF:
      return state.err("invalid escaped codepoint: " & $num)
    else:
      return ok(cast[Rune](num))
  else:
    return state.err("invalid escaped codepoint: " & $c)

proc consumeString(state: var TomlParser, first: char):
    Result[string, string] =
  var multiline = false

  if first == '"':
    if state.has(1):
      let s = state.peek(0, 1)
      if s == "\"\"":
        multiline = true
  elif first == '\'':
    if state.has(1):
      let s = state.peek(0, 1)
      if s == "''":
        multiline = true

  if multiline:
    let c = state.peek(0)
    if c == '\n':
      discard state.consume()

  var escape = false
  var ml_trim = false
  var res = ""
  while state.has():
    let c = state.consume()
    if c == '\n' and not multiline:
      return state.err("newline in string")
    elif c == first:
      if multiline:
        if state.has(1):
          let c2 = state.peek(0)
          let c3 = state.peek(1)
          if c2 == first and c3 == first:
            discard state.consume()
            discard state.consume()
            break
        res &= c
      else:
        break
    elif first == '"' and c == '\\':
      escape = true
    elif escape:
      case c
      of 'b': res &= '\b'
      of 't': res &= '\t'
      of 'n': res &= '\n'
      of 'f': res &= '\f'
      of 'r': res &= '\r'
      of '"': res &= '"'
      of '\\': res &= '\\'
      of 'u', 'U': res &= ?state.consumeEscape(c)
      of '\n': ml_trim = true
      else: return state.err("invalid escape sequence \\" & c)
      escape = false
    elif ml_trim:
      if c notin {'\n', ' ', '\t'}:
        res &= c
        ml_trim = false
    else:
      if c == '\n':
        inc state.line
      res &= c
  return ok(res)

proc consumeBare(state: var TomlParser, c: char): Result[string, TomlError] =
  var res = $c
  while state.has():
    let c = state.consume()
    case c
    of ' ', '\t': break
    of '.', '=', ']', '\n':
      state.reconsume()
      break
    elif c.isBare():
      res &= c
    else:
      return state.err("invalid value in token: " & c)
  return ok(res)

proc flushLine(state: var TomlParser): Err[TomlError] =
  if state.node != nil:
    if state.node of TomlKVPair:
      var i = 0
      let keys = state.currkey & TomlKVPair(state.node).key
      var table = state.root
      while i < keys.len - 1:
        if keys[i] in table.map:
          let node = table.map[keys[i]]
          if node.vt == VALUE_TABLE:
            table = node.t
          elif node.vt == VALUE_ARRAY:
            assert state.tarray
            table = node.a[^1].t
          else:
            let s = keys.join(".")
            return state.err("re-definition of node " & s)
        else:
          let node = TomlTable()
          table.map[keys[i]] = TomlValue(vt: VALUE_TABLE, t: node)
          table = node
        inc i

      if keys[i] in table.map:
        let s = keys.join(".")
        return state.err("re-definition of node " & s)

      table.map[keys[i]] = TomlKVPair(state.node).value
      table.nodes.add(state.node)
    state.node = nil
  inc state.line
  return ok()

proc consumeComment(state: var TomlParser) =
  state.node = TomlNode()
  while state.has():
    let c = state.consume()
    if c == '\n':
      state.reconsume()
      break
    else:
      state.node.comment &= c

proc consumeKey(state: var TomlParser): Result[seq[string], TomlError] =
  var res: seq[string]
  var str = ""
  while state.has():
    let c = state.consume()
    case c
    of '"', '\'':
      if str.len > 0:
        return state.err("multiple strings without dot")
      str = ?state.consumeString(c)
    of '=', ']':
      if str.len != 0:
        res.add(str)
        str = ""
      return ok(res)
    of '.':
      if str.len == 0: #TODO empty strings are allowed, only empty keys aren't
        return state.err("redundant dot")
      else:
        res.add(str)
        str = ""
    of ' ', '\t': discard
    of '\n':
      if state.node != nil:
        return state.err("newline without value")
      else:
        ?state.flushLine()
    elif c.isBare():
      if str.len > 0:
        return state.err("multiple strings without dot: " & str)
      str = ?state.consumeBare(c)
    else: return state.err("invalid character in key: " & c)
  return state.err("key without value")

proc consumeTable(state: var TomlParser): Result[TomlTable, TomlError] =
  let res = TomlTable()
  while state.has():
    let c = state.peek(0)
    case c
    of ' ', '\t': discard state.consume()
    of '\n': return ok(res)
    of ']':
      if state.tarray:
        discard state.consume()
        return ok(res)
      else:
        return state.err("redundant ] character after key")
    of '[':
      state.tarray = true
      discard state.consume()
    of '"', '\'':
      res.key = ?state.consumeKey()
    elif c.isBare():
      res.key = ?state.consumeKey()
    else: return state.err("invalid character before key: " & c)
  return state.err("unexpected end of file")

proc consumeNoState(state: var TomlParser): Result[bool, TomlError] =
  while state.has():
    let c = state.peek(0)
    case c
    of '#', '\n':
      return ok(false)
    of ' ', '\t': discard
    of '[':
      discard state.consume()
      state.tarray = false
      let table = ?state.consumeTable()
      if state.tarray:
        var node = state.root
        for i in 0 ..< table.key.high:
          if table.key[i] in node.map:
            node = node.map[table.key[i]].t
          else:
            let t2 = TomlTable()
            node.map[table.key[i]] = TomlValue(vt: VALUE_TABLE, t: t2)
            node = t2
        if table.key[^1] in node.map:
          var last = node.map[table.key[^1]]
          if last.vt != VALUE_ARRAY:
            let key = table.key.join('.')
            return state.err("re-definition of node " & key &
              " as table array (was " & $last.vt & ")")
          last.ad = true
          let val = TomlValue(vt: VALUE_TABLE, t: table)
          last.a.add(val)
        else:
          let val = TomlValue(vt: VALUE_TABLE, t: table)
          let last = TomlValue(vt: VALUE_ARRAY, a: @[val])
          node.map[table.key[^1]] = last
      state.currkey = table.key
      state.node = table
      return ok(false)
    elif c == '"' or c == '\'' or c.isBare():
      let kvpair = TomlKVPair()
      kvpair.key = ?state.consumeKey()
      state.node = kvpair
      return ok(true)
    else: return state.err("invalid character before key: " & c)
  return state.err("unexpected end of file")

type ParsedNumberType = enum
  NUMBER_INTEGER, NUMBER_FLOAT, NUMBER_HEX, NUMBER_OCT

proc consumeNumber(state: var TomlParser, c: char): TomlResult =
  var repr = $c
  var numType = NUMBER_INTEGER
  if state.has():
    if state.peek(0) == '+' or state.peek(0) == '-':
      repr &= state.consume()
    elif state.peek(0) == '0' and state.has(1):
      let c = state.peek(1)
      if c == 'x':
        numType = NUMBER_HEX
      elif c == 'o':
        numType = NUMBER_OCT

  if not state.has() or not isDigit(state.peek(0)):
    return state.err("invalid number")

  var was_num = true
  while state.has():
    if isDigit(state.peek(0)):
      repr &= state.consume()
      was_num = true
    elif was_num and state.peek(0) == '_':
      was_num = false
      repr &= '_'
    else:
      break

  if state.has(1):
    if state.peek(0) == '.' and isDigit(state.peek(1)):
      repr &= state.consume()
      repr &= state.consume()
      if numType notin {NUMBER_INTEGER, NUMBER_FLOAT}:
        return state.err("invalid floating point number")
      numType = NUMBER_FLOAT
      while state.has() and isDigit(state.peek(0)):
        repr &= state.consume()

  if state.has(1):
    if state.peek(0) == 'E' or state.peek(0) == 'e':
      if numType notin {NUMBER_INTEGER, NUMBER_FLOAT}:
        return state.err("invalid floating point number")
      numType = NUMBER_FLOAT
      var j = 2
      if state.peek(1) == '-' or state.peek(1) == '+':
        inc j
      if state.has(j) and isDigit(state.peek(j)):
        while j > 0:
          repr &= state.consume()
          dec j

        while state.has() and isDigit(state.peek(0)):
          repr &= state.consume()

  case numType
  of NUMBER_INTEGER:
    let val = parseInt64(repr)
    if not val.isSome:
      return state.err("invalid integer")
    return ok(TomlValue(vt: VALUE_INTEGER, i: val.get))
  of NUMBER_HEX:
    try:
      let val = parseHexInt(repr)
      return ok(TomlValue(vt: VALUE_INTEGER, i: val))
    except ValueError:
      return state.err("invalid hexadecimal number")
  of NUMBER_OCT:
    try:
      let val = parseOctInt(repr)
      return ok(TomlValue(vt: VALUE_INTEGER, i:val))
    except ValueError:
      return state.err("invalid octal number")
  of NUMBER_FLOAT:
    let val = parseFloat64(repr)
    return ok(TomlValue(vt: VALUE_FLOAT, f: val))

proc consumeValue(state: var TomlParser): TomlResult

proc consumeArray(state: var TomlParser): TomlResult =
  var res = TomlValue(vt: VALUE_ARRAY)
  var val: TomlValue
  while state.has():
    let c = state.consume()
    case c
    of ' ', '\t': discard
    of '\n': inc state.line
    of ']':
      if val != nil:
        res.a.add(val)
      return ok(res)
    of ',':
      if val == nil:
        return state.err("comma without element")
      res.a.add(val)
      val = nil
    else:
      if val != nil:
        return state.err("missing comma")
      state.reconsume()
      val = ?state.consumeValue()
  return err("unexpected end of file")

proc consumeInlineTable(state: var TomlParser): TomlResult =
  let res = TomlValue(vt: VALUE_TABLE, t: TomlTable())
  var key: seq[string]
  var haskey: bool
  var val: TomlValue
  while state.has():
    let c = state.consume()
    case c
    of ' ', '\t': discard
    of '\n': inc state.line
    of ',', '}':
      if c == '}' and key.len == 0 and val == nil:
        return ok(res) # empty, or trailing comma
      if key.len == 0:
        return state.err("missing key")
      if val == nil:
        return state.err("comma without element")
      var table = res.t
      for i in 0 ..< key.high:
        let k = key[i]
        if k in table.map:
          return state.err("invalid re-definition of key " & k)
        else:
          let node = TomlTable()
          table.map[k] = TomlValue(vt: VALUE_TABLE, t: node)
          table = node
      let k = key[^1]
      if k in table.map:
        return state.err("invalid re-definition of key " & k)
      table.map[k] = val
      val = nil
      haskey = false
      if c == '}':
        return ok(res)
    else:
      if val != nil:
        return state.err("missing comma")
      if not haskey:
        state.reconsume()
        key = ?state.consumeKey()
        haskey = true
      else:
        state.reconsume()
        val = ?state.consumeValue()
  return state.err("unexpected end of file")

proc consumeValue(state: var TomlParser): TomlResult =
  while state.has():
    let c = state.consume()
    case c
    of '"', '\'':
      let s = ?state.consumeString(c)
      return ok(TomlValue(vt: VALUE_STRING, s: s))
    of ' ', '\t': discard
    of '\n':
      return state.err("newline without value")
    of '#':
      return state.err("comment without value")
    of '+', '-', '0'..'9':
      return state.consumeNumber(c)
      #TODO date-time
    of '[':
      return state.consumeArray()
    of '{':
      return state.consumeInlineTable()
    elif c.isBare():
      let s = ?state.consumeBare(c)
      if s == "true":
        return ok(TomlValue(vt: VALUE_BOOLEAN, b: true))
      elif s == "false":
        return ok(TomlValue(vt: VALUE_BOOLEAN, b: false))
      else:
        return state.err("invalid token: " & s)
    else:
      return state.err("invalid character in value: " & c)
  return state.err("unexpected end of file")

proc parseToml*(inputStream: Stream, filename = "<input>"): TomlResult =
  var state: TomlParser
  state.buf = inputStream.readAll()
  state.line = 1
  state.root = TomlTable()
  state.filename = filename
  while state.has():
    if ?state.consumeNoState():
      # state.node has been set to a KV pair, so now we parse its value.
      let kvpair = TomlKVPair(state.node)
      kvpair.value = ?state.consumeValue()
    while state.has():
      let c = state.consume()
      case c
      of '\n':
        ?state.flushLine()
        break
      of '#':
        state.consumeComment()
      of '\t', ' ': discard
      else: return state.err("invalid character after value: " & c)
  inputStream.close()
  return ok(TomlValue(vt: VALUE_TABLE, t: state.root))
