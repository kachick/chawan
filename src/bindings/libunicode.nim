type
  DynBufReallocFunc = proc(opaque: pointer, p: pointer, size: csize_t): pointer {.cdecl.}

  CharRange* = object
    len*: cint # in points, always even
    size*: cint
    points*: ptr uint32 # points sorted by increasing value
    mem_opaque*: pointer
    realloc_func*: DynBufReallocFunc

  UnicodeNormalizationEnum* {.size: sizeof(cint).} = enum
    UNICODE_NFC, UNICODE_NFD, UNICODE_NKFC, UNICODE_NKFD

{.passc: "-Ilib/".}

{.push header: "quickjs/libunicode.h", importc.}

proc cr_init*(cr: ptr CharRange, mem_opaque: pointer,
              realloc_func: DynBufReallocFunc) {.importc.}

proc cr_free*(cr: ptr CharRange) {.importc.}

proc unicode_normalize*(pdst: ptr ptr uint32, src: ptr uint32, src_len: cint,
                        n_type: UnicodeNormalizationEnum, opaque: pointer,
                        realloc_func: DynBufReallocFunc): cint {.importc.}

proc unicode_general_category*(cr: ptr CharRange, gc_name: cstring): cint {.importc.}
{.pop.}
