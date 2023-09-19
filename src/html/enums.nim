import strutils
import tables

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

#TODO support all the other ones
const SupportedFormAssociatedElements* = {
  TAG_BUTTON, TAG_INPUT, TAG_SELECT, TAG_TEXTAREA
}

const InputTypeWithSize* = {
  INPUT_SEARCH, INPUT_TEXT, INPUT_EMAIL, INPUT_PASSWORD, INPUT_URL, INPUT_TEL
}

const AutocapitalizeInheritingElements* = {
  TAG_BUTTON, TAG_FIELDSET, TAG_INPUT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA
}

const LabelableElements* = {
  # input only if type not hidden
  TAG_BUTTON, TAG_INPUT, TAG_METER, TAG_OUTPUT, TAG_PROGRESS, TAG_SELECT, TAG_TEXTAREA
}

func getInputTypeMap(): Table[string, InputType] =
  for i in InputType:
    let enumname = $InputType(i)
    let tagname = enumname.split('_')[1..^1].join("_").toLowerAscii()
    result[tagname] = InputType(i)

const inputTypeMap = getInputTypeMap()

func inputType*(s: string): InputType =
  return inputTypeMap.getOrDefault(s.toLowerAscii())
