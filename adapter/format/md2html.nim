import std/strutils

proc toggle[T](s: var set[T], t: T): bool =
  result = t notin s
  if result:
    s.incl(t)
  else:
    s.excl(t)

type BracketState = enum
  bsNone, bsInBracketRef, bsInBracket, bsAfterBracket, bsInParen, bsInImage

const AsciiAlphaNumeric = {'0'..'9', 'A'..'Z', 'a'..'z'}
const AsciiWhitespace = {' ', '\n', '\r', '\t', '\f'}

proc getId(line: openArray[char]): string =
  result = ""
  var i = 0
  var bs = bsNone
  var escape = false
  while i < line.len:
    let c = line[i]
    if bs == bsInParen:
      if escape:
        escape = false
        inc i
        continue
      if c == ')':
        bs = bsNone
      elif c == '\\':
        escape = true
      inc i
      continue
    case c
    of AsciiAlphaNumeric, '-', '_', '.': result &= c.toLowerAscii()
    of ' ': result &= '-'
    of '[':
      if bs != bsNone:
        bs = bsInBracket
    of ']':
      if bs == bsInBracket:
        bs = bsAfterBracket
    of '(':
      if bs == bsAfterBracket:
        bs = bsInParen
    else: discard
    inc i

type InlineState = enum
  isItalic, isBold, isDel

func startsWithScheme(s: string): bool =
  for i, c in s:
    if i > 0 and c == ':':
      return true
    if c notin AsciiAlphaNumeric:
      break
  false

type ParseInlineContext = object
  i: int
  bracketChars: string
  bs: BracketState

proc parseInTag(ctx: var ParseInlineContext; line: openArray[char]) =
  var buf = ""
  var i = ctx.i
  while i < line.len:
    let c = line[i]
    if c == '>': # done
      if buf.startsWithScheme(): # link
        var linkChars = ""
        for c in buf:
          if c == '\'':
            linkChars &= "&apos"
          else:
            linkChars &= c
        stdout.write("<A HREF='" & linkChars & "'>" & buf & "</A>")
      else: # tag
        stdout.write('<' & buf & '>')
      buf = ""
      break
    elif c == '<':
      stdout.write('<' & buf)
      buf = ""
      dec i
      break
    else:
      buf &= c
    inc i
  stdout.write(buf)
  ctx.i = i

type CommentState = enum
  csNone, csDash, csDashDash

proc append(ctx: var ParseInlineContext; s: string) =
  if ctx.bs in {bsInBracketRef, bsInBracket}:
    ctx.bracketChars &= s
  else:
    stdout.write(s)

proc append(ctx: var ParseInlineContext; c: char) =
  if ctx.bs in {bsInBracketRef, bsInBracket}:
    ctx.bracketChars &= c
  else:
    stdout.write(c)

proc parseComment(ctx: var ParseInlineContext; line: openArray[char]) =
  var i = ctx.i
  var cs = csNone
  var buf = ""
  while i < line.len:
    let c = line[i]
    if cs in {csNone, csDash} and c == '-':
      inc cs
    elif cs == csDashDash and c == '>':
      buf &= '>'
      break
    else:
      cs = csNone
    buf &= c
    inc i
  ctx.append(buf)
  ctx.i = i

proc parseCode(ctx: var ParseInlineContext; line: openArray[char]) =
  var i = ctx.i
  while i < line.len:
    let c = line[i]
    case c
    of '<': ctx.append("&lt;")
    of '>': ctx.append("&gt;")
    of '"': ctx.append("&quot;")
    of '\'': ctx.append("&apos;")
    of '&': ctx.append("&amp;")
    of '`':
      ctx.append("</CODE>")
      break
    else: ctx.append(c)
    inc i
  ctx.i = i

