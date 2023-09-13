import terminal

when defined(posix):
  import termios


type
  WindowAttributes* = object
    width*: int
    height*: int
    ppc*: int # cell width
    ppl*: int # cell height
    cell_ratio*: float64 # ppl / ppc
    width_px*: int
    height_px*: int

proc getWindowAttributes*(tty: File): WindowAttributes =
  when defined(posix):
    if tty.isatty():
      var win: IOctl_WinSize
      if ioctl(cint(getOsFileHandle(tty)), TIOCGWINSZ, addr win) != -1:
        var cols = win.ws_col
        var rows = win.ws_row
        if cols == 0:
          cols = 80
        if rows == 0:
          rows = 24
        # Filling the last row without raw mode breaks things. However,
        # not supporting Windows means we can always have raw mode, so we can
        # use all available columns.
        result.width = int(cols)
        result.height = int(rows)
        result.ppc = int(win.ws_xpixel) div result.width
        result.ppl = int(win.ws_ypixel) div result.height
        # some terminal emulators (aka vte) don't set ws_xpixel or ws_ypixel.
        # solution: use xterm.
        if result.ppc == 0:
          result.ppc = 9
        if result.ppl == 0:
          result.ppl = 18
        result.width_px = result.width * result.ppc
        result.height_px = result.height * result.ppl
        result.cell_ratio = result.ppl / result.ppc
        return
  # for Windows. unused.
  result.width = terminalWidth() - 1
  result.height = terminalHeight()
  if result.height == 0:
    result.height = 24
  result.ppc = 9
  result.ppl = 18
  result.cell_ratio = result.ppl / result.ppc
  result.width_px = result.ppc * result.width
  result.height_px = result.ppl * result.height
