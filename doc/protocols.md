<!-- MANON
% cha-protocols(5) | Protocol support in Chawan
MANOFF -->

# Protocols

Chawan supports downloading resources from various protocols: HTTP, FTP,
Gopher, Gemini, and Finger. Details on these protocols, and information
on how users can add support to their preferred protocols is outlined in
this document.

<!-- MANOFF -->
**Table of contents**

* [HTTP](#http)
* [FTP](#ftp)
* [Gopher](#gopher)
* [Gemini](#gemini)
* [Finger](#finger)
* [Local schemes: file:, about:, data:-](#local-schemes-file-about-data)
* [Custom protocols](#custom-protocols)

<!-- MANON -->

## HTTP

HTTP/s support is based on libcurl; supported features largely depend on
your libcurl version. The adapter is found at `adapter/protocol/http.nim`.

The libcurl HTTP adapter can take arbitrary headers and POST data, is able
to use passed userinfo data (`https://username:password@example.org`), and
returns all headers and response body it receives from libcurl without
exception.

It is possible to build these adapters using
[curl-impersonate](https://github.com/lwthiker/curl-impersonate) by setting
the compile-time variable CURLLIBNAME to `libcurl-impersonate.so`. Note that
for curl-impersonate to work, you must set `network.default-headers = {}`
in the Chawan config. (Otherwise, the libcurl adapter will happily override
curl-impersonate headers, which is probably not what you want.)

The `bonus/libfetch` directory contains an alternative HTTP client, which is
based on FreeBSD libfetch. It is mostly a proof of concept, as FreeBSD
libfetch HTTP support is very limited; in particular, it does not support
HTTP headers (beyond some basic request headers), so e.g. cookies will
not work.

## FTP

Chawan supports FTP through the `adapter/protocol/ftp.nim` libcurl adapter. For
directory listings, it assumes UNIX output style, and will probably break
horribly on receiving anything else. Otherwise, the directory listing view
is identical to (and uses the same code path as) the file:// directory listing.

In theory, SFTP and FTPS should be supported as well. In practice, SFTP does
not really work yet because there is no way to specify private keys, and I
have never seen an FTPS server in the wild so I assume it is broken too.

## Gopher

Gopher is supported through the `adapter/protocol/gopher.nim` libcurl
adapter. Gopher directories are passed as the `text/gopher` type, and
`adapter/format/gopher.nim` takes care of converting this to HTML.

Gopher selector types are converted to MIME types when possible; note however,
that this is very limited, as most of them (like `s` sound, or `I` image)
cannot be unambiguously converted without some other sniffing method. Chawan
will fall back to extension-based detection in these cases, and in the worst
case may end up with `application/octet-stream`.

## Gemini

Chawan's gemini adapter (in `adapter/protocol/gmifetch.c`) is a C program. It
requires OpenSSL to work.

Note that gmifetch was written as a candidate for the bonus/ directory when
Chawan's local CGI support was still in early stages of development, and
thus has some legacy issues. In particular:

* It takes the URL through `$QUERY_STRING`, and re-parses it for its needs. In
  all likelihood it breaks on IPv6 URLs. Needless to say this is a bad idea
  and should not be imitated.
* Error messages are returned as full documents.
* It does not support proxies.
* It does not support private key authentication.

`adapter/format/gmi2html.nim` is its companion program to convert the
`text/gemini` file format to HTML. Note that the gemtext specification insists
on line breaks being visually significant, and forbids their collapsing onto
a single line; gmi2html respects this. However, inline whitespace is still
collapsed outside of preformatted blocks.

## Finger

Finger is supported through the `adapter/protocol/cha-finger` shell script.
It is implemented as a shell script because of the protocol's simplicity.
cha-finger uses the `curl` program's telnet:// protocol to make requests.
As such, it will not work if `curl` is not installed.

Aspiring protocol adapter writers are encouraged to study cha-finger for
a simple example of how a custom protocol handler could be written.

## Local schemes: file:, about:, data:, cgi-bin:

While these are not necessarily *protocols*, they are implemented similarly
to the protocols listed above (and thus can also be replaced, if the user
wishes; see below).

`file:` loads a file from the local filesystem. In case of directories, it
shows the directory listing like the FTP protocol does.

`about:` contains informational pages about the browser. At the time of
writing, the following pages are available: `about:chawan`, `about:blank`
and `about:license`.

`data:` decodes a data URL as defined in RFC 2397.

Finally, `cgi-bin:` executes a local CGI script. This scheme is used for
the actual implementations of all supported protocols and can *not*
be replaced.

## Custom protocols

Chawan itself is protocol-agnostic. This means that the `cha` binary itself
does not know much about the protocols listed above; instead, it loads
these through a combination of local CGI, urimethodmap, and if conversion
to HTML or plain text is necessary, mailcap (using x-htmloutput and
copiousoutput).

urimethodmap can also be used to override default handlers for the protocols
listed above. This is similar to how w3m allows you to override the default
directory listing display, but much more powerful; this way, any library
or program that can retrieve and output text through a certain protocol can
be combined with Chawan.

For example, consider the urimethodmap definition of cha-finger:

```
finger:		cgi-bin:cha-finger
```

This commands Chawan to load the cha-finger CGI script, setting the
`$MAPPED_URI_*` variables to the target URL's parts in the process.

Then, cha-finger uses these passed parts to construct an appropriate curl
command that will retrieve the specified `finger:` URL; it prints the header
'Content-Type: text/plain' to the output, then an empty line, then the body
of the retrieved resource. If an error is encountered, it prints a
`Cha-Control` header with an error code and a specific error message instead.
<!-- MANON

## See also

**cha**(1), **cha-urimethodmap**(5), **cha-localcgi**(5),
**cha-urimethodmap**(5)
MANOFF -->