proc parseInline(line: openArray[char]) =
  var state: set[InlineState] = {}
  var ctx = ParseInlineContext()
  var image = false
  while ctx.i < line.len:
    let c = line[ctx.i]
    if ctx.bs == bsAfterBracket and c != '(':
      stdout.write("[" & ctx.bracketChars & "]")
      ctx.bracketChars = ""
      ctx.bs = bsNone
      image = false
    if c == '\\':
      inc ctx.i
      if ctx.i < line.len:
        ctx.append(line[ctx.i])
    elif (ctx.i > 0 and line[ctx.i - 1] notin AsciiWhitespace or
          ctx.i + 1 < line.len and line[ctx.i + 1] notin AsciiWhitespace) and
        (c == '*' or
          c == '_' and
            (ctx.i == 0 or line[ctx.i - 1] notin AsciiAlphaNumeric or
              ctx.i + 1 >= line.len or
              line[ctx.i + 1] notin AsciiAlphaNumeric + {'_'})):
      if ctx.i + 1 < line.len and line[ctx.i + 1] == c:
        if state.toggle(isBold):
          ctx.append("<B>")
        else:
          ctx.append("</B>")
        inc ctx.i
      else:
        if state.toggle(isItalic):
          stdout.write("<I>")
        else:
          stdout.write("</I>")
    elif c == '`':
      ctx.append("<CODE>")
      inc ctx.i
      ctx.parseCode(line)
    elif c == '~' and ctx.i + 1 < line.len and line[ctx.i + 1] == '~':
      if state.toggle(isDel):
        ctx.append("<DEL>")
      else:
        ctx.append("</DEL>")
      inc ctx.i
    elif c == '!' and ctx.bs == bsNone and ctx.i + 1 < line.len and
        line[ctx.i + 1] == '[':
      image = true
    elif c == '[' and ctx.bs == bsNone:
      ctx.bs = bsInBracket
      if ctx.i + 1 < line.len and line[ctx.i + 1] == '^':
        inc ctx.i
        ctx.bs = bsInBracketRef
    elif c == ']' and ctx.bs == bsInBracketRef:
      let id = ctx.bracketChars.getId()
      stdout.write("<A HREF='#" & id & "'>" & ctx.bracketChars & "</A>")
      ctx.bracketChars = ""
    elif c == ']' and ctx.bs == bsInBracket:
      ctx.bs = bsAfterBracket
    elif c == '(' and ctx.bs == bsAfterBracket:
      if image:
        stdout.write("<IMG SRC='")
      else:
        stdout.write("<A HREF='")
      ctx.bs = bsInParen
    elif c == ')' and ctx.bs == bsInParen:
      if image:
        stdout.write("' ALT='" & ctx.bracketChars & "'>")
      else:
        stdout.write("'>" & ctx.bracketChars & "</A>")
      image = false
      ctx.bracketChars = ""
      ctx.bs = bsNone
    elif c == '\'' and ctx.bs == bsInParen:
      stdout.write("&apos;")
    elif c == '<' and ctx.bs == bsNone:
      inc ctx.i
      ctx.parseInTag(line)
    elif ctx.i + 4 < line.len and line.toOpenArray(ctx.i, ctx.i + 3) == "<!--":
      ctx.append("<!--")
      ctx.i += 3
      ctx.parseComment(line)
    elif c == '\n' and ctx.i >= 2 and line[ctx.i - 1] == ' ' and
        line[ctx.i - 2] == ' ':
      ctx.append("<BR>")
    else:
      ctx.append(c)
    inc ctx.i
  if ctx.bracketChars != "":
    stdout.write(ctx.bracketChars)
  if isBold in state:
    stdout.write("</B>")
  if isItalic in state:
    stdout.write("</I>")

proc parseHash(line: openArray[char]): bool =
  var n = -1
  for i, c in line:
    if line[i] != '#':
      if line[i] != ' ':
        return false
      n = i + 1
      break
  if n == -1:
    return false
  n = min(n, 6)
  let L = n
  var H = line.high
  for i in countdown(line.high, L):
    if line[i] != '#':
      if line[i] != ' ':
        break
      H = i - 1
      break
  H = max(L - 1, H)
  let id = line.toOpenArray(L, H).getId()
  stdout.write("<H" & $n & " id='" & id & "'><A HREF='#" & id & "'>" &
    '#'.repeat(n) & "</A> ")
  line.toOpenArray(L, H).parseInline()
  stdout.write("</H" & $n & ">\n")
  return true

type ListType = enum
  ltOl, ltUl

