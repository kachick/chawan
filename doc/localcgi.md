<!-- MANON
% cha-localcgi(5) | Local CGI support in Chawan
MANOFF -->

# Local CGI support in Chawan

Chawan supports the invocation of CGI scripts locally. This feature can be
used in the following way:

* All local CGI scripts must be placed in a directory specified in
  `external.cgi-dir`. Multiple directories can be specified in an array too,
  and directories specified first have higher precedence.
* Then, a CGI script in one of these directories can be executed by visiting
  the URL `cgi-bin:script-name`. $PATH_INFO and $QUERY_STRING are set as
  normal, i.e. `cgi-bin:script-name/abcd?defgh=ijkl` will set $PATH_INFO to
  `/abcd`, and $QUERY_STRING to `defgh=ijkl`.

Further notes on processing CGI paths:

* The URL must be opaque, so you must not add a double slash after the scheme.
  e.g. `cgi-bin://script-name` will NOT work, only `cgi-bin:script-name`.
* Paths beginning with `/cgi-bin/` or `/$LIB/` are stripped of this segment
  automatically. So e.g. `file:///cgi-bin/script-name` becomes
  `cgi-bin:script-name`.
* If `extern.w3m-cgi-compat` is true, file: URLs are converted to cgi-bin: URLs
  if the path name starts with `/cgi-bin/`, `/$LIB/`, or the path of a local
  CGI script.
* Absolute paths are accepted as e.g. `cgi-bin:/path/to/cgi/dir/script-name`.
  Note however, that this only works if `/path/to/cgi/dir` has already been
  specified as a CGI directory in `external.cgi-dir`.

Note that this is different from w3m's cgi-bin functionality, in that we
use a custom scheme for local CGI instead of interpreting all requests to
a designated path as a CGI request. (This incompatibility is bridged over when
`external.cgi-dir` is true.)

Also, for now Chawan has no equivalent to the W3m-control headers (but this
may change in the future).

## Environment variables

Chawan sets the following environment variables:

* `SERVER_SOFTWARE="Chawan"`
* `SERVER_PROTOCOL="HTTP/1.0"`
* `SERVER_NAME="localhost"`
* `SERVER_PORT="80"`
* `REMOTE_HOST="localhost"`
* `REMOTE_ADDR="127.0.0.1"`
* `GATEWAY_INTERFACE="CGI/1.1"`
* `SCRIPT_NAME="/cgi-bin/script-name"` if called with a relative path, and
  `"/path/to/script/script-name"` if called with an absolute path.
* `SCRIPT_FILENAME="/path/to/script/script-name"`
* `QUERY_STRING=` the query string (i.e. `URL.search`). Note that this
  variable is percent-encoded.
* `PATH_INFO=` everything after the script's path name,
  e.g. for `cgi-bin:script-name/abcd/efgh` `"/abcd/efgh"`. Note that this
  variable is NOT percent-encoded.
* `REQUEST_URI="$SCRIPT_NAME/$PATH_INFO?$QUERY_STRING`
* `REQUEST_METHOD=` HTTP method used for making the request, e.g. GET or POST
* `CONTENT_TYPE=` for POST requests, the Content-Type header. Not set for
  other request types (e.g. GET).
* `CONTENT_LENGTH=` the content length, if $CONTENT_TYPE has been set.
* `HTTP_PROXY=` and (lower case) `http_proxy=`: the proxy URL if a proxy
  has been set and its scheme is either `http` or `https`.
* `ALL_PROXY=` if a proxy has been set, the proxy URL.
* `HTTP_COOKIE=` if set, the Cookie header.
* `HTTP_REFERER=` if set, the Referer header.

## Request body

If the request body is not empty, it is streamed into the program through
the standard input.

NOTE: multipart requests are not implemented yet. This will be fixed in
the future.

## Troubleshooting

Note that standard error is redirected to the browser console (by default,
M-cM-c). This makes it easy to debug a misbehaving CGI script, but may also
slow down the browser in case of excessive logging. If this is not the
desired behavior, we recommend wrapping your script into a shell script that
redirects stderr to /dev/null.

### My script is returning a "no local-CGI directory configured" error message.

Configure a local-CGI directory using `external.cgi-dir`.

e.g. you could add this to your config.toml:

```toml
[external]
cgi-dir = "/usr/local/libexec/chawan/cgi-bin"
```

and then put your script in `/usr/local/libexec/chawan/cgi-bin`.

### My script is returning an "invalid CGI path" error message.

Make sure that you did not include leading slashes. Reminder:
`cgi-bin://script-name` does not work, use `cgi-bin:script-name`.

### My script is returning a "CGI file not found" error message.

Double check that your CGI script is in the correct location. Also, make
sure that you are not accidentally calling the script with an absolute path via
`cgi-bin:/script-name` (instead of the correct `cgi-bin:script-name`).

Also, make sure `external.cgi-dir` is set to the directory your script is in.

### My script returns a page saying "Failed to execute script".

This means the `execl` call to the script failed. Make sure that your CGI
script's executable bit is set, i.e. run `chmod +x /path/to/cgi/script`.

### My script is returning a "failed to set up CGI script" error message.

This means that either `pipe` or `fork` failed. Something strange is going on
with your system; we recommend exorcism. (Maybe you are running out of memory?)

<!-- MANON
## See also

**cha**(1)
MANOFF -->
