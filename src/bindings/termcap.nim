const termlib = (func(): string =
  let libs = ["terminfo", "mytinfo", "termlib", "termcap", "tinfo", "ncurses", "curses"]
  for lib in libs:
    let res = staticExec("pkg-config --libs --silence-errors " & lib)
    if res != "":
      return res
)()
when termlib != "":
  {.passl: termlib.}
  {.push importc, cdecl.}
  const termcap_found* = true
  proc tgetent*(bp: cstring, name: cstring): cint
  proc tgetnum*(id: cstring): cint
  proc tgetflag*(id: cstring): cint
  proc tgetstr*(id: cstring, area: ptr cstring): cstring
  proc tgoto*(cap: cstring, x, y: cint): cstring
  proc tputs*(str: cstring, len: cint, putc: proc(c: char): cint {.cdecl.}): cint
  {.pop.}
else:
  const termcap_found* = false
