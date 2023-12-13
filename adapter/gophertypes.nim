type GopherType* = enum
  UNKNOWN = "unsupported"
  TEXT_FILE = "text file"
  ERROR = "error"
  DIRECTORY = "directory"
  DOS_BINARY = "DOS binary"
  SEARCH = "search"
  MESSAGE = "message"
  SOUND = "sound"
  GIF = "gif"
  HTML = "HTML"
  INFO = ""
  IMAGE = "image"
  BINARY = "binary"
  PNG = "png"

func gopherType*(c: char): GopherType =
  return case c
  of '0': TEXT_FILE
  of '1': DIRECTORY
  of '3': ERROR
  of '5': DOS_BINARY
  of '7': SEARCH
  of 'm': MESSAGE
  of 's': SOUND
  of 'g': GIF
  of 'h': HTML
  of 'i': INFO
  of 'I': IMAGE
  of '9': BINARY
  of 'p': PNG
  else: UNKNOWN
