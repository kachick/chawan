import terminal
when defined(posix):
  import termios

type
  TermAttributes* = object
    width*: int
    height*: int
    ppc*: int # cell width
    ppl*: int # cell height
    cell_ratio*: float64 # ppl / ppc
    width_px*: int
    height_px*: int

proc getTermAttributes*(): TermAttributes =
  if stdin.isatty():
    when defined(posix):
      var win: IOctl_WinSize
      if ioctl(cint(getOsFileHandle(stdout)), TIOCGWINSZ, addr win) != -1:
        result.ppc = int(win.ws_xpixel) div int(win.ws_col)
        result.ppl = int(win.ws_ypixel) div int(win.ws_row)
        result.width = int(win.ws_col) - 1
        result.height = int(win.ws_row)
        result.width_px = int(win.ws_xpixel) - result.ppc
        result.height_px = int(win.ws_ypixel)
        result.cell_ratio = result.ppl / result.ppc
        return
  #fail
  result.width = terminalWidth() - 1
  result.height = terminalHeight()
  if result.height == 0:
    result.height = 24
  result.ppc = 9
  result.ppl = 18
  result.cell_ratio = result.ppl / result.ppc
  result.width_px = result.ppc * result.width
  result.height_px = result.ppl * result.height
