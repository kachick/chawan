import tables

import loader/connecterror
import loader/headers
import loader/loaderhandle
import loader/request
import types/url

const chawan = staticRead"res/chawan.html"
const HeaderTable = {
  "Content-Type": "text/html"
}.toTable()

proc loadAbout*(handle: LoaderHandle, request: Request) =
  template t(body: untyped) =
    if not body:
      return
  if request.url.pathname == "blank":
    t handle.sendResult(0)
    t handle.sendStatus(200) # ok
    t handle.sendHeaders(newHeaders(HeaderTable))
  elif request.url.pathname == "chawan":
    t handle.sendResult(0)
    t handle.sendStatus(200) # ok
    t handle.sendHeaders(newHeaders(HeaderTable))
    t handle.sendData(chawan)
  else:
    t handle.sendResult(ERROR_ABOUT_PAGE_NOT_FOUND)
