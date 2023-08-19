import math
import times

import bindings/quickjs
import js/javascript
import utils/opt

type
  EventPhase = enum
    NONE = 0u16
    CAPTURING_PHASE = 1u16
    AT_TARGET = 2u16
    BUBBLING_PHASE = 3u16

  EventFlag = enum
    FLAG_STOP_PROPAGATION
    FLAG_STOP_IMMEDIATE_PROPAGATION
    FLAG_CANCELED
    FLAG_IN_PASSIVE_LISTENER
    FLAG_COMPOSED
    FLAG_INITIALIZED
    FLAG_DISPATCH

  Event* = ref object of RootObj
    ctype {.jsget: "type".}: string
    target {.jsget.}: EventTarget
    currentTarget {.jsget.}: EventTarget
    eventPhase {.jsget.}: uint16
    bubbles {.jsget.}: bool
    cancelable {.jsget.}: bool
    #TODO DOMHighResTimeStamp?
    timeStamp {.jsget.}: float64
    flags: set[EventFlag]
    isTrusted {.jsufget.}: bool

  CustomEvent* = ref object of Event
    ctx: JSContext #TODO get rid of this
    detail {.jsget.}: JSValue

  EventTarget* = ref object of RootObj
    eventListeners*: seq[EventListener]

  EventHandler* = JSValue

  EventListenerCallback = proc (event: Event): Err[JSError]

  EventListener = ref object
    ctype: string
    callback: EventListenerCallback
    capture: bool
    passive: Opt[bool]
    once: bool
    #TODO AbortSignal
    removed: bool

jsDestructor(Event)
jsDestructor(CustomEvent)
jsDestructor(EventTarget)

# Forward declaration hack
var isDefaultPassive*: proc (eventTarget: EventTarget): bool

# Event
proc innerEventCreationSteps(event: Event, ctx: JSContext,
    eventInitDict: JSValue) =
  event.flags = {FLAG_INITIALIZED}
  #TODO this is probably incorrect?
  # I think it measures the time since the first fork. not sure though
  event.timeStamp = round(cpuTime())
  if not JS_IsUndefined(eventInitDict):
    template set(name: static string, value: var bool) =
      let prop = JS_GetPropertyStr(ctx, eventInitDict, name)
      let jsVal = fromJS[bool](ctx, prop)
      if jsVal.isSome:
        value = jsVal.get
    set "bubbles", event.bubbles
    set "cancelable", event.cancelable
    var composed: bool
    set "composed", composed
    if composed:
      event.flags.incl(FLAG_COMPOSED)

#TODO eventInitDict type
proc newEvent(ctx: JSContext, ctype: string, eventInitDict = JS_UNDEFINED):
    Result[Event, JSError] {.jsctor.} =
  if not JS_IsUndefined(eventInitDict) and not JS_IsObject(eventInitDict):
    return err(newTypeError("eventInitDict must be an object"))
  let event = Event()
  event.innerEventCreationSteps(ctx, eventInitDict)
  event.ctype = ctype
  return ok(event)

proc initialize(this: Event, ctype: string, bubbles, cancelable: bool) =
  this.flags.incl(FLAG_INITIALIZED)
  this.isTrusted = false
  this.target = nil
  this.ctype = ctype
  this.bubbles = bubbles
  this.cancelable = cancelable

proc initEvent(this: Event, ctype: string, bubbles, cancelable: bool)
    {.jsfunc.} =
  if FLAG_DISPATCH notin this.flags:
    this.initialize(ctype, bubbles, cancelable)

func srcElement(this: Event): EventTarget {.jsfget.} =
  return this.target

#TODO shadow DOM etc.
func composedPath(this: Event): seq[EventTarget] {.jsfunc.} =
  if this.currentTarget == nil:
    return @[]
  return @[this.currentTarget]

proc stopPropagation(this: Event) {.jsfunc.} =
  this.flags.incl(FLAG_STOP_PROPAGATION)

func cancelBubble(this: Event): bool {.jsfget.} =
  return FLAG_STOP_PROPAGATION in this.flags

proc cancelBubble(this: Event, cancel: bool) {.jsfset.} =
  if cancel:
    this.stopPropagation()

proc stopImmediatePropagation(this: Event) {.jsfunc.} =
  this.flags.incl({FLAG_STOP_PROPAGATION, FLAG_STOP_IMMEDIATE_PROPAGATION})

proc setCanceledFlag(this: Event) =
  if this.cancelable and FLAG_IN_PASSIVE_LISTENER notin this.flags:
    this.flags.incl(FLAG_CANCELED)

proc returnValue(this: Event): bool {.jsfget.} =
  return FLAG_CANCELED notin this.flags

