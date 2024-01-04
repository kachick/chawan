import std/unicode

# Lookup tables for characters on the BMP. This "only" takes up 8k of space
# per table, as opposed to the 135k that storing all characters would require.
# The downside is obviously that we need a binary search fallback for non-bmp.
# We do not store a lookup table of ambiguous ranges, either.

type
  ptint* = int32
  PropertyTable* = array[0x10000 div (sizeof(ptint) * 8), ptint]
  RangeMap* = openArray[(uint32, uint32)]

func makePropertyTable*(ranges: RangeMap, skip: RangeMap = @[]): PropertyTable =
  var ucs: uint32 = 0
  var j = 0
  var k = 0
  while ucs <= 0xFFFF:
    if k > ranges.len:
      break
    if ranges[k][0] > ucs:
      ucs = ranges[k][0]
      continue
    if ranges[k][1] < ucs:
      inc k
      continue
    if j != skip.len and ucs == skip[j][0]:
      ucs = skip[j][1] + 1
      continue
    let i = ucs div (sizeof(ptint) * 8)
    let m = ucs mod (sizeof(ptint) * 8)
    result[i] = result[i] or ptint(1 shl m)
    inc ucs

{.push boundChecks:off.}
func contains*(props: PropertyTable, r: Rune): bool =
  let u = ptint(r)
  let i = u div (sizeof(ptint) * 8)
  let m = u mod (sizeof(ptint) * 8)
  return (props[i] and (1 shl m)) != 0
{.pop.}
