import std/strutils

import utils/twtstr

type BracketState = enum
  bsNone, bsInBracket

proc getId(line: openArray[char]): string =
  result = ""
  var i = 0
  var bs = bsNone
  while i < line.len:
    case (let c = line[i]; c)
    of AsciiAlphaNumeric, '-', '_', '.': result &= c.toLowerAscii()
    of ' ': result &= '-'
    of '[':
      bs = bsInBracket
    of ']':
      if bs == bsInBracket:
        if i + 1 < line.len and line[i + 1] == '(':
          inc i
          while i < line.len:
            let c = line[i]
            if c == '\\':
              inc i
            elif c == ')':
              break
            inc i
        bs = bsNone
    else: discard
    inc i

type InlineFlag = enum
  ifItalic, ifBold, ifDel

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
  bracketRef: bool
  flags: set[InlineFlag]

proc parseInTag(ctx: var ParseInlineContext; line: openArray[char]) =
  var buf = ""
  var i = ctx.i + 1
  while i < line.len:
    let c = line[i]
    if c == '>': # done
      if buf.startsWithScheme(): # link
        stdout.write("<A HREF='" & buf.htmlEscape() & "'>" & buf & "</A>")
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

proc append(ctx: var ParseInlineContext; s: string) =
  if ctx.bs == bsInBracket:
    ctx.bracketChars &= s
  else:
    stdout.write(s)

proc append(ctx: var ParseInlineContext; c: char) =
  if ctx.bs == bsInBracket:
    ctx.bracketChars &= c
  else:
    stdout.write(c)

type CommentState = enum
  csNone, csDash, csDashDash

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
  let i = ctx.i + 1
  let j = line.toOpenArray(i, line.high).find('`')
  if j != -1:
    ctx.append("<CODE>")
    ctx.append(line.toOpenArray(i, i + j - 1).htmlEscape())
    ctx.append("</CODE>")
    ctx.i = i + j
  else:
    ctx.append('`')

proc parseLinkDestination(url: var string; line: openArray[char]; i: int): int =
  var i = i
  var quote = false
  var parens = 0
  let sc = line[i]
  if sc == '<':
    inc i
  while i < line.len:
    let c = line[i]
    if quote:
      quote = false
    elif sc == '<' and c == '>' or sc != '<' and c in AsciiWhitespace + {')'}:
      break
    elif c in {'<', '\n'} or c in Controls and sc != '<':
      return -1
    elif c == '\\':
      quote = true
    elif c == '(':
      inc parens
      url &= c
    elif c == ')' and sc != '>':
      if parens == 0:
        break
      dec parens
      url &= c
    else:
      url &= c
    inc i
  if sc != '>' and parens != 0 or quote:
    return -1
  return line.skipBlanks(i)

proc parseTitle(title: var string; line: openArray[char]; i: int): int =
  let ec = line[i]
  var i = i + 1
  var quote = false
  while i < line.len:
    let c = line[i]
    if quote:
      quote = false
    elif c == '\\':
      quote = true
    elif c == ec:
      inc i
      break
    else:
      title &= c
    inc i
  return line.skipBlanks(i)

proc parseLink(ctx: var ParseInlineContext; line: openArray[char]) =
  let i = ctx.i + 1
  if i >= line.len or line[i] != '(':
    #TODO reference links
    stdout.write('[' & ctx.bracketChars & ']')
    return
  var url = ""
  var j = url.parseLinkDestination(line, line.skipBlanks(i + 1))
  var title = ""
  if j != -1 and j < line.len and line[j] in {'(', '"', '\''}:
    j = title.parseTitle(line, j)
  if j == -1 or j >= line.len or line[j] != ')':
    stdout.write('[' & ctx.bracketChars & ']')
  else:
    let url = url.htmlEscape()
    stdout.write("<A HREF='" & url)
    if title != "":
      stdout.write("' TITLE='" & title.htmlEscape())
    stdout.write("'>")
    stdout.write(ctx.bracketChars)
    stdout.write("</A>")
    ctx.i = j

