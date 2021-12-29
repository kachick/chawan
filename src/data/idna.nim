import algorithm
import unicode
import sets
import tables
import sugar
import strutils

type IDNATableStatus* = enum
  IDNA_VALID, IDNA_IGNORED, IDNA_MAPPED, IDNA_DEVIATION, IDNA_DISALLOWED

const IdnaMappingTable = staticRead"res/IdnaMappingTable.txt"

func loadStuff(s: string): (seq[(uint16, cstring)], seq[(int, cstring)],
                            seq[(uint16, uint16)], seq[(int, int)],
                            set[uint16], HashSet[int],
                            set[uint16], HashSet[int],
                            seq[(uint16, cstring)]) =
  template add_map(i: int, str: string) =
    if cast[uint](i) <= high(uint16):
      result[0].add((cast[uint16](i), cstring(str)))
    else:
      result[1].add((i, cstring(str)))
  template add_disallow(i, j: int) =
    if cast[uint](i) <= high(uint16):
      result[2].add((cast[uint16](i), cast[uint16](j)))
    else:
      result[3].add((i, j))
  template add_disallow(i: int) =
    if cast[uint](i) <= high(uint16):
      result[4].incl(cast[uint16](i))
    else:
      result[5].incl(i)
  template add_ignore(i: int) =
    if cast[uint](i) <= high(uint16):
      result[6].incl(cast[uint16](i))
    else:
      result[7].incl(i)
  template add_deviation(i: int, str: string) =
    if cast[uint](i) <= high(uint16):
      result[8].add((cast[uint16](i), cstring(str)))
    else:
      assert false

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

      if firstcol.contains(".."):
        let fcs = firstcol.split("..")
        let rstart = parseHexInt(fcs[0])
        let rend = parseHexInt(fcs[1])
        for i in rstart..rend:
          add_map(i, str)
      else:
        add_map(parseHexInt(firstcol), str)
    of "deviation":
      let codepoints = thirdcol
      var str = ""
      for code in codepoints:
        str &= Rune(parseHexInt(code))
      if firstcol.contains(".."):
        let fcs = firstcol.split("..")
        let rstart = parseHexInt(fcs[0])
        let rend = parseHexInt(fcs[1])
        for i in rstart..rend:
          add_deviation(i, str)
      else:
        add_deviation(parseHexInt(firstcol), str)
    of "valid":
      if fourthcol == "NV8" or fourthcol == "XV8":
        if firstcol.contains(".."):
          let fcs = firstcol.split("..")
          let rstart = parseHexInt(fcs[0])
          let rend = parseHexInt(fcs[1])
          add_disallow(rstart, rend)
        else:
          add_disallow(parseHexInt(firstcol))
    of "disallowed":
      if firstcol.contains(".."):
        let fcs = firstcol.split("..")
        let rstart = parseHexInt(fcs[0])
        let rend = parseHexInt(fcs[1])
        add_disallow(rstart, rend)
      else:
        add_disallow(parseHexInt(firstcol))
    of "ignored":
      if firstcol.contains(".."):
        let fcs = firstcol.split("..")
        let rstart = parseHexInt(fcs[0])
        let rend = parseHexInt(fcs[1])
        for i in rstart..rend:
          add_ignore(i)
      else:
        add_ignore(parseHexInt(firstcol))

when defined(release):
  const (MappedMap1,
         MappedMap2,
         DisallowedRanges1,
         DisallowedRanges2,
         Disallowed1,
         Disallowed2,
         Ignored1,
         Ignored2,
         Deviation) = loadStuff(IdnaMappingTable)
else:
  let (MappedMap1,
         MappedMap2,
         DisallowedRanges1,
         DisallowedRanges2,
         Disallowed1,
         Disallowed2,
         Ignored1,
         Ignored2,
         Deviation) = loadStuff(IdnaMappingTable)

func searchInMap[U, T](a: openarray[(U, T)], u: U): int =
  binarySearch(a, u, (x, y) => cmp(x[0], y))

func isInMap[U, T](a: openarray[(U, T)], u: U): bool =
  a.searchInMap(u) != -1

func isInRange[U](a: openarray[(U, U)], u: U): bool =
  binarySearch(a, u, (x, y) => (if x[0] < y: -1 elif x[1] > y: 1 else: 0)) != -1

func getIdnaTableStatus*(r: Rune): IDNATableStatus =
  let i = int(r)
  {.cast(noSideEffect).}:
    if cast[uint](i) <= high(uint16):
      let u = cast[uint16](i)
      if u in Ignored1:
        return IDNA_IGNORED
      if u in Disallowed1:
        return IDNA_DISALLOWED
      for item in Deviation:
        if item[0] == u:
          return IDNA_DEVIATION
      if DisallowedRanges1.isInRange(u):
        return IDNA_DISALLOWED
      if MappedMap1.isInMap(u):
        return IDNA_MAPPED
    else:
      if i in Ignored2:
        return IDNA_IGNORED
      if i in Disallowed2:
        return IDNA_DISALLOWED
      if DisallowedRanges2.isInRange(i):
        return IDNA_DISALLOWED
      if MappedMap2.isInMap(i):
        return IDNA_MAPPED
    return IDNA_VALID

func getIdnaMapped*(r: Rune): string =
  {.cast(noSideEffect).}:
    let i = int(r)
    if cast[uint](i) <= high(uint16):
      let u = cast[uint16](i)
      let n = MappedMap1.searchInMap(u)
      if n != -1:
        return $MappedMap1[n][1]
    let n = MappedMap2.searchInMap(i)
    return $MappedMap2[n][1]

func getDeviationMapped*(r: Rune): string =
  {.cast(noSideEffect).}:
    for item in Deviation:
      if item[0] == cast[uint16](r):
        return $item[1]
