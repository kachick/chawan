import bindings/curl

type ConnectErrorCode* = enum
  ERROR_ABOUT_PAGE_NOT_FOUND = (-6, "about page not found")
  ERROR_FILE_NOT_FOUND = (-5, "file not found")
  ERROR_SOURCE_NOT_FOUND = (-4, "clone source could not be found"),
  ERROR_LOADER_KILLED = (-3, "loader killed during transfer"),
  ERROR_DISALLOWED_URL = (-2, "url not allowed by filter"),
  ERROR_UNKNOWN_SCHEME = (-1, "unknown scheme")

converter toInt*(code: ConnectErrorCode): int =
  return int(code)

func getLoaderErrorMessage*(code: int): string =
  if code < 0:
    return $ConnectErrorCode(code)
  return $curl_easy_strerror(CURLcode(cint(code)))
