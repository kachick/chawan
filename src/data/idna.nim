import algorithm
import unicode
import sets
import tables
import sugar
import strutils

type
  IDNATableStatus* = enum
    IDNA_VALID, IDNA_IGNORED, IDNA_MAPPED, IDNA_DEVIATION, IDNA_DISALLOWED

type
  LowMap[T] = seq[(uint16, T)]
  FullMap[T] = (LowMap[T], seq[(uint32, T)])
  FullRangeList = (seq[(uint16, uint16)], seq[(uint32, uint32)])
  FullSet = (set[uint16], HashSet[uint32])

const IdnaMappingTable = staticRead"res/IdnaMappingTable.txt"

func loadStuff(s: string): (FullMap[cstring], # Map
                            FullRangeList, # Disallowed Ranges
                            FullSet, # Disallowed
                            FullSet, # Ignored
                            LowMap[cstring]) = # Deviation
  template add_map(i: uint32, str: string) =
    if i <= high(uint16):
      result[0][0].add((uint16(i), cstring(str)))
    else:
      result[0][1].add((i, cstring(str)))
  template add_disallow(i, j: uint32) =
    if i <= high(uint16):
      result[1][0].add((uint16(i), uint16(j)))
    else:
      result[1][1].add((i, j))
  template add_disallow(i: uint32) =
    if i <= high(uint16):
      result[2][0].incl(uint16(i))
    else:
      result[2][1].incl(i)
  template add_ignore(rstart, rend: uint32) =
    for i in rstart..rend:
      if i <= high(uint16):
        result[3][0].incl(uint16(i))
      else:
        result[3][1].incl(i)
  template add_ignore(i: uint32) =
    if i <= high(uint16):
      result[3][0].incl(uint16(i))
    else:
      result[3][1].incl(i)
  template add_deviation(i: uint32, str: string) =
    if i <= high(uint16):
      result[4].add((uint16(i), cstring(str)))
    else:
      assert false
  template add(firstcol: string, str: string, temp: untyped) =
    if firstcol.contains(".."):
      let fcs = firstcol.split("..")
      let rstart = uint32(parseHexInt(fcs[0]))
      let rend = uint32(parseHexInt(fcs[1]))
      for i in rstart..rend:
        temp(i, str)
    else:
      temp(uint32(parseHexInt(firstcol)), str)
  template add(firstcol: string, temp: untyped) =
    if firstcol.contains(".."):
      let fcs = firstcol.split("..")
      let rstart = uint32(parseHexInt(fcs[0]))
      let rend = uint32(parseHexInt(fcs[1]))
      temp(rstart, rend)
    else:
      temp(uint32(parseHexInt(firstcol)))

  for line in s.split('\n'):
    if line.len == 0 or line[0] == '#':
      continue
    var i = 0
    var firstcol = ""
    var status = ""
    var thirdcol: seq[string]
    var fourthcol = ""

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
    if line[i] != '#':
      inc i

    var nw = true
    while i < line.len and line[i] notin {'#', ';'}:
      if line[i] == ' ':
        nw = true
      else:
        if nw:
          thirdcol.add("")
          nw = false
        thirdcol[^1] &= line[i]
      inc i
    if line[i] != '#':
      inc i

    while i < line.len and line[i] notin {'#', ';'}:
      if line[i] != ' ':
        fourthcol &= line[i]
      inc i

    case status
    of "mapped", "disallowed_STD3_mapped":
      let codepoints = thirdcol
      var str = ""
      for code in codepoints:
        str &= Rune(parseHexInt(code))

      add(firstcol, str, add_map)
    of "deviation":
      let codepoints = thirdcol
      var str = ""
      for code in codepoints:
        str &= Rune(parseHexInt(code))

      add(firstcol, str, add_deviation)
    of "valid":
      if fourthcol == "NV8" or fourthcol == "XV8":
        add(firstcol, add_disallow)
    of "disallowed":
      add(firstcol, add_disallow)
    of "ignored":
      add(firstcol, add_ignore)

when defined(release):
  const (MappedMap,
         DisallowedRanges,
         Disallowed,
         Ignored,
         Deviation) = loadStuff(IdnaMappingTable)
else:
  let (MappedMap,
       DisallowedRanges,
       Disallowed,
       Ignored,
       Deviation) = loadStuff(IdnaMappingTable)

func searchInMap[U, T](a: openarray[(U, T)], u: U): int =
  binarySearch(a, u, (x, y) => cmp(x[0], y))

func isInMap[U, T](a: openarray[(U, T)], u: U): bool =
  a.searchInMap(u) != -1

func isInRange[U](a: openarray[(U, U)], u: U): bool =
  binarySearch(a, u, (x, y) => (if x[0] < y: -1 elif x[1] > y: 1 else: 0)) != -1

func getIdnaTableStatus*(r: Rune): IDNATableStatus =
  let i = uint32(r)
  {.cast(noSideEffect).}:
    if i <= high(uint16):
      let u = uint16(i)
      if u in Ignored[0]:
        return IDNA_IGNORED
      if u in Disallowed[0]:
        return IDNA_DISALLOWED
      for item in Deviation:
        if item[0] == u:
          return IDNA_DEVIATION
      if DisallowedRanges[0].isInRange(u):
        return IDNA_DISALLOWED
      if MappedMap[0].isInMap(u):
        return IDNA_MAPPED
    else:
      if i in Ignored[1]:
        return IDNA_IGNORED
      if i in Disallowed[1]:
        return IDNA_DISALLOWED
      if DisallowedRanges[1].isInRange(i):
        return IDNA_DISALLOWED
      if MappedMap[1].isInMap(uint32(i)):
        return IDNA_MAPPED
    return IDNA_VALID

func getIdnaMapped*(r: Rune): string =
  {.cast(noSideEffect).}:
    let i = uint32(r)
    if i <= high(uint16):
      let u = uint16(i)
      let n = MappedMap[0].searchInMap(u)
      if n != -1:
        return $MappedMap[0][n][1]
    let n = MappedMap[1].searchInMap(i)
    return $MappedMap[1][n][1]

func getDeviationMapped*(r: Rune): string =
  {.cast(noSideEffect).}:
    for item in Deviation:
      if item[0] == uint16(r):
        return $item[1]
