import base64
import strutils

import loader/connecterror
import loader/headers
import loader/loaderhandle
import loader/request
import types/url
import utils/twtstr

proc loadData*(handle: LoaderHandle, request: Request) =
  template t(body: untyped) =
    if not body:
      return
  var str = $request.url
  let si = "data:".len # start index
  var ct = ""
  for i in si ..< str.len:
    if str[i] == ',':
      break
    ct &= str[i]
  let sd = si + ct.len + 1 # data start
  let s = percentDecode(str, sd)
  if ct.endsWith(";base64"):
    try:
      let d = base64.decode(s) # decode from ct end + 1
      t handle.sendResult(0)
      t handle.sendStatus(200)
      ct.setLen(ct.len - ";base64".len) # remove base64 indicator
      t handle.sendHeaders(newHeaders({"Content-Type": ct}))
      t handle.sendData(d)
    except ValueError:
      discard handle.sendResult(ERROR_INVALID_DATA_URL)
  else:
    t handle.sendResult(0)
    t handle.sendStatus(200)
    t handle.sendHeaders(newHeaders({"Content-Type": ct}))
    t handle.sendData(s)
