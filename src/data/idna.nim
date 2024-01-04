import std/unicode

import utils/map

include res/map/idna_gen

type
  IDNATableStatus* = enum
    IDNA_VALID, IDNA_IGNORED, IDNA_MAPPED, IDNA_DEVIATION, IDNA_DISALLOWED

func getIdnaTableStatus*(r: Rune): IDNATableStatus =
  let i = uint32(r)
  if i <= high(uint16):
    let u = uint16(i)
    if u in IgnoredLow:
      return IDNA_IGNORED
    if u in DisallowedLow:
      return IDNA_DISALLOWED
    for item in Deviation:
      if item[0] == u:
        return IDNA_DEVIATION
    if DisallowedRangesLow.isInRange(u):
      return IDNA_DISALLOWED
    if MappedMapLow.isInMap(u):
      return IDNA_MAPPED
  else:
    if i in IgnoredHigh:
      return IDNA_IGNORED
    if i in DisallowedHigh:
      return IDNA_DISALLOWED
    if DisallowedRangesHigh.isInRange(i):
      return IDNA_DISALLOWED
    if MappedMapHigh.isInMap(uint32(i)):
      return IDNA_MAPPED
  return IDNA_VALID

func getIdnaMapped*(r: Rune): string =
  let i = uint32(r)
  if i <= high(uint16):
    let u = uint16(i)
    let n = MappedMapLow.searchInMap(u)
    if n != -1:
      return $MappedMapLow[n].mapped
  let n = MappedMapHigh.searchInMap(i)
  return $MappedMapHigh[n].mapped

func getDeviationMapped*(r: Rune): string =
  for item in Deviation:
    if item[0] == uint16(r):
      return $item[1]
  return ""
