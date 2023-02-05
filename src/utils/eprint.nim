{.used.}

func eprint*(s: varargs[string, `$`]) = {.cast(noSideEffect), cast(tags: []), cast(raises: []).}:
  var a = false
  var o = ""
  when nimVm:
    for x in s:
      if not a:
        a = true
      else:
        o &= ' '
      o &= x
    echo o
  else:
    for x in s:
      if not a:
        a = true
      else:
        o &= ' '
      o &= x
    o &= '\n'
    stderr.write(o)
