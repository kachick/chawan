import js/javascript

type
  Event* = ref object

  EventTarget* = ref object of RootObj

  #EventHandler* = proc(event: Event): JSValue #TODO ?
  EventHandler* = JSValue

jsDestructor(Event)
jsDestructor(EventTarget)

proc addEventModule*(ctx: JSContext) =
  ctx.registerType(Event)
  ctx.registerType(EventTarget)
