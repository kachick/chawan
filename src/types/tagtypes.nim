import tables
import enums
import strutils

func getTagTypeMap(): Table[string, TagType] =
  for i in low(TagType) .. high(TagType):
    let enumname = $TagType(i)
    let tagname = enumname.split('_')[1..^1].join("_").tolower()
    result[tagname] = TagType(i)

func getInputTypeMap(): Table[string, InputType] =
  for i in low(InputType) .. high(InputType):
    let enumname = $InputType(i)
    let tagname = enumname.split('_')[1..^1].join("_").tolower()
    result[tagname] = InputType(i)

const tagTypeMap = getTagTypeMap()
const inputTypeMap = getInputTypeMap()

func tagType*(s: string): TagType =
  if tagTypeMap.hasKey(s):
    return tagTypeMap[s]
  else:
    return TAG_UNKNOWN

func inputType*(s: string): InputType =
  if inputTypeMap.hasKey(s):
    return inputTypeMap[s]
  else:
    return INPUT_UNKNOWN
