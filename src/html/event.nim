import std/math
import std/options
import std/times

import bindings/quickjs
import js/error
import js/fromjs
import js/javascript
import js/jstypes
import js/tojs
import types/opt

type
  EventPhase = enum
    NONE = 0u16
    CAPTURING_PHASE = 1u16
    AT_TARGET = 2u16
    BUBBLING_PHASE = 3u16

  EventFlag* = enum
    efStopPropagation
    efStopImmediatePropagation
    efCanceled
    efInPassiveListener
    efComposed
    efInitialized
    efDispatch

  Event* = ref object of RootObj
    ctype {.jsget: "type".}: string
    target* {.jsget.}: EventTarget
    currentTarget* {.jsget.}: EventTarget
    eventPhase {.jsget.}: uint16
    bubbles {.jsget.}: bool
    cancelable {.jsget.}: bool
    #TODO DOMHighResTimeStamp?
    timeStamp {.jsget.}: float64
    flags*: set[EventFlag]
    isTrusted {.jsufget.}: bool

  CustomEvent* = ref object of Event
    detail {.jsget.}: JSValue

  EventTarget* = ref object of RootObj
    eventListeners*: seq[EventListener]

  EventHandler* = JSValue

  EventListenerCallback = JSValue

  EventListener* = ref object
    ctype*: string
    callback*: EventListenerCallback
    capture: bool
    passive: Option[bool]
    once: bool
    #TODO AbortSignal
    #TODO do we really need `removed'? maybe we could just check if
    # callback is undefined.
    removed*: bool

jsDestructor(Event)
jsDestructor(CustomEvent)
jsDestructor(EventTarget)

# Forward declaration hack
var isDefaultPassive*: proc (eventTarget: EventTarget): bool

type
  EventInit = object of JSDict
    bubbles: bool
    cancelable: bool
    composed: bool

  CustomEventInit = object of EventInit
    detail: JSValue

# Event
proc innerEventCreationSteps(event: Event; eventInitDict: EventInit) =
  event.flags = {efInitialized}
  #TODO this is probably incorrect?
  # I think it measures the time since the first fork. not sure though
  event.timeStamp = round(cpuTime())
  event.bubbles = eventInitDict.bubbles
  event.cancelable = eventInitDict.cancelable
  if eventInitDict.composed:
    event.flags.incl(efComposed)

#TODO eventInitDict type
proc newEvent(ctype: string; eventInitDict = EventInit()):
    JSResult[Event] {.jsctor.} =
  let event = Event()
  event.innerEventCreationSteps(eventInitDict)
  event.ctype = ctype
  return ok(event)

proc newEvent*(ctx: JSContext; ctype: string; target: EventTarget): Event =
  return Event(
    ctype: ctype,
    target: target,
    currentTarget: target
  )

proc initialize(this: Event; ctype: string; bubbles, cancelable: bool) =
  this.flags.incl(efInitialized)
  this.isTrusted = false
  this.target = nil
  this.ctype = ctype
  this.bubbles = bubbles
  this.cancelable = cancelable

proc initEvent(this: Event; ctype: string; bubbles, cancelable: bool)
    {.jsfunc.} =
  if efDispatch notin this.flags:
    this.initialize(ctype, bubbles, cancelable)

func srcElement(this: Event): EventTarget {.jsfget.} =
  return this.target

#TODO shadow DOM etc.
func composedPath(this: Event): seq[EventTarget] {.jsfunc.} =
  if this.currentTarget == nil:
    return @[]
  return @[this.currentTarget]

proc stopPropagation(this: Event) {.jsfunc.} =
  this.flags.incl(efStopPropagation)

func cancelBubble(this: Event): bool {.jsfget.} =
  return efStopPropagation in this.flags

proc cancelBubble(this: Event; cancel: bool) {.jsfset.} =
  if cancel:
    this.stopPropagation()

proc stopImmediatePropagation(this: Event) {.jsfunc.} =
  this.flags.incl({efStopPropagation, efStopImmediatePropagation})

proc setCanceledFlag(this: Event) =
  if this.cancelable and efInPassiveListener notin this.flags:
    this.flags.incl(efCanceled)

proc returnValue(this: Event): bool {.jsfget.} =
  return efCanceled notin this.flags

proc returnValue(this: Event; value: bool) {.jsfset.} =
  if not value:
    this.setCanceledFlag()

proc preventDefault(this: Event) {.jsfunc.} =
  this.flags.incl(efCanceled)

func defaultPrevented(this: Event): bool {.jsfget.} =
  return efCanceled in this.flags

func composed(this: Event): bool {.jsfget.} =
  return efComposed in this.flags

# CustomEvent
proc newCustomEvent(ctype: string; eventInitDict = CustomEventInit()):
    JSResult[CustomEvent] {.jsctor.} =
  let event = CustomEvent()
  event.innerEventCreationSteps(eventInitDict)
  event.detail = eventInitDict.detail
  event.ctype = ctype
  return ok(event)

