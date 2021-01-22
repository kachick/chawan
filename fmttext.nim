type
  FmtText* = object
    str*: string
    beginStyle*: string
    endStyle*: string

func `$`*(stt: FmtText): string =
  return stt.beginStyle & stt.str & stt.endStyle
