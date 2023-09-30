import bindings/curl

type ConnectErrorCode* = enum
  ERROR_TOO_MANY_REWRITES = (-14, "too many URI method map rewrites")
  ERROR_INVALID_URI_METHOD_ENTRY = (-13, "invalid URI method entry")
  ERROR_CGI_FILE_NOT_FOUND = (-12, "CGI file not found")
  ERROR_INVALID_CGI_PATH = (-11, "invalid CGI path")
  ERROR_FAIL_SETUP_CGI = (-10, "failed to set up CGI script")
  ERROR_NO_CGI_DIR = (-9, "no local-CGI directory configured")
  ERROR_INVALID_METHOD = (-8, "invalid method")
  ERROR_INVALID_DATA_URL = (-7, "invalid data URL")
  ERROR_ABOUT_PAGE_NOT_FOUND = (-6, "about page not found")
  ERROR_FILE_NOT_FOUND = (-5, "file not found")
  ERROR_SOURCE_NOT_FOUND = (-4, "clone source could not be found")
  ERROR_LOADER_KILLED = (-3, "loader killed during transfer")
  ERROR_DISALLOWED_URL = (-2, "url not allowed by filter")
  ERROR_UNKNOWN_SCHEME = (-1, "unknown scheme")

converter toInt*(code: ConnectErrorCode): int =
  return int(code)

func getLoaderErrorMessage*(code: int): string =
  if code < 0:
    return $ConnectErrorCode(code)
  return $curl_easy_strerror(CURLcode(cint(code)))
