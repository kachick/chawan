import std/macros

const seccomp = (proc(): string =
  let res = staticExec("pkg-config --libs --silence-errors libseccomp")
  if res == "":
    error("Couldn't find libseccomp on your computer!  Please install " &
      "libseccomp (e.g. apt install libseccomp-dev), or build with " &
      "`make CHA_DANGER_DISABLE_SANDBOX=1'.")
  return res
)()

type
  scmp_filter_ctx* = distinct pointer

  scmp_datum_t* = uint64

  scmp_compare* {.size: sizeof(cint).} = enum
    N_SCMP_CMP_MIN = 0
    SCMP_CMP_NE = 1 # not equal
    SCMP_CMP_LT = 2 # less than
    SCMP_CMP_LE = 3 # less than or equal
    SCMP_CMP_EQ = 4 # equal
    SCMP_CMP_GE = 5 # greater than or equal
    SCMP_CMP_GT = 6 # greater than
    SCMP_CMP_MASKED_EQ = 7 # masked equality

  scmp_arg_cmp* = object
    arg*: cuint
    op*: scmp_compare
    datum_a*: scmp_datum_t
    datum_b*: scmp_datum_t

{.push importc.}
{.passl: seccomp.}

const SCMP_ACT_KILL_PROCESS* = 0x80000000u32
const SCMP_ACT_ALLOW* = 0x7FFF0000u32
const SCMP_ACT_TRAP* = 0x00030000u32

template SCMP_ACT_ERRNO*(x: uint16): uint32 =
  0x50000u32 or x

proc seccomp_init*(def_action: uint32): scmp_filter_ctx
proc seccomp_reset*(ctx: scmp_filter_ctx; def_action: uint32): cint
proc seccomp_syscall_resolve_name*(name: cstring): cint
proc seccomp_syscall_resolve_name_rewrite*(name: cstring): cint
proc seccomp_rule_add*(ctx: scmp_filter_ctx; action: uint32; syscall: cint;
  arg_cnt: cuint): cint {.varargs.}
proc seccomp_load*(ctx: scmp_filter_ctx): cint
proc seccomp_release*(ctx: scmp_filter_ctx)

{.pop.}
