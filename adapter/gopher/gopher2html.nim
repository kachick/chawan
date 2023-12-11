# This file is dedicated to the public domain.
# Gopher directory -> HTML converter for Chawan.

import std/os
import std/streams
import std/strutils

type GopherType = enum
  UNKNOWN = "unsupported"
  TEXT_FILE = "text file"
  ERROR = "error"
  DIRECTORY = "directory"
  DOS_BINARY = "DOS binary"
  SEARCH = "search"
  MESSAGE = "message"
  SOUND = "sound"
  GIF = "gif"
  HTML = "HTML"
  INFO = ""
  IMAGE = "image"
  BINARY = "binary"
  PNG = "png"

func gopherType(c: char): GopherType =
  return case c
  of '0': TEXT_FILE
  of '1': DIRECTORY
  of '3': ERROR
  of '5': DOS_BINARY
  of '7': SEARCH
  of 'm': MESSAGE
  of 's': SOUND
  of 'g': GIF
  of 'h': HTML
  of 'i': INFO
  of 'I': IMAGE
  of '9': BINARY
  of 'p': PNG
  else: UNKNOWN

func htmlEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '<': result &= "&lt;"
    of '>': result &= "&gt;"
    of '&': result &= "&amp;"
    of '"': result &= "&quot;"
    of '\'': result &= "&apos;"
    else: result &= c

func until(s: string, c: char, starti = 0): string =
  for i in starti ..< s.len:
    if s[i] == c:
      break
    result &= s[i]

const ControlPercentEncodeSet = {char(0x00)..char(0x1F), char(0x7F)..char(0xFF)}
const QueryPercentEncodeSet = (ControlPercentEncodeSet + {' ', '"', '#', '<', '>'})
const PathPercentEncodeSet = (QueryPercentEncodeSet + {'?', '`', '{', '}'})
const HexCharsUpper = "0123456789ABCDEF"
proc percentEncode(s: string): string =
  result = ""
  for c in s:
    if c notin PathPercentEncodeSet:
      result &= c
    else:
      result &= '%'
      result &= HexCharsUpper[uint8(c) shr 4]
      result &= HexCharsUpper[uint8(c) and 0xF]

# returns URL
proc parseParams(): string =
  result = ""
  let params = commandLineParams()
  var was_u = false
  for param in params:
    if was_u:
      result = param
      was_u = false
    elif param == "-h" or param == "--help":
      stdout.write("Usage: gopher2html [-u URL]")
      quit(0)
    elif param == "-u":
      was_u = true
    else:
      stdout.write("Usage: gopher2html [-u URL]")
      quit(1)

proc main() =
  let url = parseParams()
  let escapedURL = htmlEscape(url)
  stdout.write("""
<!DOCTYPE HTML>
<HTML>
<HEAD>
<BASE HREF="""" & url & """">
<TITLE>Index of """ & escapedURL & """</TITLE>
</HEAD>
<BODY>
<H1>Index of """ & escapedURL & """</H1>""")
  let ins = newFileStream(stdin)
  var ispre = false
  while not ins.atEnd:
    let line = ins.readLine()
    if line.len == 0:
      break # invalid
    let tc = line[0]
    if tc == '.':
      break # end
    var i = 1
    template get_field(): string =
      let s = line.until('\t', i)
      i += s.len
      if i >= line.len or line[i] != '\t':
        break # invalid
      inc i
      s
    let t = gopherType(tc)
    let name = get_field()
    var file = get_field()
    let host = get_field()
    let port = line.until('\t', i) # ignore anything after port
    var outs = ""
    if t == INFO:
      if not ispre:
        outs &= "<PRE>"
        ispre = true
      outs &= htmlEscape(name) & '\n'
    else:
      if ispre:
        outs &= "</PRE>"
        ispre = false
      let ts = $t
      var names = ""
      if ts != "":
        names &= '[' & ts & ']'
      names &= htmlEscape(name)
      let ourls = if not file.startsWith("URL:"):
        if file.len == 0 or file[0] != '/':
          file = '/' & file
        let pefile = percentEncode(file)
        "gopher://" & host & ":" & port & "/" & tc & pefile
      else:
        file.substr("URL:".len)
      outs &= "<A HREF=\"" & htmlEscape(ourls) & "\">" & names & "</A><BR>\n"
    stdout.write(outs)

main()