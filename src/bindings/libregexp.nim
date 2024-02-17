type
  LREFlag* {.size: sizeof(cint).} = enum
    LRE_FLAG_GLOBAL = "g"
    LRE_FLAG_IGNORECASE = "i"
    LRE_FLAG_MULTILINE = "m"
    LRE_FLAG_DOTALL = "s"
    LRE_FLAG_UTF16 = "u"
    LRE_FLAG_STICKY = "y"

  LREFlags* = set[LREFlag]

func toCInt*(flags: LREFlags): cint =
  cast[cint](flags)

func toLREFlags*(flags: cint): LREFlags =
  cast[LREFlags](flags)

{.passc: "-Ilib/".}

{.push header: "quickjs/libregexp.h", importc.}
proc lre_compile*(plen: ptr cint, error_msg: cstring, error_msg_size: cint,
  buf: cstring, buf_len: csize_t, re_flags: cint, opaque: pointer): ptr uint8

proc lre_exec*(capture: ptr ptr uint8, bc_buf: ptr uint8, cbuf: ptr uint8,
  cindex: cint, clen: cint, cbuf_type: cint, opaque: pointer): cint

proc lre_get_capture_count*(bc_buf: ptr uint8): cint

proc lre_get_flags*(bc_buf: ptr uint8): cint
{.pop.}
