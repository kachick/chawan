import std/algorithm
import std/streams
import std/tables

import config/mimetypes

const DefaultGuess* = block:
  let ss = newStringStream(staticRead"res/mime.types")
  parseMimeTypes(ss)

func guessContentType*(mimeTypes: MimeTypes; path: string;
    fallback = "application/octet-stream"): string =
  var n = 0
  for i in countdown(path.high, 0):
    if path[i] == '/':
      break
    if path[i] == '.':
      n = i
      break
  if n > 0:
    let ext = path.substr(n + 1)
    if ext in mimeTypes:
      return mimeTypes[ext]
  return fallback

const JavaScriptTypes = [
  "application/ecmascript",
  "application/javascript",
  "application/x-ecmascript",
  "application/x-javascript",
  "text/ecmascript",
  "text/javascript",
  "text/javascript1.0",
  "text/javascript1.1",
  "text/javascript1.2",
  "text/javascript1.3",
  "text/javascript1.4",
  "text/javascript1.5",
  "text/jscript",
  "text/livescript",
  "text/x-ecmascript",
  "text/x-javascript"
]

func isJavaScriptType*(s: string): bool =
  return JavaScriptTypes.binarySearch(s) != -1
