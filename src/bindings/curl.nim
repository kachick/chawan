const curllib = (func(): string =
  when defined(windows): return "libcurl.dll"
  elif defined(macos): return "libcurl(|.4|.4.8.0).dylib"
  else: return "libcurl.so(|.4|.4.8.0)" # assume posix
)()

const
  CURL_GLOBAL_SSL* = 1 shl 0 # no purpose since 7.57.0
  CURL_GLOBAL_WIN32* = 1 shl 1
  CURL_GLOBAL_ALL* = CURL_GLOBAL_SSL or CURL_GLOBAL_WIN32
  CURL_GLOBAL_NOTHING* = 0
  CURL_GLOBAL_DEFAULT* = CURL_GLOBAL_ALL
  CURL_GLOBAL_ACK_EINTR* = 1 shl 2

const
  CURLOPTTYPE_LONG = 0
  CURLOPTTYPE_OBJECTPOINT = 10000
  CURLOPTTYPE_FUNCTIONPOINT = 20000
  CURLOPTTYPE_OFF_T = 30000
  CURLOPTTYPE_BLOB = 40000

const
  CURLOPTTYPE_STRINGPOINT = CURLOPTTYPE_OBJECTPOINT
  CURLOPTTYPE_SLISTPOINT = CURLOPTTYPE_OBJECTPOINT
  CURLOPTTYPE_CBPOINT = CURLOPTTYPE_OBJECTPOINT
  CURLOPTTYPE_VALUES = CURLOPTTYPE_LONG

{.push cdecl, dynlib: curllib.}

