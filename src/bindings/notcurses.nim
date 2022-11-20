const notcurseslib = (func(): string =
  when defined(windows): return "libnotcurses-core.dll"
  elif defined(macos): return "libnotcurses-core(|.3|.3.0.8).dylib"
  else: return "libnotcurses-core.so(|.3|.3.0.8)" # assume posix
)()

{.push cdecl, dynlib: notcurseslib.}

const
  NCOPTION_INHIBIT_SETLOCALE* = 0x0001u64
  NCOPTION_NO_CLEAR_BITMAPS* = 0x0002u64
  NCOPTION_NO_WINCH_SIGHANDLER* = 0x0004u64
  NCOPTION_NO_QUIT_SIGHANDLERS* = 0x0008u64
  NCOPTION_PRESERVE_CURSOR* = 0x0010u64
  NCOPTION_SUPPRESS_BANNERS* = 0x0020u64
  NCOPTION_NO_ALTERNATE_SCREEN* = 0x0040u64
  NCOPTION_NO_FONT_CHANGES* = 0x0080u64
  NCOPTION_DRAIN_INPUT* = 0x0100u64
  NCOPTION_SCROLLING* = 0x0200u64

const
  NCDIRECT_OPTION_INHIBIT_SETLOCALE* = 0x0001u64
  NCDIRECT_OPTION_INHIBIT_CBREAK* = 0x0002u64
  NCDIRECT_OPTION_NO_QUIT_SIGHANDLERS* = 0x0008u64
  NCDIRECT_OPTION_VERBOSE* = 0x0010u64
  NCDIRECT_OPTION_VERY_VERBOSE* = 0x0020u64

const NCOPTION_CLI_MODE = NCOPTION_NO_ALTERNATE_SCREEN or
  NCOPTION_NO_CLEAR_BITMAPS or
  NCOPTION_PRESERVE_CURSOR or
  NCOPTION_SCROLLING

type
  ncloglevel_e* {.size: sizeof(cint).} = enum
    NCLOGLEVEL_SILENT  # print nothing once fullscreen service begins
    NCLOGLEVEL_PANIC   # default. print diagnostics before we crash/exit
    NCLOGLEVEL_FATAL   # we're hanging around, but we've had a horrible fault
    NCLOGLEVEL_ERROR   # we can't keep doing this, but we can do other things
    NCLOGLEVEL_WARNING # you probably don't want what's happening to happen
    NCLOGLEVEL_INFO    # "standard information"
    NCLOGLEVEL_VERBOSE # "detailed information"
    NCLOGLEVEL_DEBUG   # this is honestly a bit much
    NCLOGLEVEL_TRACE   # there's probably a better way to do what you want

  notcurses_options_struct* = object
    termtype*: cstring
    loglevel*: ncloglevel_e
    margin_t*: cuint
    margin_r*: cuint
    margin_b*: cuint
    margin_l*: cuint
    flags*: uint64

  notcurses_options* = ptr notcurses_options_struct

  notcurses* = pointer

  ncdirect* = pointer

{.push importc.}

proc ncdirect_core_init*(termtype: cstring, fp: File, flags: uint64): ncdirect
proc ncdirect_stop*(nc: ncdirect): cint

{.pop.}
{.pop.}
