import std/selectors
import std/tables

import io/dynstream
import monoucha/javascript

type TimeoutState* = object
  timeoutid: int32
  timeouts: Table[int32, tuple[handler: (proc()), fdi: int]]
  intervals: Table[int32, tuple[handler: (proc()), fdi: int, tofree: JSValue]]
  timeout_fdis: Table[int, int32]
  interval_fdis: Table[int, int32]
  selector: Selector[int] #TODO would be better with void...
  jsctx: JSContext
  err: DynStream #TODO shouldn't be needed
  evalJSFree: proc(src, file: string) #TODO ew

func newTimeoutState*(selector: Selector[int]; jsctx: JSContext; err: DynStream;
    evalJSFree: proc(src, file: string)): TimeoutState =
  return TimeoutState(
    selector: selector,
    jsctx: jsctx,
    err: err,
    evalJSFree: evalJSFree
  )

func empty*(state: TimeoutState): bool =
  return state.timeouts.len == 0 and state.intervals.len == 0

#TODO varargs
proc setTimeout*[T: JSValue|string](state: var TimeoutState; handler: T;
    timeout = 0i32): int32 =
  let id = state.timeoutid
  inc state.timeoutid
  let fdi = state.selector.registerTimer(max(timeout, 1), true, 0)
  state.timeout_fdis[fdi] = id
  when T is string:
    let evalJSFree = state.evalJSFree
    state.timeouts[id] = ((proc() =
      evalJSFree(handler, "setTimeout handler")
    ), fdi)
  else:
    let fun = JS_DupValue(state.jsctx, handler)
    let jsctx = state.jsctx
    let err = state.err
    state.timeouts[id] = ((proc() =
      let ret = JS_Call(jsctx, fun, JS_UNDEFINED, 0, nil)
      if JS_IsException(ret):
        jsctx.writeException(err)
      JS_FreeValue(jsctx, ret)
      JS_FreeValue(jsctx, fun)
    ), fdi)
  return id

proc clearTimeout*(state: var TimeoutState; id: int32) =
  if id in state.timeouts:
    let timeout = state.timeouts[id]
    state.selector.unregister(timeout.fdi)
    state.timeout_fdis.del(timeout.fdi)
    state.timeouts.del(id)

proc clearInterval*(state: var TimeoutState; id: int32) =
  if id in state.intervals:
    let interval = state.intervals[id]
    state.selector.unregister(interval.fdi)
    JS_FreeValue(state.jsctx, interval.tofree)
    state.interval_fdis.del(interval.fdi)
    state.intervals.del(id)

#TODO varargs
proc setInterval*[T: JSValue|string](state: var TimeoutState; handler: T;
    interval = 0i32): int32 =
  let id = state.timeoutid
  inc state.timeoutid
  let fdi = state.selector.registerTimer(max(interval, 1), false, 0)
  state.interval_fdis[fdi] = id
  when T is string:
    let evalJSFree = state.evalJSFree
    state.intervals[id] = ((proc() =
      evalJSFree(handler, "setInterval handler")
    ), fdi, JS_NULL)
  else:
    let fun = JS_DupValue(state.jsctx, handler)
    let jsctx = state.jsctx
    let err = state.err
    state.intervals[id] = ((proc() =
      let ret = JS_Call(jsctx, handler, JS_UNDEFINED, 0, nil)
      if JS_IsException(ret):
        jsctx.writeException(err)
      JS_FreeValue(jsctx, ret)
    ), fdi, fun)
  return id

proc runTimeoutFd*(state: var TimeoutState; fd: int): bool =
  if fd in state.interval_fdis:
    state.intervals[state.interval_fdis[fd]].handler()
    return true
  elif fd in state.timeout_fdis:
    let id = state.timeout_fdis[fd]
    let timeout = state.timeouts[id]
    timeout.handler()
    state.clearTimeout(id)
    return true
  return false
