import terminal
when defined(posix):
  import termios

type
  TermAttributes* = object
    width*: int
    height*: int
    ppc*: int
    ppl*: int

proc getTermAttributes*(): TermAttributes =
  if stdin.isatty():
    when defined(posix):
      var win: IOctl_WinSize
      if ioctl(cint(getOsFileHandle(stdout)), TIOCGWINSZ, addr win) != -1:
        result.width = int(win.ws_col)
        result.height = int(win.ws_row)
        result.ppc = int(win.ws_xpixel) div int(win.ws_col)
        result.ppl = int(win.ws_ypixel) div int(win.ws_row)
        return
  #fail
  result.width = terminalWidth()
  result.height = terminalHeight()
  if result.height == 0:
    result.height = 24
  result.ppc = 9
  result.ppl = 18
