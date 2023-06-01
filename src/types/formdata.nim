import types/blob

type
  FormDataEntry* = object
    name*: string
    filename*: string
    case isstr*: bool
    of true:
      svalue*: string
    of false:
      value*: Blob

  FormData* = ref object
    entries*: seq[FormDataEntry]

iterator items*(this: FormData): FormDataEntry {.inline.} =
  for entry in this.entries:
    yield entry
