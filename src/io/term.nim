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
  let stdin_fileno = stdin.getFileHandle()
  var orig_termios: Termios
  proc disableRawMode*() {.noconv.} =
    discard tcSetAttr(stdin_fileno, TCSAFLUSH, addr orig_termios)

  proc enableRawMode*() =
    addExitProc(disableRawMode)
    discard tcGetAttr(stdin_fileno, addr orig_termios)
    var raw = orig_termios
    raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    raw.c_oflag = raw.c_oflag and not (OPOST)
    raw.c_cflag = raw.c_cflag or CS8
    raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
    discard tcSetAttr(stdin_fileno, TCSAFLUSH, addr raw)

  var orig_flags: cint
  var stdin_unblocked = false
  proc unblockStdin*() =
    orig_flags = fcntl(getFileHandle(stdin), F_GETFL, 0)
    let flags = orig_flags or O_NONBLOCK
    discard fcntl(getFileHandle(stdin), F_SETFL, flags)
    stdin_unblocked = true

  proc restoreStdin*() =
    if stdin_unblocked:
      discard fcntl(getFileHandle(stdin), F_SETFL, orig_flags)
      stdin_unblocked = false
else:
  proc unblockStdin*(): cint =
    discard

  proc restoreStdin*(flags: cint) =
    discard

proc getTermAttributes*(): TermAttributes =
  if stdin.isatty():
    when defined(posix):
      var win: IOctl_WinSize
      if ioctl(cint(getOsFileHandle(stdout)), TIOCGWINSZ, addr win) != -1:
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
