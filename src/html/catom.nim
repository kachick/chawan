import std/hashes

import chame/tags

#TODO use a better hash map
const CAtomFactoryStrMapLength = 1024 # must be a power of 2
static:
  doAssert (CAtomFactoryStrMapLength and (CAtomFactoryStrMapLength - 1)) == 0

type
  CAtom* = distinct int

  #TODO could be a ptr probably
  CAtomFactory* = ref object of RootObj
    strMap: array[CAtomFactoryStrMapLength, seq[CAtom]]
    atomMap: seq[string]

const CAtomNull* = CAtom(0)

# Mandatory Atom functions
func `==`*(a, b: CAtom): bool {.borrow.}
func hash*(atom: CAtom): Hash {.borrow.}

func toAtom*(factory: CAtomFactory, s: string): CAtom

proc newCAtomFactory*(): CAtomFactory =
  const minCap = int(TagType.high) + 1
  let factory = CAtomFactory(
    atomMap: newSeqOfCap[string](minCap),
  )
  factory.atomMap.add("") # skip TAG_UNKNOWN
  for tagType in TagType(int(TAG_UNKNOWN) + 1) .. TagType.high:
    discard factory.toAtom($tagType)
  return factory

func toAtom*(factory: CAtomFactory, s: string): CAtom =
  let h = s.hash()
  let i = h and (factory.strMap.len - 1)
  for atom in factory.strMap[i]:
    if factory.atomMap[int(atom)] == s:
      # Found
      return atom
  # Not found
  let atom = CAtom(factory.atomMap.len)
  factory.atomMap.add(s)
  factory.strMap[i].add(atom)
  return atom

func toAtom*(factory: CAtomFactory, tagType: TagType): CAtom =
  assert tagType != TAG_UNKNOWN
  return CAtom(tagType)

func toStr*(factory: CAtomFactory, atom: CAtom): string =
  return factory.atomMap[int(atom)]

func toTagType*(factory: CAtomFactory, atom: CAtom): TagType =
  let i = int(atom)
  if i > 0 and i <= int(high(TagType)):
    return TagType(atom)
  return TAG_UNKNOWN
