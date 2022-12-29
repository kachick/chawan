import streams
import tables

import io/request
import ips/serialize
import types/url

const chawan = staticRead"res/chawan.html"
const Headers = {
  "Content-Type": "text/html"
}.toTable()

proc loadAbout*(request: Request, ostream: Stream) =
  if request.url.pathname == "blank":
    ostream.swrite(0)
    ostream.swrite(200) # ok
    let headers = newHeaderList(Headers)
    ostream.swrite(headers)
  elif request.url.pathname == "chawan":
    ostream.swrite(0)
    ostream.swrite(200) # ok
    let headers = newHeaderList(Headers)
    ostream.swrite(headers)
    ostream.write(chawan)
  else:
    ostream.swrite(-1)
  ostream.flush()

