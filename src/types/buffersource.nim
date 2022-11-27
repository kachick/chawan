import options

when defined(posix):
  import posix

import io/request
import types/url

type
  BufferSourceType* = enum
    CLONE, LOAD_REQUEST, LOAD_PIPE

  BufferSource* = object
    location*: URL
    contenttype*: Option[string] # override
    case t*: BufferSourceType
    of CLONE:
      clonepid*: Pid
    of LOAD_REQUEST:
      request*: Request
    of LOAD_PIPE:
      fd*: FileHandle