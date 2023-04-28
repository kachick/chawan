import options
import streams
import strutils

import bindings/curl
import io/request
import ips/serialize
import types/url
import utils/twtstr

type
  HandleData* = ref HandleDataObj
  HandleDataObj = object
    curl*: CURL
    statusline: bool
    headers: HeaderList
    request: Request
    ostream*: Stream
    mime: curl_mime
    slist: curl_slist

func newHandleData(curl: CURL, request: Request, ostream: Stream): HandleData =
  let handleData = HandleData(
    headers: newHeaderList(),
    curl: curl,
    ostream: ostream,
    request: request
  )
  return handleData

proc cleanup*(handleData: HandleData) =
  if handleData.mime != nil:
    curl_mime_free(handleData.mime)
  if handleData.slist != nil:
    curl_slist_free_all(handleData.slist)
  curl_easy_cleanup(handleData.curl)

template setopt(curl: CURL, opt: CURLoption, arg: typed) =
  discard curl_easy_setopt(curl, opt, arg)

template setopt(curl: CURL, opt: CURLoption, arg: string) =
  discard curl_easy_setopt(curl, opt, cstring(arg))

template getinfo(curl: CURL, info: CURLINFO, arg: typed) =
  discard curl_easy_getinfo(curl, info, arg)

proc curlWriteHeader(p: cstring, size: csize_t, nitems: csize_t, userdata: pointer): csize_t {.cdecl.} =
  var line = newString(nitems)
  for i in 0..<nitems:
    line[i] = p[i]

  let op = cast[HandleData](userdata)
  if not op.statusline:
    op.statusline = true
    op.ostream.swrite(int(CURLE_OK))
    var status: int
    op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
    op.ostream.swrite(status)
    return nitems

  let k = line.until(':')

  if k.len == line.len:
    # empty line (last, before body) or invalid (=> error)
    op.ostream.swrite(op.headers)
    return nitems

  let v = line.substr(k.len + 1).strip()
  op.headers.add(k, v)
  return nitems

proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t, userdata: pointer): csize_t {.cdecl.} =
  let handleData = cast[HandleData](userdata)
  if nmemb > 0:
    handleData.ostream.writeData(p, int(nmemb))
    handleData.ostream.flush()
  return nmemb

proc applyPostBody(curl: CURL, request: Request, handleData: HandleData) =
  if request.multipart.issome:
    handleData.mime = curl_mime_init(curl)
    if handleData.mime == nil:
      # fail (TODO: raise?)
      handleData.ostream.swrite(-1)
      handleData.ostream.flush()
      return
    for entry in request.multipart.get.content:
      let part = curl_mime_addpart(handleData.mime)
      if part == nil:
        # fail (TODO: raise?)
        handleData.ostream.swrite(-1)
        handleData.ostream.flush()
        return
      curl_mime_name(part, cstring(entry.name))
      if entry.isFile:
        if entry.isStream:
          curl_mime_filedata(part, cstring(entry.filename))
        else:
          let fd = readFile(entry.filename)
          curl_mime_data(part, cstring(fd), csize_t(fd.len))
        # may be overridden by curl_mime_filedata, so set it here
        curl_mime_filename(part, cstring(entry.filename))
      else:
        curl_mime_data(part, cstring(entry.content), csize_t(entry.content.len))
    curl.setopt(CURLOPT_MIMEPOST, handleData.mime)
  elif request.body.issome:
    curl.setopt(CURLOPT_POSTFIELDS, cstring(request.body.get))
    curl.setopt(CURLOPT_POSTFIELDSIZE, request.body.get.len)

proc loadHttp*(curlm: CURLM, request: Request, ostream: Stream): HandleData =
  let curl = curl_easy_init()
  if curl == nil:
    ostream.swrite(-1)
    ostream.flush()
    return # fail
  let surl = request.url.serialize()
  curl.setopt(CURLOPT_URL, surl)
  let handleData = curl.newHandleData(request, ostream)
  curl.setopt(CURLOPT_WRITEDATA, handleData)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  curl.setopt(CURLOPT_HEADERDATA, handleData)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
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
    ostream.swrite(int(res))
    ostream.flush()
    #TODO: raise here?
    return
  return handleData
