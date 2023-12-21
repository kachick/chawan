import std/strutils

import utils/twtstr

proc main() =
  # We use `display: block' for anchors because they are supposed to be
  # presented on separate lines per standard.
  # We use `white-space: pre-line' on the entire body so that we do not have
  # to emit a <br> character for each paragraph. ("Why not p?" Because gemini
  # does not allow collapsing newlines, so we would have to use <br> or empty
  # <p> tags for them. Neither make a lot more sense semantically than the
  # simplest and most efficient solution, which is just using newlines.)
  stdout.write("""
<!DOCTYPE html>
<style>
a { display: block }
body { white-space: pre-line }
a, pre, ul, blockquote, li, h1, h2, h3 { margin-top: 0; margin-bottom: 0 }
</style>
""")
  var inpre = false
  var inul = false
  while not stdin.endOfFile:
    let line = stdin.readLine()
    if inpre and not line.startsWith("```"):
      stdout.write(line.htmlEscape() & "\n")
      continue
    if inul and not line.startsWith("* "):
      stdout.write("</ul>")
      inul = false
    if line.len == 0:
      stdout.write("\n")
      continue
    if line.startsWith("=>"): # link
      let i = line.skipBlanks(2)
      let url = line.until(AsciiWhitespace, i)
      let text = if i + url.len < line.len:
        let j = line.skipBlanks(i + url.len)
        line.substr(j).htmlEscape()
      else:
        url.htmlEscape()
      stdout.write("<a href='" & url.htmlEscape() & "'>" & text & "</a>")
    elif line.startsWith("```"): # preformatting toggle
      inpre = not inpre
      let title = line.substr(3).htmlEscape()
      if inpre:
        stdout.write("<pre title='" & title & "'>")
      else:
        stdout.write("</pre>")
    elif line.startsWith("#"): # heading line
      var i = 1
      while i < line.len and i < 3 and line[i] == '#':
        inc i
      let h = "h" & $i
      i = line.skipBlanks(i) # ignore whitespace after #
      stdout.write("<" & h & ">" & line.substr(i).htmlEscape() & "</" & h & ">")
    elif line.startsWith("* "): # unordered list item
      if not inul:
        inul = true
        stdout.write("<ul>")
      stdout.write("<li>" & line.substr(2).htmlEscape() & "</li>")
    elif line.startsWith(">"): # quote
      stdout.write("<blockquote>")
      stdout.write(line.substr(1).htmlEscape())
      stdout.write("</blockquote>")
    else:
      stdout.write(line.htmlEscape() & "\n")

main()
