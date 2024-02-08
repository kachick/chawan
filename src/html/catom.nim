import std/hashes

import html/enums

import chame/tags

#TODO use a better hash map
const CAtomFactoryStrMapLength = 1024 # must be a power of 2
static:
  doAssert (CAtomFactoryStrMapLength and (CAtomFactoryStrMapLength - 1)) == 0

# Null atom + mapped tag types + mapped attr types
const AttrMapNum = 1 + ({TagType.low..TagType.high} - {TAG_UNKNOWN}).card +
  ({AttrType.low..AttrType.high} - {atUnknown}).card

type
  CAtom* = distinct int

  CAtomFactoryInit = object
    obj: CAtomFactoryObj
    attrToAtom: array[AttrType, CAtom]
    atomToAttr: array[AttrMapNum, AttrType]

  CAtomFactoryObj = object
    strMap: array[CAtomFactoryStrMapLength, seq[CAtom]]
    atomMap: seq[string]

  #TODO could be a ptr probably
  CAtomFactory* = ref CAtomFactoryObj

const CAtomNull* = CAtom(0)

# Mandatory Atom functions
func `==`*(a, b: CAtom): bool {.borrow.}
func hash*(atom: CAtom): Hash {.borrow.}

func `$`*(a: CAtom): string {.borrow.}

func toAtom(factory: var CAtomFactoryObj, s: string): CAtom =
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

const factoryInit = (func(): CAtomFactoryInit =
  var init = CAtomFactoryInit()
  # Null atom
  init.obj.atomMap.add("")
  # TagType: 1..TagType.high
  for tagType in TagType(1) .. TagType.high:
    discard init.obj.toAtom($tagType)
  # Attr: may overlap with TagType; exclude atUnknown
  for attrType in AttrType(1) .. AttrType.high:
    let atom = init.obj.toAtom($attrType)
    init.attrToAtom[attrType] = atom
    init.atomToAttr[int(atom)] = attrType
  return init
)()

proc newCAtomFactory*(): CAtomFactory =
  let factory = new(CAtomFactory)
  factory[] = factoryInit.obj
  return factory

func toAtom*(factory: CAtomFactory, s: string): CAtom =
  return factory[].toAtom(s)

func toAtom*(factory: CAtomFactory, tagType: TagType): CAtom =
  assert tagType != TAG_UNKNOWN
  return CAtom(tagType)

func toAtom*(factory: CAtomFactory, attrType: AttrType): CAtom =
  assert attrType != atUnknown
  return factoryInit.attrToAtom[attrType]

func toStr*(factory: CAtomFactory, atom: CAtom): string =
  return factory.atomMap[int(atom)]

func toTagType*(factory: CAtomFactory, atom: CAtom): TagType =
  let i = int(atom)
  if i in 1 .. int(TagType.high):
    return TagType(atom)
  return TAG_UNKNOWN

func toAttrType*(factory: CAtomFactory, atom: CAtom): AttrType =
  let i = int(atom)
  if i < factoryInit.atomToAttr.len:
    return factoryInit.atomToAttr[i]
  return atUnknown
