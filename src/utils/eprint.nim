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

template print*(s: varargs[string, `$`]) =
  for x in s:
    stdout.write(x)

template printesc*(s: string) =
  for r in s.runes:
    if r.isControlChar():
      stdout.write(('^' & $($r)[0].getControlLetter())
                   .ansiFgColor(fgBlue).ansiStyle(styleBright).ansiReset())
    else:
      stdout.write($r)

