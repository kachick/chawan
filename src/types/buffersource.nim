import std/options

when defined(posix):
  import std/posix

import loader/request
import types/url

import chakasu/charset

type
  BufferSourceType* = enum
    CLONE, LOAD_REQUEST

  BufferSource* = object
    location*: URL
    contentType*: Option[string] # override
    charset*: Charset # fallback
    case t*: BufferSourceType
    of CLONE:
      clonepid*: Pid
    of LOAD_REQUEST:
      request*: Request