proc finalize(rt: JSRuntime; this: CustomEvent) {.jsfin.} =
  JS_FreeValueRT(rt, this.detail)

proc initCustomEvent(this: CustomEvent; ctype: string;
    bubbles, cancelable: bool; detail: JSValue) {.jsfunc.} =
  if efDispatch notin this.flags:
    this.initialize(ctype, bubbles, cancelable)
    this.detail = detail

# EventTarget
proc newEventTarget(): EventTarget {.jsctor.} =
  return EventTarget()

proc defaultPassiveValue(ctype: string; eventTarget: EventTarget): bool =
  if ctype in ["touchstart", "touchmove", "wheel", "mousewheel"]:
    return true
  return eventTarget.isDefaultPassive()

proc findEventListener(eventTarget: EventTarget; ctype: string;
    callback: EventListenerCallback; capture: bool): int =
  for i in 0 ..< eventTarget.eventListeners.len:
    let it = eventTarget.eventListeners[i]
    if it.ctype == ctype and it.callback == callback and it.capture == capture:
      return i
  return -1

# EventListener
proc invoke*(ctx: JSContext; listener: EventListener; event: Event):
    JSValue =
  #TODO make this standards compliant
  if JS_IsNull(listener.callback):
    return JS_UNDEFINED
  let jsTarget = ctx.toJS(event.currentTarget)
  var jsEvent = ctx.toJS(event)
  if JS_IsFunction(ctx, listener.callback):
    let ret = JS_Call(ctx, listener.callback, jsTarget, 1, addr jsEvent)
    JS_FreeValue(ctx, jsTarget)
    JS_FreeValue(ctx, jsEvent)
    return ret
  assert JS_IsObject(listener.callback)
  let handler = JS_GetPropertyStr(ctx, listener.callback, "handleEvent")
  if JS_IsException(handler):
    JS_FreeValue(ctx, jsTarget)
    JS_FreeValue(ctx, jsEvent)
    return handler
  let ret = JS_Call(ctx, handler, jsTarget, 1, addr jsEvent)
  JS_FreeValue(ctx, jsTarget)
  JS_FreeValue(ctx, jsEvent)
  return ret

# shared
proc addAnEventListener(target: EventTarget; listener: EventListener) =
  #TODO signals
  if JS_IsUndefined(listener.callback):
    return
  if listener.passive.isNone:
    listener.passive = some(defaultPassiveValue(listener.ctype, target))
  if target.findEventListener(listener.ctype, listener.callback,
      listener.capture) == -1: # dedup
    target.eventListeners.add(listener)
  #TODO signals

proc removeAnEventListener(eventTarget: EventTarget; ctx: JSContext; i: int) =
  let listener = eventTarget.eventListeners[i]
  listener.removed = true
  JS_FreeValue(ctx, listener.callback)
  listener.callback = JS_UNDEFINED
  eventTarget.eventListeners.delete(i)

proc flatten(ctx: JSContext; options: JSValue): bool =
  if JS_IsBool(options):
    return fromJS[bool](ctx, options).get(false)
  if JS_IsObject(options):
    let x = JS_GetPropertyStr(ctx, options, "capture")
    return fromJS[bool](ctx, x).get(false)
  return false

proc flattenMore(ctx: JSContext; options: JSValue):
    tuple[
      capture: bool,
      once: bool,
      passive: Option[bool]
      #TODO signals
    ] =
  if JS_IsUndefined(options):
    return
  let capture = flatten(ctx, options)
  var once = false
  var passive: Option[bool]
  if JS_IsObject(options):
    once = fromJS[bool](ctx, JS_GetPropertyStr(ctx, options, "once"))
      .get(false)
    let x = fromJS[bool](ctx, JS_GetPropertyStr(ctx, options, "passive"))
    if x.isSome:
      passive = some(x.get)
  return (capture, once, passive)

proc addEventListener*(ctx: JSContext; eventTarget: EventTarget; ctype: string;
    callback: EventListenerCallback; options = JS_UNDEFINED): Err[JSError]
    {.jsfunc.} =
  if not JS_IsObject(callback) and not JS_IsNull(callback):
    return errTypeError("callback is not an object")
  let (capture, once, passive) = flattenMore(ctx, options)
  let listener = EventListener(
    ctype: ctype,
    capture: capture,
    passive: passive,
    once: once,
    callback: JS_DupValue(ctx, callback)
  )
  eventTarget.addAnEventListener(listener)
  ok()

proc removeEventListener(ctx: JSContext; eventTarget: EventTarget;
    ctype: string; callback: EventListenerCallback;
    options = JS_UNDEFINED) {.jsfunc.} =
  let capture = flatten(ctx, options)
  let i = eventTarget.findEventListener(ctype, callback, capture)
  if i != -1:
    eventTarget.removeAnEventListener(ctx, i)

proc addEventModule*(ctx: JSContext) =
  let eventCID = ctx.registerType(Event)
  ctx.registerType(CustomEvent, parent = eventCID)
  ctx.defineConsts(eventCID, EventPhase, uint16)
  ctx.registerType(EventTarget)
