#TODO....

type
  UnderlyingSourceStartCallback = proc(controller: ReadableStreamController):
    Option[JSValue] # may be undefined!
  UnderlyingSourcePullCallback = proc(controller: ReadableStreamController):
    EmptyPromise
  UnderlyingSourceCancelCallback = proc(reason = none(JSValue)): EmptyPromise

  ReadableStreamType = enum
    BYOB = "byob"

  UnderlyingSource* = object
    start*: Option[UnderlyingSourceStartCallback]
    pull*: Option[UnderlyingSourcePullCallback]
    cancel*: Option[UnderlyingSourcePullCallback]
    #TODO mark real name being type
    ctype*: Option[ReadableStreamType]

  QueuingStrategySize = proc(chunk: JSValue): float64 # unrestricted

  QueuingStrategy* = object
    highWaterMark*: float64 # unrestricted
    size*: QueuingStrategySize

  ReadableStream* = object
    underlyingSource: UnderlyingSource

proc newReadableStream(underlyingSource = none(UnderlyingSource);
    strategy = none(QueuingStrategySize)): ReadableStream =
  let this = ReadableStream()
  discard
