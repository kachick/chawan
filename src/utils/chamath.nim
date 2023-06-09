func absSub*(a, b: SomeUnsignedInt): auto {.inline.} =
  if a > b:
    return a - b
  return b - a
