import curl

template setopt*(curl: CURL, opt: CURLoption, arg: typed) =
  discard curl_easy_setopt(curl, opt, arg)

template setopt*(curl: CURL, opt: CURLoption, arg: string) =
  discard curl_easy_setopt(curl, opt, cstring(arg))

template getinfo*(curl: CURL, info: CURLINFO, arg: typed) =
  discard curl_easy_getinfo(curl, info, arg)

template set*(url: CURLU, part: CURLUPart, content: string, flags: cuint) =
  discard curl_url_set(url, part, cstring(content), flags)

template get*(url: CURLU, part: CURLUPart, flags: cuint): cstring =
  var outs: cstring
  if curl_url_get(url, part, addr outs, flags) == CURLUE_OK:
    outs
  else:
    nil
