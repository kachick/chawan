const
  LRE_FLAG_GLOBAL* = 1 shl 0
  LRE_FLAG_IGNORECASE* = 1 shl 1
  LRE_FLAG_MULTILINE* = 1 shl 2
  LRE_FLAG_DOTALL* = 1 shl 3
  LRE_FLAG_UTF16* = 1 shl 4
  LRE_FLAG_STICKY* = 1 shl 5

proc lre_compile*(plen: ptr cint, error_msg: cstring, error_msg_size: cint,
                  buf: cstring, buf_len: csize_t, re_flags: cint,
                  opaque: pointer): ptr uint8 {.importc.}

proc lre_exec*(capture: ptr ptr uint8, bc_buf: ptr uint8, cbuf: ptr uint8,
               cindex: cint, clen: cint, cbuf_type: cint,
               opaque: pointer): cint {.importc.}

proc lre_get_capture_count*(bc_buf: ptr uint8): cint {.importc.}

proc lre_get_flags*(bc_buf: ptr uint8): cint {.importc.}
