import std/streams

import js/arraybuffer
import js/dict
import js/error
import js/javascript

import chakasu/charset
import chakasu/decoderstream
import chakasu/encoderstream

type
  TextEncoder = ref object

  TextDecoder = ref object
    encoding: Charset
    errorMode: DecoderErrorMode
    ignoreBOM {.jsget.}: bool
    doNotFlush: bool
    bomSeen: bool
    decoder: DecoderStream
    encoder: EncoderStream # to return the string to JS
    istream: StringStream

jsDestructor(TextDecoder)
jsDestructor(TextEncoder)

type TextDecoderOptions = object of JSDict
  fatal: bool
  ignoreBOM: bool

func newTextDecoder(label = "utf-8", options = TextDecoderOptions()):
    JSResult[TextDecoder] {.jsctor.} =
  let errorMode = if options.fatal:
    DECODER_ERROR_MODE_FATAL
  else:
    DECODER_ERROR_MODE_REPLACEMENT
  let encoding = getCharset(label)
  if encoding in {CHARSET_UNKNOWN, CHARSET_REPLACEMENT}:
    return err(newRangeError("Invalid encoding label"))
  return ok(TextDecoder(
    errorMode: errorMode,
    ignoreBOM: options.ignoreBOM,
    encoding: encoding
  ))

type TextDecodeOptions = object of JSDict
  stream: bool

#TODO AllowSharedBufferSource
proc decode(this: TextDecoder, input = none(JSArrayBufferView),
    options = TextDecodeOptions()): string {.jsfunc.} =
  if not this.doNotFlush:
    if this.istream != nil:
      this.istream.close()
    if this.decoder != nil:
      this.decoder.close()
    if this.encoder != nil:
      this.encoder.close()
    this.istream = newStringStream()
    this.decoder = newDecoderStream(this.istream, cs = this.encoding,
      errormode = this.errorMode)
    this.encoder = newEncoderStream(this.decoder, cs = CHARSET_UTF_8)
    this.bomSeen = false
  if this.doNotFlush != options.stream:
    this.doNotFlush = options.stream
    this.decoder.setInhibitCheckEnd(options.stream)
  if input.isSome:
    let input = input.get
    let pos = this.istream.getPosition()
    #TODO input offset?
    this.istream.writeData(input.abuf.p, int(input.abuf.len))
    this.istream.setPosition(pos)
  #TODO this should return a JSString, so we do not needlessly re-encode
  # the output. (Right now we do, implicitly through toJS.)
  return this.encoder.readAll()

func jencoding(this: TextDecoder): string {.jsfget: "encoding".} =
  return $this.encoding

func fatal(this: TextDecoder): bool {.jsfget.} =
  return this.errorMode == DECODER_ERROR_MODE_FATAL

func newTextEncoder(): TextEncoder {.jsctor.} =
  return TextEncoder()

func jencoding(this: TextEncoder): string {.jsfget: "encoding".} =
  return "utf-8"

proc dealloc_wrap(rt: JSRuntime, opaque, p: pointer) {.cdecl.} =
  dealloc(p)

proc encode(this: TextEncoder, input = ""): JSUint8Array {.jsfunc.} =
  # input is already UTF-8 here :P
  let buf = cast[ptr UncheckedArray[uint8]](alloc(input.len))
  copyMem(buf, unsafeAddr input[0], input.len)
  let abuf = JSArrayBuffer(
    p: buf,
    len: csize_t(input.len),
    dealloc: dealloc_wrap
  )
  return JSUint8Array(
    abuf: abuf,
    offset: 0,
    nmemb: csize_t(input.len)
  )

#TODO encodeInto

proc addEncodingModule*(ctx: JSContext) =
  ctx.registerType(TextDecoder)
  ctx.registerType(TextEncoder)