type
  CURL* = pointer

  curl_mime_struct = object
  curl_mime* = ptr curl_mime_struct
  curl_mimepart_struct = object
  curl_mimepart* = ptr curl_mimepart_struct
  curl_slist_struct = object
  curl_slist* = ptr curl_mimepart_struct

  CURLoption* {.size: sizeof(cint).} = enum
    # Long
    CURLOPT_PORT = CURLOPTTYPE_LONG + 3
    CURLOPT_POST = CURLOPTTYPE_LONG + 47
    CURLOPT_FOLLOWLOCATION = CURLOPTTYPE_LONG + 52
    CURLOPT_POSTFIELDSIZE = CURLOPTTYPE_LONG + 60
    CURLOPT_HTTPGET = CURLOPTTYPE_LONG + 80

    # Objectpoint
    CURLOPT_WRITEDATA = CURLOPTTYPE_CBPOINT + 1
    CURLOPT_URL = CURLOPTTYPE_STRINGPOINT + 2
    CURLOPT_POSTFIELDS = CURLOPTTYPE_OBJECTPOINT + 15
    CURLOPT_HTTPHEADER = CURLOPTTYPE_SLISTPOINT + 23
    CURLOPT_HEADERDATA = CURLOPTTYPE_CBPOINT + 29
    CURLOPT_MIMEPOST = CURLOPTTYPE_OBJECTPOINT + 269

    # Functionpoint
    CURLOPT_WRITEFUNCTION = CURLOPTTYPE_FUNCTIONPOINT + 11
    CURLOPT_READFUNCTION = CURLOPTTYPE_FUNCTIONPOINT + 12
    CURLOPT_HEADERFUNCTION = CURLOPTTYPE_FUNCTIONPOINT + 79

    # Off-t
    CURLOPT_INFILESIZE_LARGE = CURLOPTTYPE_OFF_T + 115
    CURLOPT_RESUME_FROM_LARGE = CURLOPTTYPE_OFF_T + 116

    # Blob
    CURLOPT_SSLCERT_BLOB = CURLOPTTYPE_BLOB + 291
    CURLOPT_SSLKEY_BLOB = CURLOPTTYPE_BLOB + 292
    CURLOPT_PROXY_SSLCERT_BLOB = CURLOPTTYPE_BLOB + 293
    CURLOPT_PROXY_SSLKEY_BLOB = CURLOPTTYPE_BLOB + 294
    CURLOPT_ISSUECERT_BLOB = CURLOPTTYPE_BLOB + 295

  CURLcode* {.size: sizeof(cint).} = enum
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL,    # 1 
    CURLE_FAILED_INIT,             # 2 
    CURLE_URL_MALFORMAT,           # 3 
    CURLE_NOT_BUILT_IN,            # 4 - [was obsoleted in August 2007 for
                                   # 7.17.0, reused in April 2011 for 7.21.5]
    CURLE_COULDNT_RESOLVE_PROXY,   # 5 
    CURLE_COULDNT_RESOLVE_HOST,    # 6 
    CURLE_COULDNT_CONNECT,         # 7 
    CURLE_WEIRD_SERVER_REPLY,      # 8 
    CURLE_REMOTE_ACCESS_DENIED,    # 9 a service was denied by the server
                                   # due to lack of access - when login fails
                                   # this is not returned.
    CURLE_FTP_ACCEPT_FAILED,       # 10 - [was obsoleted in April 2006 for
                                   # 7.15.4, reused in Dec 2011 for 7.24.0]
    CURLE_FTP_WEIRD_PASS_REPLY,    # 11 
    CURLE_FTP_ACCEPT_TIMEOUT,      # 12 - timeout occurred accepting server
                                   # [was obsoleted in August 2007 for 7.17.0,
                                   # reused in Dec 2011 for 7.24.0]
    CURLE_FTP_WEIRD_PASV_REPLY,    # 13 
    CURLE_FTP_WEIRD_227_FORMAT,    # 14 
    CURLE_FTP_CANT_GET_HOST,       # 15 
    CURLE_HTTP2,                   # 16 - A problem in the http2 framing layer.
                                   # [was obsoleted in August 2007 for 7.17.0,
                                   # reused in July 2014 for 7.38.0]
    CURLE_FTP_COULDNT_SET_TYPE,    # 17 
    CURLE_PARTIAL_FILE,            # 18 
    CURLE_FTP_COULDNT_RETR_FILE,   # 19 
    CURLE_OBSOLETE20,              # 20 - NOT USED 
    CURLE_QUOTE_ERROR,             # 21 - quote command failure 
    CURLE_HTTP_RETURNED_ERROR,     # 22 
    CURLE_WRITE_ERROR,             # 23 
    CURLE_OBSOLETE24,              # 24 - NOT USED 
    CURLE_UPLOAD_FAILED,           # 25 - failed upload "command" 
    CURLE_READ_ERROR,              # 26 - couldn't open/read from file 
    CURLE_OUT_OF_MEMORY,           # 27 
    CURLE_OPERATION_TIMEDOUT,      # 28 - the timeout time was reached 
    CURLE_OBSOLETE29,              # 29 - NOT USED 
    CURLE_FTP_PORT_FAILED,         # 30 - FTP PORT operation failed 
    CURLE_FTP_COULDNT_USE_REST,    # 31 - the REST command failed 
    CURLE_OBSOLETE32,              # 32 - NOT USED 
    CURLE_RANGE_ERROR,             # 33 - RANGE "command" didn't work 
    CURLE_HTTP_POST_ERROR,         # 34 
    CURLE_SSL_CONNECT_ERROR,       # 35 - wrong when connecting with SSL 
    CURLE_BAD_DOWNLOAD_RESUME,     # 36 - couldn't resume download 
    CURLE_FILE_COULDNT_READ_FILE,  # 37 
    CURLE_LDAP_CANNOT_BIND,        # 38 
    CURLE_LDAP_SEARCH_FAILED,      # 39 
    CURLE_OBSOLETE40,              # 40 - NOT USED 
    CURLE_FUNCTION_NOT_FOUND,      # 41 - NOT USED starting with 7.53.0 
    CURLE_ABORTED_BY_CALLBACK,     # 42 
    CURLE_BAD_FUNCTION_ARGUMENT,   # 43 
    CURLE_OBSOLETE44,              # 44 - NOT USED 
    CURLE_INTERFACE_FAILED,        # 45 - CURLOPT_INTERFACE failed 
    CURLE_OBSOLETE46,              # 46 - NOT USED 
    CURLE_TOO_MANY_REDIRECTS,      # 47 - catch endless re-direct loops 
    CURLE_UNKNOWN_OPTION,          # 48 - User specified an unknown option 
    CURLE_SETOPT_OPTION_SYNTAX,    # 49 - Malformed setopt option 
    CURLE_OBSOLETE50,              # 50 - NOT USED 
    CURLE_OBSOLETE51,              # 51 - NOT USED 
    CURLE_GOT_NOTHING,             # 52 - when this is a specific error 
    CURLE_SSL_ENGINE_NOTFOUND,     # 53 - SSL crypto engine not found 
    CURLE_SSL_ENGINE_SETFAILED,    # 54 - can not set SSL crypto engine as
                                   # default
    CURLE_SEND_ERROR,              # 55 - failed sending network data 
    CURLE_RECV_ERROR,              # 56 - failure in receiving network data 
    CURLE_OBSOLETE57,              # 57 - NOT IN USE 
    CURLE_SSL_CERTPROBLEM,         # 58 - problem with the local certificate 
    CURLE_SSL_CIPHER,              # 59 - couldn't use specified cipher 
    CURLE_PEER_FAILED_VERIFICATION, # 60 - peer's certificate or fingerprint
                                   # wasn't verified fine
    CURLE_BAD_CONTENT_ENCODING,    # 61 - Unrecognized/bad encoding 
    CURLE_OBSOLETE62,              # 62 - NOT IN USE since 7.82.0 
    CURLE_FILESIZE_EXCEEDED,       # 63 - Maximum file size exceeded 
    CURLE_USE_SSL_FAILED,          # 64 - Requested FTP SSL level failed 
    CURLE_SEND_FAIL_REWIND,        # 65 - Sending the data requires a rewind
                                   # that failed
    CURLE_SSL_ENGINE_INITFAILED,   # 66 - failed to initialise ENGINE 
    CURLE_LOGIN_DENIED,            # 67 - user, password or similar was not
                                   # accepted and we failed to login
    CURLE_TFTP_NOTFOUND,           # 68 - file not found on server 
    CURLE_TFTP_PERM,               # 69 - permission problem on server 
    CURLE_REMOTE_DISK_FULL,        # 70 - out of disk space on server 
    CURLE_TFTP_ILLEGAL,            # 71 - Illegal TFTP operation 
    CURLE_TFTP_UNKNOWNID,          # 72 - Unknown transfer ID 
    CURLE_REMOTE_FILE_EXISTS,      # 73 - File already exists 
    CURLE_TFTP_NOSUCHUSER,         # 74 - No such user 
    CURLE_CONV_FAILED,             # 75 - conversion failed 
    CURLE_OBSOLETE76,              # 76 - NOT IN USE since 7.82.0 
    CURLE_SSL_CACERT_BADFILE,      # 77 - could not load CACERT file, missing
                                   # or wrong format
    CURLE_REMOTE_FILE_NOT_FOUND,   # 78 - remote file not found 
    CURLE_SSH,                     # 79 - error from the SSH layer, somewhat
                                   # generic so the error message will be of
                                   # interest when this has happened

    CURLE_SSL_SHUTDOWN_FAILED,     # 80 - Failed to shut down the SSL
                                   # connection
    CURLE_AGAIN,                   # 81 - socket is not ready for send/recv,
                                   # wait till it's ready and try again (Added
                                   # in 7.18.2)
    CURLE_SSL_CRL_BADFILE,         # 82 - could not load CRL file, missing or
                                   # wrong format (Added in 7.19.0)
    CURLE_SSL_ISSUER_ERROR,        # 83 - Issuer check failed.  (Added in
                                   # 7.19.0)
    CURLE_FTP_PRET_FAILED,         # 84 - a PRET command failed 
    CURLE_RTSP_CSEQ_ERROR,         # 85 - mismatch of RTSP CSeq numbers 
    CURLE_RTSP_SESSION_ERROR,      # 86 - mismatch of RTSP Session Ids 
    CURLE_FTP_BAD_FILE_LIST,       # 87 - unable to parse FTP file list 
    CURLE_CHUNK_FAILED,            # 88 - chunk callback reported error 
    CURLE_NO_CONNECTION_AVAILABLE, # 89 - No connection available, the
                                   # session will be queued
    CURLE_SSL_PINNEDPUBKEYNOTMATCH, # 90 - specified pinned public key did not
                                   #  match
    CURLE_SSL_INVALIDCERTSTATUS,   # 91 - invalid certificate status 
    CURLE_HTTP2_STREAM,            # 92 - stream error in HTTP/2 framing layer
    CURLE_RECURSIVE_API_CALL,      # 93 - an api function was called from
                                   # inside a callback
    CURLE_AUTH_ERROR,              # 94 - an authentication function returned an
                                   # error
    CURLE_HTTP3,                   # 95 - An HTTP/3 layer problem 
    CURLE_QUIC_CONNECT_ERROR,      # 96 - QUIC connection error 
    CURLE_PROXY,                   # 97 - proxy handshake error 
    CURLE_SSL_CLIENTCERT,          # 98 - client-side certificate required 
    CURLE_UNRECOVERABLE_POLL,      # 99 - poll/select returned fatal error 
    CURL_LAST # never use! 

