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

const SelfClosingTagTypes* = {
  TAG_LI, TAG_P
}

const VoidTagTypes* = {
  TAG_AREA, TAG_BASE, TAG_BR, TAG_COL, TAG_FRAME, TAG_HR, TAG_IMG, TAG_INPUT,
  TAG_SOURCE, TAG_TRACK, TAG_LINK, TAG_META, TAG_PARAM, TAG_WBR, TAG_HR
}

const PClosingTagTypes* = {
  TAG_ADDRESS, TAG_ARTICLE, TAG_ASIDE, TAG_BLOCKQUOTE, TAG_DETAILS, TAG_DIV,
  TAG_DL, TAG_FIELDSET, TAG_FIGCAPTION, TAG_FIGURE, TAG_FOOTER, TAG_FORM,
  TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6, TAG_HEADER, TAG_HGROUP,
  TAG_HR, TAG_MAIN, TAG_MENU, TAG_NAV, TAG_OL, TAG_P, TAG_PRE, TAG_SECTION,
  TAG_TABLE, TAG_UL
}

const HeadTagTypes* = {
  TAG_BASE, TAG_LINK, TAG_META, TAG_TITLE, TAG_NOSCRIPT, TAG_SCRIPT, TAG_NOFRAMES, TAG_STYLE, TAG_HEAD
}