proc getListDepth(line: string): tuple[depth, len: int; ol: ListType] =
  var depth = 0
  for i, c in line:
    if c == '\t':
      depth += 8
    elif c == ' ':
      inc depth
    elif c in {'*', '-'}:
      let i = i + 1
      if i < line.len and line[i] in {'\t', ' '}:
        return (depth, i, ltUl)
      break
    elif c in {'0'..'9'}:
      let i = i + 1
      if i < line.len and line[i] == '.':
        let i = i + 1
        if i < line.len and line[i] in {'\t', ' '}:
          return (depth, i, ltOl)
      break
    else:
      break
  return (-1, -1, ltUl)

proc matchHTMLPreStart(line: string): bool =
  var tagn = ""
  for i, c in line:
    if i == 0:
      if c != '<':
        return false
      continue
    if c in {' ', '\t', '>'}:
      break
    if c notin {'A'..'Z', 'a'..'z'}:
      return false
    tagn &= c.toLowerAscii()
  return tagn in ["pre", "script", "style", "textarea"]

proc matchHTMLPreEnd(line: string): bool =
  var tagn = ""
  for i, c in line:
    if i == 0:
      if c != '<':
        return false
      continue
    if i == 1:
      if c != '/':
        return false
      continue
    if c in {' ', '\t', '>'}:
      break
    if c notin {'A'..'Z', 'a'..'z'}:
      return false
    tagn &= c.toLowerAscii()
  return tagn in ["pre", "script", "style", "textarea"]

type
  BlockType = enum
    btNone, btPar, btList, btPre, btTabPre, btSpacePre, btBlockquote, btHTML,
    btHTMLPre, btComment

  ParseState = object
    blockType: BlockType
    blockData: string
    listDepth: int
    lists: seq[ListType]
    hasp: bool
    reprocess: bool
    numPreLines: int

proc pushList(state: var ParseState; t: ListType) =
  case t
  of ltOl: stdout.write("<OL>\n<LI>")
  of ltUl: stdout.write("<UL>\n<LI>")
  state.lists.add(t)

proc popList(state: var ParseState) =
  case state.lists.pop()
  of ltOl: stdout.write("</OL>\n")
  of ltUl: stdout.write("</UL>\n")

proc parseNone(state: var ParseState; line: string) =
  if line == "":
    discard
  elif line[0] == '#' and line.toOpenArray(1, line.high).parseHash():
    discard
  elif line.startsWith("<!--"):
    state.blockType = btComment
    state.reprocess = true
  elif line[0] == '<' and line.find('>') == line.high:
    state.blockType = if line.matchHTMLPreStart(): btHTMLPre else: btHTML
    state.reprocess = true
  elif line.startsWith("```"):
    state.blockType = btPre
    stdout.write("<PRE>")
  elif line[0] == '\t':
    state.blockType = btTabPre
    if state.hasp:
      state.hasp = false
      stdout.write("</P>\n")
    stdout.write("<PRE>")
    state.blockData = line.substr(1) & '\n'
  elif line.startsWith("    "):
    state.blockType = btSpacePre
    if state.hasp:
      state.hasp = false
      stdout.write("</P>\n")
    stdout.write("<PRE>")
    state.blockData = line.substr(4) & '\n'
  elif line[0] == '>':
    state.blockType = btBlockquote
    if state.hasp:
      state.hasp = false
      stdout.write("</P>\n")
    state.blockData = line.substr(1) & "<BR>"
    stdout.write("<BLOCKQUOTE>")
  elif (let (n, len, t) = line.getListDepth(); n != -1):
    state.blockType = btList
    state.listDepth = n
    state.hasp = false
    state.pushList(t)
    state.blockData = line.substr(len + 1) & '\n'
  else:
    state.blockType = btPar
    state.hasp = true
    stdout.write("<P>\n")
    state.reprocess = true

proc parsePre(state: var ParseState; line: string) =
  if line.startsWith("```"):
    state.blockType = btNone
    stdout.write("</PRE>\n")
  else:
    stdout.write(line & '\n')

