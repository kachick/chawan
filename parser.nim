import parsexml
import htmlelement
import streams

func parseNextNode(str: string) =
  return

var s = ""
proc parseHtml*(inputStream: Stream) =
  var x: XmlParser
  x.open(inputStream, "")
  while true:
    x.next()
    case x.kind
    of xmlElementStart: discard
    of xmlEof: break
    else: discard
