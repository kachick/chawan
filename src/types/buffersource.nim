import std/options

import loader/request
import types/url

import chakasu/charset

type
  BufferSource* = object
    location*: URL
    contentType*: Option[string] # override
    charset*: Charset # fallback
    request*: Request
