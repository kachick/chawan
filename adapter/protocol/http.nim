import std/envvars
import std/strutils

import curlerrors
import curlwrap

import bindings/curl
import utils/twtstr

type
  EarlyHintState = enum
    NO_EARLY_HINT, EARLY_HINT_STARTED, EARLY_HINT_DONE

  HttpHandle = ref object
    curl: CURL
    statusline: bool
    connectreport: bool
    earlyhint: EarlyHintState
    slist: curl_slist

proc curlWriteHeader(p: cstring, size, nitems: csize_t, userdata: pointer):
    csize_t {.cdecl.} =
  var line = newString(nitems)
  if nitems > 0:
    prepareMutation(line)
    copyMem(addr line[0], p, nitems)

  let op = cast[HttpHandle](userdata)
  if not op.statusline:
    op.statusline = true
    var status: clong
    op.curl.getinfo(CURLINFO_RESPONSE_CODE, addr status)
    if status == 103 and op.earlyhint == NO_EARLY_HINT:
      op.earlyhint = EARLY_HINT_STARTED
    else:
      op.connectreport = true
      stdout.write("Status: " & $status & "\n")
      stdout.write("Cha-Control: ControlDone\n")
    return nitems

  if line == "":
    # empty line (last, before body)
    if op.earlyhint == EARLY_HINT_STARTED:
      # ignore; we do not have a way to stream headers yet.
      op.earlyhint = EARLY_HINT_DONE
      # reset statusline; we are awaiting the next line.
      op.statusline = false
      return nitems
    return nitems

  if op.earlyhint != EARLY_HINT_STARTED:
    # Regrettably, we can only write early hint headers after the status
    # code is already known.
    # For now, it seems easiest to just ignore them all.
    stdout.write(line)
  return nitems

# From the documentation: size is always 1.
proc curlWriteBody(p: cstring, size, nmemb: csize_t, userdata: pointer):
    csize_t {.cdecl.} =
  return csize_t(stdout.writeBuffer(p, int(nmemb)))

# From the documentation: size is always 1.
proc readFromStdin(buffer: cstring, size, nitems: csize_t, userdata: pointer):
    csize_t {.cdecl.} =
  return csize_t(stdin.readBuffer(buffer, nitems))

proc curlPreRequest(clientp: pointer, conn_primary_ip, conn_local_ip: cstring,
    conn_primary_port, conn_local_port: cint): cint {.cdecl.} =
  let op = cast[HttpHandle](clientp)
  op.connectreport = true
  stdout.write("Cha-Control: Connected\n")
  return 0 # ok

proc main() =
  let curl = curl_easy_init()
  doAssert curl != nil
  let url = curl_url()
  const flags = cuint(CURLU_PATH_AS_IS)
  url.set(CURLUPART_SCHEME, getEnv("MAPPED_URI_SCHEME"), flags)
  let username = getEnv("MAPPED_URI_USERNAME")
  if username != "":
    url.set(CURLUPART_USER, username, flags)
  let password = getEnv("MAPPED_URI_PASSWORD")
  if password != "":
    url.set(CURLUPART_PASSWORD, password, flags)
  url.set(CURLUPART_HOST, getEnv("MAPPED_URI_HOST"), flags)
  let port = getEnv("MAPPED_URI_PORT")
  if port != "":
    url.set(CURLUPART_PORT, port, flags)
  let path = getEnv("MAPPED_URI_PATH")
  if path != "":
    url.set(CURLUPART_PATH, path, flags)
  let query = getEnv("MAPPED_URI_QUERY")
  if query != "":
    url.set(CURLUPART_QUERY, query, flags)
  curl.setopt(CURLOPT_CURLU, url)
  let op = HttpHandle(curl: curl)
  curl.setopt(CURLOPT_WRITEFUNCTION, curlWriteBody)
  curl.setopt(CURLOPT_HEADERDATA, op)
  curl.setopt(CURLOPT_HEADERFUNCTION, curlWriteHeader)
  curl.setopt(CURLOPT_PREREQDATA, op)
  curl.setopt(CURLOPT_PREREQFUNCTION, curlPreRequest)
  let proxy = getEnv("ALL_PROXY")
  if proxy != "":
    curl.setopt(CURLOPT_PROXY, proxy)
  case getEnv("REQUEST_METHOD")
  of "GET":
    curl.setopt(CURLOPT_HTTPGET, 1)
  of "POST":
    curl.setopt(CURLOPT_POST, 1)
    let len = parseInt(getEnv("CONTENT_LENGTH"))
    # > For any given platform/compiler curl_off_t must be typedef'ed to
    # a 64-bit
    # > wide signed integral data type. The width of this data type must remain
    # > constant and independent of any possible large file support settings.
    # >
    # > As an exception to the above, curl_off_t shall be typedef'ed to
    # a 32-bit
    # > wide signed integral data type if there is no 64-bit type.
    # It seems safe to assume that if the platform has no uint64 then Nim won't
    # compile either. In return, we are allowed to post >2G of data.
    curl.setopt(CURLOPT_POSTFIELDSIZE_LARGE, uint64(len))
    curl.setopt(CURLOPT_READFUNCTION, readFromStdin)
  else: discard #TODO
  let headers = getEnv("REQUEST_HEADERS")
  for line in headers.split("\r\n"):
    if line.startsWithNoCase("Accept-Encoding: "):
      let s = line.after(' ')
      # From the CURLOPT_ACCEPT_ENCODING manpage:
      # > The application does not have to keep the string around after
      # > setting this option.
      curl.setopt(CURLOPT_ACCEPT_ENCODING, cstring(s))
    # This is OK, because curl_slist_append strdup's line.
    op.slist = curl_slist_append(op.slist, cstring(line))
  if op.slist != nil:
    curl.setopt(CURLOPT_HTTPHEADER, op.slist)
  let res = curl_easy_perform(curl)
  if res != CURLE_OK and not op.connectreport:
    stdout.write(getCurlConnectionError(res))
    op.connectreport = true
  curl_easy_cleanup(curl)

main()
