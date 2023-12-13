import bindings/curl
import loader/connecterror

func curlErrorToChaError*(res: CURLcode): ConnectErrorCode =
  return case res
  of CURLE_OK: CONNECTION_SUCCESS
  of CURLE_URL_MALFORMAT: ERROR_INVALID_URL #TODO should never occur...
  of CURLE_COULDNT_CONNECT: ERROR_CONNECTION_REFUSED
  of CURLE_COULDNT_RESOLVE_PROXY: ERROR_FAILED_TO_RESOLVE_PROXY
  of CURLE_COULDNT_RESOLVE_HOST: ERROR_FAILED_TO_RESOLVE_HOST
  of CURLE_PROXY: ERROR_PROXY_REFUSED_TO_CONNECT
  else: ERROR_INTERNAL

proc getCurlConnectionError*(res: CURLcode): string =
  let e = $int(curlErrorToChaError(res))
  let msg = $curl_easy_strerror(res)
  return "Cha-Control: ConnectionError " & e & " " & msg & "\n"