proc returnValue(this: Event, value: bool) {.jsfset.} =
  if not value:
    this.setCanceledFlag()

proc preventDefault(this: Event) {.jsfunc.} =
  this.flags.incl(FLAG_CANCELED)

func defaultPrevented(this: Event): bool {.jsfget.} =
  return FLAG_CANCELED in this.flags

func composed(this: Event): bool {.jsfget.} =
  return FLAG_COMPOSED in this.flags

# CustomEvent
proc newCustomEvent(ctx: JSContext, ctype: string,
    eventInitDict = JS_UNDEFINED): Result[CustomEvent, JSError] {.jsctor.} =
  if not JS_IsUndefined(eventInitDict) and not JS_IsObject(eventInitDict):
    return err(newTypeError("eventInitDict must be an object"))
  let event = CustomEvent()
  event.innerEventCreationSteps(ctx, eventInitDict)
  event.detail = JS_GetPropertyStr(ctx, eventInitDict, "detail")
  event.ctx = ctx
  event.ctype = ctype
  return ok(event)

proc finalize(this: CustomEvent) {.jsfin.} =
  JS_FreeValue(this.ctx, this.detail)

proc initCustomEvent(ctx: JSContext, this: CustomEvent, ctype: string,
    bubbles, cancelable: bool, detail: JSValue) {.jsfunc.} =
  if FLAG_DISPATCH notin this.flags:
    this.initialize(ctype, bubbles, cancelable)
    this.ctx = ctx
    this.detail = detail

# EventTarget
proc newEventTarget(): EventTarget {.jsctor.} =
  return EventTarget()

proc defaultPassiveValue(ctype: string, eventTarget: EventTarget): bool =
  if ctype in ["touchstart", "touchmove", "wheel", "mousewheel"]:
    return true
  return eventTarget.isDefaultPassive()

proc findEventListener(eventTarget: EventTarget, ctype: string,
    callback: EventListenerCallback, capture: bool): int =
  for i in 0 ..< eventTarget.eventListeners.len:
    let it = eventTarget.eventListeners[i]
    if it.ctype == ctype and it.callback == callback and it.capture == capture:
      return i
  return -1

# shared
proc addAnEventListener(eventTarget: EventTarget, listener: EventListener) =
  #TODO signals
  if listener.callback == nil:
    return
  if listener.passive.isNone:
    listener.passive = opt(defaultPassiveValue(listener.ctype, eventTarget))
  if eventTarget.findEventListener(listener.ctype, listener.callback,
      listener.capture) == -1: # dedup
    eventTarget.eventListeners.add(listener)
  #TODO signals

proc removeAnEventListener(eventTarget: EventTarget, i: int) =
  eventTarget.eventListeners[i].removed = true
  eventTarget.eventListeners.delete(i)

proc flatten(ctx: JSContext, options: JSValue): bool =
  if JS_IsBool(options):
    return fromJS[bool](ctx, options).get(false)
  if JS_IsObject(options):
    let x = JS_GetPropertyStr(ctx, options, "capture")
    return fromJS[bool](ctx, x).get(false)
  return false

proc flattenMore(ctx: JSContext, options: JSValue):
    tuple[
      capture: bool,
      once: bool,
      passive: Opt[bool]
      #TODO signals
    ] =
  if JS_IsUndefined(options):
    return
  let capture = flatten(ctx, options)
  var once = false
  var passive: Opt[bool]
  if JS_IsObject(options):
    once = fromJS[bool](ctx, JS_GetPropertyStr(ctx, options, "once"))
      .get(false)
    let x = fromJS[bool](ctx, JS_GetPropertyStr(ctx, options, "passive"))
    if x.isSome:
      passive = opt(x.get)
  return (capture, once, passive)

proc addEventListener(ctx: JSContext, eventTarget: EventTarget,
    callback: EventListenerCallback, options = JS_UNDEFINED) {.jsfunc.} =
  let (capture, once, passive) = flattenMore(ctx, options)
  let listener = EventListener(
    capture: capture,
    passive: passive,
    once: once,
    callback: callback
  )
  eventTarget.addAnEventListener(listener)

proc removeEventListener(ctx: JSContext, eventTarget: EventTarget,
    ctype: string, callback: EventListenerCallback,
    options = JS_UNDEFINED) {.jsfunc.} =
  let capture = flatten(ctx, options)
  let i = eventTarget.findEventListener(ctype, callback, capture)
  if i != -1:
    eventTarget.removeAnEventListener(i)

proc addEventModule*(ctx: JSContext) =
  let eventCID = ctx.registerType(Event)
  ctx.registerType(CustomEvent, parent = eventCID)
  ctx.defineConsts(eventCID, EventPhase, uint16)
  ctx.registerType(EventTarget)
