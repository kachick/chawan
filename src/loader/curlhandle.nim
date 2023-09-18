import bindings/curl
import loader/headers
import loader/loaderhandle
import loader/request

type
  CurlHandle* = ref object of RootObj
    curl*: CURL
    statusline*: bool
    headers*: Headers
    request*: Request
    handle*: LoaderHandle
    mime*: curl_mime
    slist*: curl_slist
    finish*: proc(handle: CurlHandle)

func newCurlHandle*(curl: CURL, request: Request, handle: LoaderHandle):
    CurlHandle =
  return CurlHandle(
    headers: newHeaders(),
    curl: curl,
    handle: handle,
    request: request
  )

proc cleanup*(handleData: CurlHandle) =
  handleData.handle.close()
  if handleData.mime != nil:
    curl_mime_free(handleData.mime)
  if handleData.slist != nil:
    curl_slist_free_all(handleData.slist)
  curl_easy_cleanup(handleData.curl)
