import terminal

type
  TermAttributes* = object
    termWidth*: int
    termHeight*: int

proc getTermAttributes*(): TermAttributes =
  let attrs = TermAttributes(termWidth: terminalWidth(),
                             termHeight: terminalHeight())
  return attrs