proc curl_global_init*(flags: clong): CURLcode {.importc: "curl_global_init".}
proc curl_global_cleanup*() {.importc: "curl_global_cleanup".}

proc curl_easy_init*(): CURL {.importc: "curl_easy_init".}
proc curl_easy_cleanup*(handle: CURL) {.importc: "curl_easy_cleanup".}
proc curl_easy_setopt*(handle: CURL, option: CURLoption) {.importc: "curl_easy_setopt", varargs.}
proc curl_easy_perform*(handle: CURL): CURLcode {.importc: "curl_easy_perform".}

proc curl_mime_init*(handle: CURL): curl_mime {.importc: "curl_mime_init".}
proc curl_mime_free*(mime: curl_mime) {.importc: "curl_mime_free".}
proc curl_mime_addpart*(mime: curl_mime): curl_mimepart {.importc: "curl_mime_addpart".}
proc curl_mime_name*(part: curl_mimepart, name: cstring) {.importc: "curl_mime_name".}
proc curl_mime_data*(part: curl_mimepart, data: cstring, datasize: csize_t) {.importc: "curl_mime_name".}
proc curl_mime_filename*(part: curl_mimepart, name: cstring) {.importc: "curl_mime_filename".}
proc curl_mime_filedata*(part: curl_mimepart, filename: cstring) {.importc: "curl_mime_filedata".}

proc curl_slist_append*(slist: curl_slist, str: cstring): curl_slist {.importc: "curl_slist_append".}
proc curl_slist_free_all*(slist: curl_slist) {.importc: "curl_slist_free_all".}

{.pop.}
