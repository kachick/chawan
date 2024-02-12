import std/options

import loader/request

import chakasu/charset

type
  BufferSource* = object
    contentType*: Option[string] # override
    charset*: Charset # fallback
    request*: Request
