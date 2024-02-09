import std/strutils
import std/unicode
import utils/map

const CanHaveDakuten = ("かきくけこさしすせそたちつてとはひふへほカキクケコ" &
  "サシスセソタチツテトハヒフヘホ").toRunes()

const CanHaveHanDakuten = "はひふへほハヒフヘホ".toRunes()

const HasDakuten = ("がぎぐげござじずぜぞだぢづでどばびぶべぼガギグゲゴ" &
  "ザジズゼゾダヂヅデドバビブベボ").toRunes()

const HasHanDakuten = "ぱぴぷぺぽパピプペポ".toRunes()

# in unicode, char + 1 is dakuten and char + 2 handakuten

const HalfDakuten = Rune(0xFF9E) # half-width dakuten
const HalfHanDakuten = Rune(0xFF9F)

func dakuten(r: Rune): Rune =
  assert r in CanHaveDakuten
  return Rune(int32(r) + 1)

func handakuten(r: Rune): Rune =
  assert r in CanHaveHanDakuten
  return Rune(int32(r) + 2)

func nodakuten(r: Rune): Rune =
  return Rune(int32(r) - 1)

func nohandakuten(r: Rune): Rune =
  return Rune(int32(r) - 2)

# Halfwidth to fullwidth & vice versa
const halfFullMap = (func(): seq[tuple[half, full1, full2: Rune]] =
  result = @[]
  const map = staticRead"res/widthconvmap.tab"
  for line in map.split('\n'):
    if line == "":
      break
    var i = 0
    var half: Rune
    fastRuneAt(line, i, half)
    assert line[i] == '\t'
    inc i
    var full1: Rune
    fastRuneAt(line, i, full1)
    var full2 = Rune(0)
    if i < line.len:
      assert line[i] == '\t'
      inc i
      fastRuneAt(line, i, full2)
    result.add((half, full1, full2))
)()

func halfwidth(r: Rune): Rune =
  if r != Rune(0): # special case to avoid comparison with f2
    for (h, f1, f2) in halfFullMap:
      if f1 == r or f2 == r:
        return h
  return r

func halfwidth*(s: string): string =
  result = ""
  for r in s.runes:
    case r
    of HasDakuten:
      result &= halfwidth(r.nodakuten())
      result &= HalfDakuten
    of HasHanDakuten:
      result &= halfwidth(r.nohandakuten())
      result &= HalfHanDakuten
    else:
      result &= halfwidth(r)

func fullwidth(r: Rune): Rune =
  if r != Rune(0): # special case to avoid comparison with f2
    for (h, f1, f2) in halfFullMap:
      if h == r:
        return f1
  return r

func fullwidth*(s: string): string =
  result = ""
  var lastr = Rune(0)
  for r in s.runes:
    if lastr != Rune(0):
      if r == HalfDakuten:
        # flush with dakuten
        result &= lastr.dakuten()
        lastr = Rune(0)
        continue
      elif r == HalfHanDakuten:
        # flush with handakuten
        result &= lastr.handakuten()
        lastr = Rune(0)
        continue
      result &= lastr
      lastr = Rune(0)
    let r = fullwidth(r)
    if r in CanHaveDakuten:
      lastr = r
    else:
      result &= r
  if lastr != Rune(0):
    # flush
    result &= lastr

const kanamap = staticRead"res/kanamap.tab"
func genFullSizeMap(): seq[(uint32, uint32)] =
  result = @[]
  for line in kanamap.split('\n'):
    if line.len == 0: break
    let rs = line.toRunes()
    assert rs[1] == Rune('\t')
    result.add((uint32(rs[0]), uint32(rs[2])))
const fullSizeMap = genFullSizeMap()

proc fullsize*(s: string): string =
  result = ""
  for r in s.runes():
    let i = searchInMap(fullSizeMap, uint32(r))
    if i == -1:
      result &= r
    else:
      result &= $Rune(fullSizeMap[i][1])
