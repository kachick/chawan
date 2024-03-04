import std/strutils
import std/tables

import utils/twtstr

import chame/tags

type
  InputType* = enum
    INPUT_TEXT, INPUT_BUTTON, INPUT_CHECKBOX, INPUT_COLOR, INPUT_DATE,
    INPUT_DATETIME_LOCAL, INPUT_EMAIL, INPUT_FILE, INPUT_HIDDEN, INPUT_IMAGE,
    INPUT_MONTH, INPUT_NUMBER, INPUT_PASSWORD, INPUT_RADIO, INPUT_RANGE,
    INPUT_RESET, INPUT_SEARCH, INPUT_SUBMIT, INPUT_TEL, INPUT_TIME, INPUT_URL,
    INPUT_WEEK

  ButtonType* = enum
    BUTTON_SUBMIT, BUTTON_RESET, BUTTON_BUTTON

  NodeType* = enum
    ELEMENT_NODE = 1,
    ATTRIBUTE_NODE = 2,
    TEXT_NODE = 3,
    CDATA_SECTION_NODE = 4,
    ENTITY_REFERENCE_NODE = 5,
    ENTITY_NODE = 6
    PROCESSING_INSTRUCTION_NODE = 7,
    COMMENT_NODE = 8,
    DOCUMENT_NODE = 9,
    DOCUMENT_TYPE_NODE = 10,
    DOCUMENT_FRAGMENT_NODE = 11,
    NOTATION_NODE = 12

  AttrType* = enum
    atUnknown = ""
    atAcceptCharset = "accept-charset"
    atAction = "action"
    atAlign = "align"
    atAlt = "alt"
    atAsync = "async"
    atBgcolor = "bgcolor"
    atBlocking = "blocking"
    atCharset = "charset"
    atChecked = "checked"
    atClass = "class"
    atClassList
    atColor = "color"
    atCols = "cols"
    atColspan = "colspan"
    atCrossorigin = "crossorigin"
    atDefer = "defer"
    atDirname = "dirname"
    atDisabled = "disabled"
    atEnctype = "enctype"
    atEvent = "event"
    atFor = "for"
    atForm = "form"
    atFormaction = "formaction"
    atFormenctype = "formenctype"
    atFormmethod = "formmethod"
    atHeight = "height"
    atHref = "href"
    atId = "id"
    atIntegrity = "integrity"
    atIsmap = "ismap"
    atLanguage = "language"
    atMedia = "media"
    atMethod = "method"
    atMultiple = "multiple"
    atName = "name"
    atNomodule = "nomodule"
    atOnload = "onload"
    atReferrerpolicy = "referrerpolicy"
    atRel = "rel"
    atRequired = "required"
    atRows = "rows"
    atRowspan = "rowspan"
    atSelected = "selected"
    atSize = "size"
    atSizes = "sizes"
    atSlot = "slot"
    atSrc = "src"
    atSrcset = "srcset"
    atStyle = "style"
    atStylesheet = "stylesheet"
    atTarget = "target"
    atText = "text"
    atTitle = "title"
    atType = "type"
    atUsemap = "usemap"
    atValign = "valign"
    atValue = "value"
    atWidth = "width"

const InputTypeWithSize* = {
  INPUT_SEARCH, INPUT_TEXT, INPUT_EMAIL, INPUT_PASSWORD, INPUT_URL, INPUT_TEL
}

const AutocapitalizeInheritingElements* = {
  TAG_BUTTON, TAG_FIELDSET, TAG_INPUT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA
}

const LabelableElements* = {
  # input only if type not hidden
  TAG_BUTTON, TAG_INPUT, TAG_METER, TAG_OUTPUT, TAG_PROGRESS, TAG_SELECT,
  TAG_TEXTAREA
}

# https://html.spec.whatwg.org/multipage/syntax.html#void-elements
const VoidElements* = {
  TAG_AREA, TAG_BASE, TAG_BR, TAG_COL, TAG_EMBED, TAG_HR, TAG_IMG, TAG_INPUT,
  TAG_LINK, TAG_META, TAG_SOURCE, TAG_TRACK, TAG_WBR
}

const ResettableElements* = {
  TAG_INPUT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA
}

func getInputTypeMap(): Table[string, InputType] =
  for i in InputType:
    let enumname = $InputType(i)
    let tagname = enumname.split('_')[1..^1].join('_').toLowerAscii()
    result[tagname] = InputType(i)

const inputTypeMap = getInputTypeMap()

func inputType*(s: string): InputType =
  return inputTypeMap.getOrDefault(s.toLowerAscii())

const AutoDirInput* = {
  INPUT_HIDDEN, INPUT_TEXT, INPUT_SEARCH, INPUT_TEL, INPUT_URL, INPUT_EMAIL,
  INPUT_PASSWORD, INPUT_SUBMIT, INPUT_RESET, INPUT_BUTTON
}
