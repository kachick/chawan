const zlib = (func(): string =
  let res = staticExec("pkg-config --libs --silence-errors zlib")
  if res != "":
    return res
)()
when zlib == "":
  error("zlib not found")

{.passl: zlib.}

const
  Z_NO_FLUSH* = cint(0)
  Z_PARTIAL_FLUSH* = cint(1)
  Z_SYNC_FLUSH* = cint(2)
  Z_FULL_FLUSH* = cint(3)
  Z_FINISH* = cint(4)
  Z_BLOCK* = cint(5)
  Z_TREES* = cint(6)

const
  Z_OK* = cint(0)
  Z_STREAM_END* = cint(1)
  Z_NEED_DICT* = cint(2)
  Z_ERRNO* = cint(-1)
  Z_STREAM_ERROR* = cint(-2)
  Z_DATA_ERROR* = cint(-3)
  Z_MEM_ERROR* = cint(-4)
  Z_BUF_ERROR* = cint(-5)
  Z_VERSION_ERROR* = cint(-6)

const
  Z_BINARY* = cint(0)
  Z_TEXT* = cint(1)
  Z_ASCII* = Z_TEXT
  Z_UNKNOWN* = cint(2)

type
  alloc_func* {.importc, header: "zlib.h".} = proc (opaque: pointer;
    items, size: cuint): pointer {.cdecl.}

  free_func* {.importc, header: "zlib.h".} = proc (opaque, address: pointer)
    {.cdecl.}

  internal_state* {.importc, header: "zlib.h".} = object

  z_stream* {.importc, header: "zlib.h".} = object
    next_in*: ptr uint8 # next input byte
    avail_in*: cuint # number of bytes available in next_in
    total_in*: culong # total number of input bytes read so far

    next_out*: ptr uint8 # next output byte will go here
    avail_out*: cuint # remaining free space at next_out
    total_out*: culong # total number of bytes output so far

    msg*: cstring # last error message, NULL if no error
    state*: ptr internal_state # not visible by applications

    zalloc*: alloc_func # used to allocate the internal state
    zfree*: free_func # used to free the internal state
    opaque*: pointer # private data object passed to zalloc and zfree

    data_type*: cint # best guess about the data type: binary or text
                     # for deflate, or the decoding state for inflate
    adler*: culong # Adler-32 or CRC-32 value of the uncompressed data
    reserved*: culong # reserved for future use

  z_streamp* = ptr z_stream

{.push header: "zlib.h", importc, cdecl.}
proc inflateInit*(strm: z_streamp): cint
proc inflate*(strm: z_streamp, flush: cint): cint
proc inflateEnd*(strm: z_streamp): cint
proc compress*(dest: ptr uint8; destLen: ptr culong; source: ptr uint8;
  sourceLen: culong): cint
proc compressBound*(sourceLen: culong): culong
proc uncompress*(dest: ptr uint8; destLen: ptr culong; source: ptr uint8;
  sourceLen: culong): cint
proc crc32*(crc: culong; buf: ptr uint8; len: cuint): culong
{.pop.}
