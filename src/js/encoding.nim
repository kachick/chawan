import chagashi/charset
import chagashi/decoder
import monoucha/javascript
import monoucha/jserror
import monoucha/jstypes
import monoucha/quickjs
import types/opt

type
  JSTextEncoder = ref object

  JSTextDecoder = ref object
    encoding: Charset
    ignoreBOM {.jsget.}: bool
    errorMode: DecoderErrorMode
    stream: bool
    bomSeen: bool
    tdctx: TextDecoderContext

jsDestructor(JSTextDecoder)
jsDestructor(JSTextEncoder)

type TextDecoderOptions = object of JSDict
  fatal {.jsdefault.}: bool
  ignoreBOM {.jsdefault.}: bool

func newJSTextDecoder(label = "utf-8"; options = TextDecoderOptions()):
    JSResult[JSTextDecoder] {.jsctor.} =
  let encoding = getCharset(label)
  if encoding in {CHARSET_UNKNOWN, CHARSET_REPLACEMENT}:
    return errRangeError("Invalid encoding label")
  let errorMode = if options.fatal: demFatal else: demReplacement
  return ok(JSTextDecoder(
    ignoreBOM: options.ignoreBOM,
    errorMode: errorMode,
    tdctx: initTextDecoderContext(encoding, errorMode),
    encoding: encoding
  ))

func fatal(this: JSTextDecoder): bool {.jsfget.} =
  return this.errorMode == demFatal

proc decode0(this: JSTextDecoder; ctx: JSContext; input: JSArrayBufferView;
    stream: bool): JSResult[JSValue] =
  let H = int(input.abuf.len) - 1
  var oq = ""
  for chunk in this.tdctx.decode(input.abuf.p.toOpenArray(0, H), not stream):
    oq &= chunk
  if this.tdctx.failed:
    this.tdctx.failed = false
    return errTypeError("Failed to decode string")
  return ok(JS_NewStringLen(ctx, cstring(oq), csize_t(oq.len)))

type TextDecodeOptions = object of JSDict
  stream {.jsdefault.}: bool

#TODO AllowSharedBufferSource
proc decode(ctx: JSContext; this: JSTextDecoder;
    input = none(JSArrayBufferView); options = TextDecodeOptions()):
    JSResult[JSValue] {.jsfunc.} =
  if not this.stream:
    this.tdctx = initTextDecoderContext(this.encoding, this.errorMode)
    this.bomSeen = false
  this.stream = options.stream
  if input.isSome:
    return this.decode0(ctx, input.get, options.stream)
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
