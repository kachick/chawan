import config/config
import css/sheet

type BufferConfig* = object
  userstyle*: string

proc loadBufferConfig*(config: Config): BufferConfig =
  result.userstyle = config.stylesheet
