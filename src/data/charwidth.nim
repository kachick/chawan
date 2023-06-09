import strutils

const (
  DoubleWidthRanges*,
  DoubleWidthAmbiguousRanges*,
  HalfWidthRanges*
) = (func(): (
    seq[(uint32, uint32)],
    seq[(uint32, uint32)],
    seq[(uint32, uint32)]
  ) =
  template add(firstcol: string, res: var seq[(uint32, uint32)]) =
    if firstcol.contains(".."):
      let fcs = firstcol.split("..")
      let rstart = uint32(parseHexInt(fcs[0]))
      let rend = uint32(parseHexInt(fcs[1]))
      res.add((rstart, rend))
    else:
      let cp = uint32(parseHexInt(firstcol))
      res.add((cp, cp))
  const map = staticRead"res/map/EastAsianWidth.txt"
  for line in map.split('\n'):
    if line.len == 0 or line[0] == '#':
      continue
    var i = 0
    var firstcol = ""
    var status = ""
    while i < line.len and line[i] notin {'#', ';'}:
      if line[i] != ' ':
        firstcol &= line[i]
      inc i
    if line[i] != '#':
      inc i
    while i < line.len and line[i] notin {'#', ';'}:
      if line[i] != ' ':
        status &= line[i]
      inc i
    case status
    of "W", "F": add(firstcol, result[0])
    of "A": add(firstcol, result[1])
    of "H": add(firstcol, result[2])
)()