proc parseList(state: var ParseState; line: string) =
  if line == "":
    state.blockData.parseInline()
    state.blockData = ""
    while state.lists.len > 0:
      state.popList()
    state.blockType = btNone
  elif (let (n, len, t) = line.getListDepth(); n != -1):
    state.blockData.parseInline()
    state.blockData = ""
    if n < state.listDepth:
      if state.lists.len > 0:
        state.popList()
      else:
        state.pushList(t)
    elif n > state.listDepth:
      state.pushList(t)
    stdout.write("<LI>")
    state.listDepth = n
    state.blockData = line.substr(len + 1) & '\n'
  else:
    state.blockData &= line & '\n'

proc parsePar(state: var ParseState; line: string) =
  if line == "":
    state.blockData.parseInline()
    state.blockData = ""
    state.blockType = btNone
  elif line[0] == '<' and line.find('>') == line.high:
    state.blockData.parseInline()
    state.blockData = ""
    if line.matchHTMLPreStart():
      state.blockType = btHTMLPre
    else:
      state.blockType = btHTML
    state.reprocess = true
  elif line.len >= 3 and line.startsWith("```"):
    state.blockData.parseInline()
    state.blockData = ""
    state.blockType = btPre
    state.hasp = false
    stdout.write("<PRE>")
  else:
    state.blockData &= line & '\n'

proc parseHTML(state: var ParseState; line: string) =
  if state.hasp:
    state.hasp = false
    stdout.write("</P>\n")
  if line == "":
    state.blockData.parseInline()
    state.blockData = ""
    state.blockType = btNone
  else:
    state.blockData &= line & '\n'

proc parseHTMLPre(state: var ParseState; line: string) =
  if state.hasp:
    state.hasp = false
    stdout.write("</P>\n")
  if line.matchHTMLPreEnd():
    stdout.write(state.blockData)
    state.blockData = ""
    state.blockType = btNone
  else:
    state.blockData &= line & '\n'

proc parseTabPre(state: var ParseState; line: string) =
  if line.len == 0:
    inc state.numPreLines
  elif line[0] != '\t':
    state.numPreLines = 0
    stdout.write(state.blockData)
    stdout.write("</PRE>")
    state.blockData = ""
    state.reprocess = true
    state.blockType = btNone
  else:
    while state.numPreLines > 0:
      state.blockData &= '\n'
      dec state.numPreLines
    state.blockData &= line.substr(1) & '\n'

proc parseSpacePre(state: var ParseState; line: string) =
  if line.len == 0:
    inc state.numPreLines
  elif not line.startsWith("    "):
    state.numPreLines = 0
    stdout.write(state.blockData)
    stdout.write("</PRE>")
    state.blockData = ""
    state.reprocess = true
    state.blockType = btNone
  else:
    while state.numPreLines > 0:
      state.blockData &= '\n'
      dec state.numPreLines
    state.blockData &= line.substr(4) & '\n'

proc parseBlockquote(state: var ParseState; line: string) =
  if line.len == 0 or line[0] != '>':
    stdout.write(state.blockData)
    stdout.write("</BLOCKQUOTE>")
    state.blockData = ""
    state.reprocess = true
    state.blockType = btNone
  else:
    state.blockData &= line.substr(1) & "<BR>"

proc parseComment(state: var ParseState; line: string) =
  let i = line.find("-->")
  if i != -1:
    stdout.write(line.substr(0, i + 2))
    state.blockType = btNone
    line.substr(i + 3).parseInline()
  else:
    stdout.write(line & '\n')

proc main() =
  var line: string
  var state = ParseState(listDepth: -1)
  while state.reprocess or stdin.readLine(line):
    state.reprocess = false
    case state.blockType
    of btNone: state.parseNone(line)
    of btPre: state.parsePre(line)
    of btTabPre: state.parseTabPre(line)
    of btSpacePre: state.parseSpacePre(line)
    of btBlockquote: state.parseBlockquote(line)
    of btList: state.parseList(line)
    of btPar: state.parsePar(line)
    of btHTML: state.parseHTML(line)
    of btHTMLPre: state.parseHTMLPre(line)
    of btComment: state.parseComment(line)
  state.blockData.parseInline()

main()
