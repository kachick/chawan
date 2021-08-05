{.used.}

template eprint*(s: varargs[string, `$`]) = {.cast(noSideEffect).}:
  var a = false
  for x in s:
    if not a:
      a = true
    else:
      stderr.write(' ')
    stderr.write(x)
  stderr.write('\n')
