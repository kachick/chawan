import config/config
import css/sheet

type BufferConfig* = ref object
  userstyle*: CSSStylesheet

proc loadBufferConfig*(config: Config): BufferConfig =
  new(result)
  result.userstyle = parseStylesheet(config.stylesheet)
  zeroMem(addr config[], sizeof(ConfigObj))
