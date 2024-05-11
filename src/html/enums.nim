import chame/tags

type
  InputType* = enum
    itText = "text"
    itButton = "button"
    itCheckbox = "checkbox"
    itColor = "color"
    itDate = "date"
    itDatetimeLocal = "datetime-local"
    itEmail = "email"
    itFile = "file"
    itHidden = "hidden"
    itImage = "image"
    itMonth = "month"
    itNumber = "number"
    itPassword = "password"
    itRadio = "radio"
    itRange = "range"
    itReset = "reset"
    itSearch = "search"
    itSubmit = "submit"
    itTel = "tel"
    itTime = "time"
    itURL = "url"
    itWeek = "week"

  ButtonType* = enum
    btSubmit = "submit"
    btReset = "reset"
    btButton = "button"

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

const InputTypeWithSize* = {
  itSearch, itText, itEmail, itPassword, itURL, itTel
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

const AutoDirInput* = {
  itHidden, itText, itSearch, itTel, itURL, itEmail, itPassword, itSubmit,
  itReset, itButton
}
