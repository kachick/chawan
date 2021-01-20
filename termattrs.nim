import terminal

type
  TermAttributes* = object
    termWidth*: int
    termHeight*: int

proc getTermAttributes*(): TermAttributes =
  var t = TermAttributes()
  t.termWidth = terminalWidth()
  t.termHeight = terminalHeight()
  return t
