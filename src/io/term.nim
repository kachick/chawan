import terminal

import std/exitprocs

type
  TermAttributes* = object
    width*: int
    height*: int
    ppc*: int # cell width
    ppl*: int # cell height
    cell_ratio*: float64 # ppl / ppc
    width_px*: int
    height_px*: int

when defined(posix):
  import posix
  import termios

  # see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
  var orig_termios: Termios
  var stdin_fileno: FileHandle
  proc disableRawMode*() {.noconv.} =
    discard tcSetAttr(stdin_fileno, TCSAFLUSH, addr orig_termios)

  proc enableRawMode*(fileno: FileHandle) =
    stdin_fileno = fileno
    addExitProc(disableRawMode)
    discard tcGetAttr(fileno, addr orig_termios)
    var raw = orig_termios
    raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    raw.c_oflag = raw.c_oflag and not (OPOST)
    raw.c_cflag = raw.c_cflag or CS8
    raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
    discard tcSetAttr(fileno, TCSAFLUSH, addr raw)

  var orig_flags: cint
  var stdin_unblocked = false
  proc unblockStdin*(fileno: FileHandle) =
    orig_flags = fcntl(fileno, F_GETFL, 0)
    let flags = orig_flags or O_NONBLOCK
    discard fcntl(fileno, F_SETFL, flags)
    stdin_unblocked = true

  proc restoreStdin*(fileno: FileHandle) =
    if stdin_unblocked:
      discard fcntl(fileno, F_SETFL, orig_flags)
      stdin_unblocked = false
else:
  proc unblockStdin*(): cint =
    discard

  proc restoreStdin*(flags: cint) =
    discard

proc getTermAttributes*(tty: File): TermAttributes =
  if tty.isatty():
    when defined(posix):
      var win: IOctl_WinSize
      if ioctl(cint(getOsFileHandle(tty)), TIOCGWINSZ, addr win) != -1:
        result.ppc = int(win.ws_xpixel) div int(win.ws_col)
        result.ppl = int(win.ws_ypixel) div int(win.ws_row)
        # some terminals don't like it when we fill the last cell. #TODO make this optional
        result.width = int(win.ws_col) - 1
        result.height = int(win.ws_row)
        result.width_px = result.width * result.ppc
        result.height_px = result.height * result.ppl
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
