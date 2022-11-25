{.used.}

template eprint*(s: varargs[string, `$`]) = {.cast(noSideEffect), cast(tags: []), cast(raises: []).}:
  var a = false
  when nimVm:
    var o = ""
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
        stderr.write(' ')
      stderr.write(x)
    stderr.write('\n')
