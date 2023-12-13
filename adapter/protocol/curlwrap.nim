import bindings/curl

template setopt*(curl: CURL, opt: CURLoption, arg: typed) =
  discard curl_easy_setopt(curl, opt, arg)

template setopt*(curl: CURL, opt: CURLoption, arg: string) =
  discard curl_easy_setopt(curl, opt, cstring(arg))

template getinfo*(curl: CURL, info: CURLINFO, arg: typed) =
  discard curl_easy_getinfo(curl, info, arg)

template set*(url: CURLU, part: CURLUPart, content: string, flags: cuint) =
  discard curl_url_set(url, part, cstring(content), flags)
