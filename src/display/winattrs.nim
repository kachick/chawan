when defined(posix):
  import std/termios

type
  WindowAttributes* = object
    width*: int
    height*: int
    ppc*: int # cell width
    ppl*: int # cell height
    width_px*: int
    height_px*: int

proc isatty(fd: FileHandle): cint {.importc: "isatty", header: "<unistd.h>".}
proc isatty*(f: File): bool =
  return isatty(f.getFileHandle()) != 0

proc getWindowAttributes*(tty: File): WindowAttributes =
  if tty.isatty():
    var win: IOctl_WinSize
    if ioctl(cint(getOsFileHandle(tty)), TIOCGWINSZ, addr win) != -1:
      var cols = int(win.ws_col)
      var rows = int(win.ws_row)
      if cols == 0:
        cols = 80
      if rows == 0:
        rows = 24
      var ppc = int(win.ws_xpixel) div cols
      var ppl = int(win.ws_ypixel) div rows
      # some terminal emulators (aka vte) don't set ws_xpixel or ws_ypixel.
      # solution: use xterm.
      if ppc == 0:
        ppc = 9
      if ppl == 0:
        ppl = 18
      # Filling the last row without raw mode breaks things. However,
      # not supporting Windows means we can always have raw mode, so we can
      # use all available columns.
      return WindowAttributes(
        width: cols,
        height: rows,
        ppc: ppc,
        ppl: ppl,
        width_px: cols * ppc,
        height_px: rows * ppl
      )
  # Fallback for ioctl failure
  let height = 24
  let width = 80
  let ppc = 9
  let ppl = 18
  return WindowAttributes(
    width: width,
    height: height,
    ppc: ppc,
    ppl: ppl,
    width_px: ppc * width,
    height_px: ppl * height
  )
