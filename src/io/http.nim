import options
import streams
import strutils

import bindings/curl
import io/loadertypes
import types/url
import types/mime
import utils/twtstr

type
  HeaderResult* = ref object
    statusline: bool
    headers: HeaderList

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

  let headers = cast[HeaderResult](userdata)
  if not headers.statusline:
    headers.statusline = true
    return nitems #TODO handle status line?

  let k = line.until(':')

  if k.len == line.len:
    return nitems # empty line (last, before body) or invalid (=> error)

  let v = line.substr(k.len + 1).strip()
  headers.headers.add(k, v)
  return nitems

proc curlWriteBody(p: cstring, size: csize_t, nmemb: csize_t, userdata: pointer): csize_t {.cdecl.} =
  var s = newString(nmemb)
  for i in 0..<nmemb:
    s[i] = p[i]
  let stream = cast[Stream](userdata)
  stream.write(s)
  stream.flush()
  return nmemb

proc getPageHttp*(request: Request): LoadResult =
  let curl = curl_easy_init()

  if curl == nil: return # fail

  let surl = request.url.serialize()
  curl.setopt(CURLOPT_URL, surl)

  var cs = newStringStream()
  curl.setopt(CURLOPT_WRITEDATA, cs)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)

  let headerres = HeaderResult(headers: newHeaderList())
  curl.setopt(CURLOPT_HEADERDATA, headerres)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)

  var mime: curl_mime = nil

  case request.httpmethod
  of HTTP_GET: curl.setopt(CURLOPT_HTTPGET, 1)
  of HTTP_POST:
    curl.setopt(CURLOPT_POST, 1)
    if request.multipart.issome:
      mime = curl_mime_init(curl)
      if mime == nil: return # fail
      for entry in request.multipart.get.content:
        let part = curl_mime_addpart(mime)
        if part == nil: return # fail
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
      curl.setopt(CURLOPT_MIMEPOST, mime)
    elif request.body.issome:
      curl.setopt(CURLOPT_POSTFIELDS, cstring(request.body.get))
      curl.setopt(CURLOPT_POSTFIELDSIZE, request.body.get.len)
  else: discard #TODO

  var slist: curl_slist = nil
  for k, v in request.headers:
    let header = k & ": " & v
    slist = curl_slist_append(slist, cstring(header))
  if slist != nil:
    curl.setopt(CURLOPT_HTTPHEADER, slist)

  let res = curl_easy_perform(curl)
  if res == CURLE_OK: # TODO handle errors
    cs.setPosition(0)
    result.s = cs

    let ct = headerres.headers.getOrDefault("Content-Type")
    if ct != "":
      result.contenttype = ct.until(';')
    else:
      result.contenttype = guessContentType(request.url.path.serialize())
    curl.getinfo(CURLINFO_RESPONSE_CODE, addr result.status)
    if result.status in {301, 302, 303}: #TODO 300, 304, 307
      var urlp: cstring
      curl.getinfo(CURLINFO_REDIRECT_URL, addr urlp)
      if urlp != nil:
        let urls = $urlp
        result.redirect = parseUrl(urls, some(request.url))

  curl_easy_cleanup(curl)
  if mime != nil:
    curl_mime_free(mime)
  if slist != nil:
    curl_slist_free_all(slist)
