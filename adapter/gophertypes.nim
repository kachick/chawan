type GopherType* = enum
  gtUnknown = "unsupported"
  gtTextFile = "text file"
  gtError = "error"
  gtDirectory = "directory"
  gtDOSBinary = "DOS binary"
  gtSearch = "search"
  gtMessage = "message"
  gtSound = "sound"
  gtGif = "gif"
  gtHTML = "HTML"
  gtInfo = ""
  gtImage = "image"
  gtBinary = "binary"
  gtPng = "png"

func gopherType*(c: char): GopherType =
  return case c
  of '0': gtTextFile
  of '1': gtDirectory
  of '3': gtError
  of '5': gtDOSBinary
  of '7': gtSearch
  of 'm': gtMessage
  of 's': gtSound
  of 'g': gtGif
  of 'h': gtHTML
  of 'i': gtInfo
  of 'I': gtImage
  of '9': gtBinary
  of 'p': gtPng
  else: gtUnknown
