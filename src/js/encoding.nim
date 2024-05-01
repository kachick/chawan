import bindings/quickjs
import js/error
import js/javascript
import js/jstypes

import chagashi/charset
import chagashi/decoder
import chagashi/decodercore
import chagashi/validator
import chagashi/validatorcore

type
  JSTextEncoder = ref object

  JSTextDecoder = ref object
    encoding: Charset
    ignoreBOM {.jsget.}: bool
    fatal {.jsget.}: bool
    doNotFlush: bool
    bomSeen: bool
    td: TextDecoder
    tv: ref TextValidatorUTF8
    validateBuf: seq[uint8]

jsDestructor(JSTextDecoder)
jsDestructor(JSTextEncoder)

type TextDecoderOptions = object of JSDict
  fatal: bool
  ignoreBOM: bool

func newJSTextDecoder(label = "utf-8", options = TextDecoderOptions()):
    JSResult[JSTextDecoder] {.jsctor.} =
  let encoding = getCharset(label)
  if encoding in {CHARSET_UNKNOWN, CHARSET_REPLACEMENT}:
    return err(newRangeError("Invalid encoding label"))
  return ok(JSTextDecoder(
    ignoreBOM: options.ignoreBOM,
    fatal: options.fatal,
    td: if encoding != CHARSET_UTF_8: newTextDecoder(encoding) else: nil,
    tv: if encoding == CHARSET_UTF_8: (ref TextValidatorUTF8)() else: nil,
    encoding: encoding
  ))

type Growbuf = object
  p: ptr UncheckedArray[uint8]
  cap: int
  len: int

{.warning[Deprecated]: off.}:
  proc `=destroy`(growbuf: var Growbuf) =
    if growbuf.p != nil:
      dealloc(growbuf.p)
      growbuf.p = nil

const BufferSize = 128
proc grow(buf: var Growbuf) =
  if buf.cap == 0:
    buf.cap = BufferSize
  else:
    buf.cap *= 2
  buf.p = cast[ptr UncheckedArray[uint8]](buf.p.realloc(buf.cap))

proc write(buf: var Growbuf; s: openArray[uint8]) =
  if buf.len + s.len > buf.cap:
    buf.grow()
  if s.len > 0:
    copyMem(addr buf.p[buf.len], unsafeAddr s[0], s.len)
  buf.len += s.len

proc write(buf: var Growbuf; s: string) =
  if buf.len + s.len > buf.cap:
    buf.grow()
  if s.len > 0:
    copyMem(addr buf.p[buf.len], unsafeAddr s[0], s.len)
  buf.len += s.len

proc decode0(this: JSTextDecoder; ctx: JSContext; input: JSArrayBufferView;
    stream: bool): JSResult[JSValue] =
  var oq = Growbuf(
    p: cast[ptr UncheckedArray[uint8]](alloc(BufferSize)),
    len: 0,
    cap: BufferSize
  )
  var i = 0
  let H = int(input.abuf.len) - 1
  template handle_error =
    if this.fatal:
      return errTypeError("Failed to decode string")
    oq.write("\uFFFD")
    i = this.td.i
  while true:
    case this.td.decode(input.abuf.p.toOpenArray(i, H),
      oq.p.toOpenArray(0, oq.cap - 1), oq.len)
    of tdrDone:
      if not stream:
        case this.td.finish()
        of tdfrDone: discard
        of tdfrError: handle_error
      break
    of tdrError:
      handle_error
    of tdrReqOutput:
      oq.grow()
  return ok(JS_NewStringLen(ctx, cast[cstring](oq.p), csize_t(oq.len)))

proc validate0(this: JSTextDecoder; ctx: JSContext; input: JSArrayBufferView;
    stream: bool): JSResult[JSValue] =
  # assume input is valid; do not allocate yet
  var oq = Growbuf(p: nil, len: 0, cap: 0)
  var i = 0
  let H = int(input.abuf.len) - 1
  var n = 0
  template handle_error =
    if this.fatal:
      return errTypeError("Failed to decode string")
    # write from previous error (or beginning) to the last valid char
    oq.write(input.abuf.p.toOpenArray(i, n))
    oq.write("\uFFFD")
    this.validateBuf.setLen(0)
    i = this.tv.i
  while true:
    case this.tv[].validate(input.abuf.p.toOpenArray(i, H), n)
    of tvrDone:
      break
    of tvrError:
      handle_error
  if not stream:
    case this.tv[].finish()
    of tvrDone: discard
    of tvrError: handle_error
  if this.validateBuf.len > 0 and n > -1:
    oq.write(this.validateBuf)
    oq.write(input.abuf.p.toOpenArray(i, n))
    this.validateBuf.setLen(0)
  this.validateBuf.add(input.abuf.p.toOpenArray(n + 1, input.abuf.high))
  if oq.len > 0:
    assert oq.p != nil
    return ok(JS_NewStringLen(ctx, cast[cstring](oq.p), csize_t(oq.len)))
  assert oq.p == nil
  return ok(JS_NewStringLen(ctx, cast[cstring](input.abuf.p), csize_t(n + 1)))

type TextDecodeOptions = object of JSDict
  stream: bool

#TODO AllowSharedBufferSource
proc decode(ctx: JSContext; this: JSTextDecoder;
    input = none(JSArrayBufferView); options = TextDecodeOptions()):
    JSResult[JSValue] {.jsfunc.} =
  if not this.doNotFlush:
    if this.td != nil:
      this.td = newTextDecoder(this.encoding)
    else:
      assert this.tv != nil
      this.tv = (ref TextValidatorUTF8)()
    this.bomSeen = false
  if this.doNotFlush != options.stream:
    this.doNotFlush = options.stream
  if input.isSome:
    if this.td != nil:
      return this.decode0(ctx, input.get, options.stream)
    else:
      assert this.encoding == CHARSET_UTF_8
      # just validate
      return this.validate0(ctx, input.get, options.stream)
  return ok(JS_NewString(ctx, ""))

func jencoding(this: JSTextDecoder): string {.jsfget: "encoding".} =
  return $this.encoding

func newTextEncoder(): JSTextEncoder {.jsctor.} =
  return JSTextEncoder()

func jencoding(this: JSTextEncoder): string {.jsfget: "encoding".} =
  return "utf-8"

proc dealloc_wrap(rt: JSRuntime; opaque, p: pointer) {.cdecl.} =
  dealloc(p)

proc encode(this: JSTextEncoder; input = ""): JSUint8Array {.jsfunc.} =
  # we have to validate input first :/
  #TODO it is possible to do less copies here...
  var input = input.toValidUTF8()
  let buf = cast[ptr UncheckedArray[uint8]](alloc(input.len))
  copyMem(buf, addr input[0], input.len)
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
  ctx.registerType(JSTextDecoder, name = "TextDecoder")
  ctx.registerType(JSTextEncoder, name = "TextEncoder")
