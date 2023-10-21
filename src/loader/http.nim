import options
import strutils

import bindings/curl
import loader/curlhandle
import loader/curlwrap
import loader/headers
import loader/loaderhandle
import loader/request
import types/blob
import types/formdata
import types/opt
import types/url
import utils/twtstr

type
  EarlyHintState = enum
    NO_EARLY_HINT, EARLY_HINT_STARTED, EARLY_HINT_DONE

  HttpHandle = ref object of CurlHandle
    earlyhint: EarlyHintState

func newHttpHandle(curl: CURL, request: Request, handle: LoaderHandle):
    HttpHandle =
  return HttpHandle(
    headers: newHeaders(),
    curl: curl,
    handle: handle,
    request: request
  )

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  if nitems > 0:
    prepareMutation(line)
    copyMem(addr line[0], p, nitems)

  let op = cast[HttpHandle](userdata)
  if not op.statusline:
    op.statusline = true
    if op.earlyhint == NO_EARLY_HINT:
      if not op.handle.sendResult(int(CURLE_OK)):
        return 0
    var status: clong
    op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
    if status == 103 and op.earlyhint == NO_EARLY_HINT:
      op.earlyhint = EARLY_HINT_STARTED
    else:
      if not op.handle.sendStatus(cast[int](status)):
        return 0
    return nitems

  let k = line.until(':')

  if k.len == line.len:
    # empty line (last, before body) or invalid (=> error)
    if op.earlyhint == EARLY_HINT_STARTED:
      # ignore; we do not have a way to stream headers yet.
      op.earlyhint = EARLY_HINT_DONE
      # reset statusline; we are awaiting the next line.
      op.statusline = false
      return nitems
    if not op.handle.sendHeaders(op.headers):
      return 0
    return nitems

  let v = line.substr(k.len + 1).strip()
  op.headers.add(k, v)
  return nitems

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t,
    userdata: pointer): csize_t {.cdecl.} =
  let handleData = cast[HttpHandle](userdata)
  if nmemb > 0:
    if not handleData.handle.sendData(p, int(nmemb)):
      return 0
  return nmemb

proc applyPostBody(curl: CURL, request: Request, handleData: HttpHandle) =
  if request.multipart.isOk:
    handleData.mime = curl_mime_init(curl)
    doAssert handleData.mime != nil
    for entry in request.multipart.get:
      let part = curl_mime_addpart(handleData.mime)
      doAssert part != nil
      curl_mime_name(part, cstring(entry.name))
      if entry.isstr:
        curl_mime_data(part, cstring(entry.svalue), csize_t(entry.svalue.len))
      else:
        let blob = entry.value
        if blob.isfile: #TODO ?
          curl_mime_filedata(part, cstring(WebFile(blob).path))
        else:
          curl_mime_data(part, blob.buffer, csize_t(blob.size))
        # may be overridden by curl_mime_filedata, so set it here
        curl_mime_filename(part, cstring(entry.filename))
    curl.setopt(CURLOPT_MIMEPOST, handleData.mime)
  elif request.body.issome:
    curl.setopt(CURLOPT_POSTFIELDS, cstring(request.body.get))
    curl.setopt(CURLOPT_POSTFIELDSIZE, request.body.get.len)

proc loadHttp*(handle: LoaderHandle, curlm: CURLM,
    request: Request): HttpHandle =
  let curl = curl_easy_init()
  doAssert curl != nil
  let surl = request.url.serialize()
  curl.setopt(CURLOPT_URL, surl)
  let handleData = curl.newHttpHandle(request, handle)
  curl.setopt(CURLOPT_WRITEDATA, handleData)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  curl.setopt(CURLOPT_HEADERDATA, handleData)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
  if request.proxy != nil:
    let purl = request.proxy.serialize()
    curl.setopt(CURLOPT_PROXY, purl)
  case request.httpmethod
  of HTTP_GET:
    curl.setopt(CURLOPT_HTTPGET, 1)
  of HTTP_POST:
    curl.setopt(CURLOPT_POST, 1)
    curl.applyPostBody(request, handleData)
  else: discard #TODO
  for k, v in request.headers:
    let header = k & ": " & v
    handleData.slist = curl_slist_append(handleData.slist, cstring(header))
  if handleData.slist != nil:
    curl.setopt(CURLOPT_HTTPHEADER, handleData.slist)
  let res = curl_multi_add_handle(curlm, curl)
  if res != CURLM_OK:
    discard handle.sendResult(int(res))
    return nil
  return handleData
