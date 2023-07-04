import js/javascript

type
  EventPhase = enum
    NONE = 0u16
    CAPTURING_PHASE = 1u16
    AT_TARGET = 2u16
    BUBBLING_PHASE = 3u16

  Event* = ref object
    ctype {.jsget: "type".}: string
    target {.jsget.}: EventTarget
    currentTarget {.jsget.}: EventTarget
    eventPhase {.jsget.}: uint16
    bubbles {.jsget.}: bool
    cancelable {.jsget.}: bool

  EventTarget* = ref object of RootObj

  EventHandler* = JSValue

jsDestructor(Event)
jsDestructor(EventTarget)

func srcElement(this: Event): EventTarget {.jsfget.} =
  return this.target

proc addEventModule*(ctx: JSContext) =
  let eventCID = ctx.registerType(Event)
  ctx.defineConsts(eventCID, EventPhase, uint16)
  ctx.registerType(EventTarget)
