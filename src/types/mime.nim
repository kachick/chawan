import tables

const DefaultGuess = [
  ("html", "text/html"),
  ("htm", "text/html"),
  ("xhtml", "application/xhtml+xml"),
  ("xhtm", "application/xhtml+xml"),
  ("xht", "application/xhtml+xml"),
].toTable()

proc guessContentType*(path: string): string =
  var i = path.len - 1
  var n = 0
  while i > 0:
    if path[i] == '/':
      return "text/plain"
    if path[i] == '.':
      n = i
      break
    dec i
  if n > 0:
    let ext = path.substr(n + 1)
    if ext in DefaultGuess:
      return DefaultGuess[ext]
  return "text/plain"