proc parseImageAlt(text: var string; line: openArray[char]; i: int): int =
  var i = i
  var brackets = 0
  while i < line.len:
    let c = line[i]
    if c == '\\':
      inc i
    elif c == '<':
      while i < line.len and line[i] != '>':
        text &= c
        inc i
    elif c == '[':
      inc brackets
      text &= c
    elif line[i] == ']':
      if brackets == 0:
        break
      dec brackets
      text &= c
    else:
      text &= c
    inc i
  return i

proc parseImage(ctx: var ParseInlineContext; line: openArray[char]) =
  var text = ""
  let i = text.parseImageAlt(line, ctx.i + 2)
  if i == -1 or i + 1 >= line.len or line[i] != ']' or line[i + 1] != '(':
    ctx.append("![")
    return
  var url = ""
  var j = url.parseLinkDestination(line, line.skipBlanks(i + 2))
  var title = ""
  if j != -1 and j < line.len and line[j] in {'(', '"', '\''}:
    j = title.parseTitle(line, j)
  if j == -1 or j >= line.len or line[j] != ')':
    ctx.append("![")
  else:
    ctx.append("<IMG SRC='" & url.htmlEscape())
    if title != "":
      ctx.append("' TITLE='" & title.htmlEscape())
    if text != "":
      ctx.append("' ALT='" & text.htmlEscape())
    ctx.append("'>")
    ctx.i = j

proc appendToggle(ctx: var ParseInlineContext; f: InlineFlag; s, e: string) =
  if f notin ctx.flags:
    ctx.flags.incl(f)
    ctx.append(s)
  else:
    ctx.flags.excl(f)
    ctx.append(e)

proc parseInline(line: openArray[char]) =
  var ctx = ParseInlineContext()
  while ctx.i < line.len:
    let c = line[ctx.i]
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
        ctx.appendToggle(ifBold, "<B>", "</B>")
        inc ctx.i
      else:
        ctx.appendToggle(ifItalic, "<I>", "</I>")
    elif c == '`':
      ctx.parseCode(line)
    elif c == '~' and ctx.i + 1 < line.len and line[ctx.i + 1] == '~':
      ctx.appendToggle(ifDel, "<DEL>", "</DEL>")
      inc ctx.i
    elif c == '!' and ctx.i + 1 < line.len and line[ctx.i + 1] == '[':
      ctx.parseImage(line)
    elif c == '[':
      if ctx.bs == bsInBracket:
        stdout.write('[' & ctx.bracketChars)
        ctx.bracketChars = ""
      ctx.bs = bsInBracket
      ctx.bracketRef = ctx.i + 1 < line.len and line[ctx.i + 1] == '^'
      if ctx.bracketRef:
        inc ctx.i
    elif c == ']' and ctx.bs == bsInBracket:
      if ctx.bracketRef:
        let id = ctx.bracketChars.getId()
        stdout.write("<A HREF='#" & id & "'>" & ctx.bracketChars & "</A>")
      else:
        ctx.parseLink(line)
      ctx.bracketChars = ""
      ctx.bracketRef = false
      ctx.bs = bsNone
    elif c == '<':
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
  if ctx.bs == bsInBracket:
    stdout.write("[")
  if ctx.bracketChars != "":
    stdout.write(ctx.bracketChars)
  if ifBold in ctx.flags:
    stdout.write("</B>")
  if ifItalic in ctx.flags:
    stdout.write("</I>")
  if ifDel in ctx.flags:
    stdout.write("</DEL>")

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
    else:
      if c in {'*', '-'}:
        let i = i + 1
        if i < line.len and line[i] in {'\t', ' '}:
          return (depth, i, ltUl)
      elif c in {'0'..'9'}:
        let i = i + 1
        if i < line.len and line[i] == '.':
          let i = i + 1
          if i < line.len and line[i] in {'\t', ' '}:
            return (depth, i, ltOl)
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
    stdout.write(line.htmlEscape() & '\n')

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
    state.blockData &= line.toOpenArray(1, line.high).htmlEscape() & '\n'

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
    state.blockData &= line.toOpenArray(4, line.high).htmlEscape() & '\n'

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
    line.toOpenArray(i + 3, line.high).parseInline()
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
