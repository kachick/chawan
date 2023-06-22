{.used.}

func eprint*(s: varargs[string, `$`]) =
  {.cast(noSideEffect), cast(tags: []), cast(raises: []).}:
    var o = ""
    for i in 0 ..< s.len:
      if i != 0:
        o &= ' '
      o &= s[i]
    when nimVm:
      echo o
    else:
      o &= '\n'
      stderr.write(o)

func elog*(s: varargs[string, `$`]) =
  {.cast(noSideEffect), cast(tags: []), cast(raises: []).}:
    var f: File
    if not open(f, "a", fmAppend):
      return
    var o = ""
    for i in 0 ..< s.len:
      if i != 0:
        o &= ' '
      o &= s[i]
    o &= '\n'
    f.write(o)
    close(f)
