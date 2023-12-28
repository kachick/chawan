when defined(gcc) or defined(llvm_gcc) or defined(clang):
  const useBuiltinSwap = true
  proc builtin_bswap32(a: uint32): uint32 {.
      importc: "__builtin_bswap32", nodecl, noSideEffect.}
elif defined(icc):
  const useBuiltinSwap = true
  proc builtin_bswap32(a: uint32): uint32 {.
      importc: "_bswap", nodecl, noSideEffect.}
elif defined(vcc):
  const useBuiltinSwap = true
  proc builtin_bswap32(a: uint32): uint32 {.
      importc: "_byteswap_ulong", nodecl, header: "<intrin.h>", noSideEffect.}
else:
  const useBuiltinSwap = false

when useBuiltinSwap:
  proc swap(u: uint32): uint32 {.inline.} =
    return builtin_bswap32(u)
else:
  proc swap(u: uint32): uint32 {.inline.} =
    return ((u and 0xFF000000) shr 24) or
      ((u and 0x00FF0000) shr 8) or
      ((u and 0x0000FF00) shl 8) or
      (u shl 24)

proc fromBytesBEu32*(x: openArray[uint8]): uint32 {.inline.} =
  var u {.noinit.}: uint32
  copyMem(addr u, unsafeAddr x[0], sizeof(uint32))
  when system.cpuEndian == littleEndian:
    return swap(u)
  else:
    return u

proc toBytesBE*(u: uint32): array[sizeof(uint32), uint8] {.inline.} =
  when system.cpuEndian == littleEndian:
    var u = swap(u)
    copyMem(addr result[0], addr u, sizeof(uint32))
  else:
    copyMem(addr result[0], unsafeAddr u, sizeof(uint32))
