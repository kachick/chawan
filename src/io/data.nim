import base64
import strutils
import tables

import io/connecterror
import io/headers
import io/loaderhandle
import io/request
import types/url

proc loadData*(handle: LoaderHandle, request: Request) =
  template t(body: untyped) =
    if not body:
      return
  let str = $request.url
  let si = "data:".len # start index
  var ct = ""
  eprint "load data", str
  for i in si ..< str.len:
    if str[i] == ',':
      break
    ct &= str[i]
  let sd = si + ct.len + 1 # data start
  if ct.endsWith(";base64"):
    try:
      let d = base64.decode(str[sd .. ^1]) # decode from ct end + 1
      t handle.sendResult(0)
      t handle.sendStatus(200)
      ct.setLen(ct.len - ";base64".len) # remove base64 indicator
      t handle.sendHeaders(newHeaders({
        "Content-Type": ct
      }.toTable()))
      if d.len > 0:
        t handle.sendData(d)
    except ValueError:
      discard handle.sendResult(ERROR_INVALID_DATA_URL)
  else:
    t handle.sendResult(0)
    t handle.sendStatus(200)
    t handle.sendHeaders(newHeaders({
      "Content-Type": ct
    }.toTable()))
    if ct.len + 1 < str.len:
      eprint "send data", str[sd .. ^1], sd, str.len - sd
      t handle.sendData(addr str[sd], str.len - sd)
