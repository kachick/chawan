import std/selectors
import std/tables

import io/dynstream
import js/console
import monoucha/fromjs
import monoucha/javascript
import types/opt

type
  TimeoutType* = enum
    ttTimeout = "setTimeout handler"
    ttInterval = "setInterval handler"

  TimeoutEntry = ref object
    t: TimeoutType
    fd: int
    val: JSValue

  TimeoutState* = object
    timeoutid: int32
    timeouts: Table[int32, TimeoutEntry]
    timeoutFds: Table[int, int32]
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
  return state.timeouts.len == 0

proc clearTimeout*(state: var TimeoutState; id: int32) =
  if id in state.timeouts:
    let entry = state.timeouts[id]
    state.selector.unregister(entry.fd)
    JS_FreeValue(state.jsctx, entry.val)
    state.timeoutFds.del(entry.fd)
    state.timeouts.del(id)

#TODO varargs
proc setTimeout*(state: var TimeoutState; t: TimeoutType; handler: JSValue;
    timeout = 0i32): int32 =
  let id = state.timeoutid
  inc state.timeoutid
  let fd = state.selector.registerTimer(max(timeout, 1), t == ttTimeout, 0)
  state.timeoutFds[fd] = id
  state.timeouts[id] = TimeoutEntry(
    t: t,
    fd: fd,
    val: JS_DupValue(state.jsctx, handler)
  )
  return id

proc runEntry(state: var TimeoutState; entry: TimeoutEntry; name: string) =
  if JS_IsFunction(state.jsctx, entry.val):
    let ret = JS_Call(state.jsctx, entry.val, JS_UNDEFINED, 0, nil)
    if JS_IsException(ret):
      state.jsctx.writeException(state.err)
    JS_FreeValue(state.jsctx, ret)
  else:
    let s = fromJS[string](state.jsctx, entry.val)
    if s.isSome:
      state.evalJSFree(s.get, "setInterval handler")

proc runTimeoutFd*(state: var TimeoutState; fd: int): bool =
  if fd notin state.timeoutFds:
    return false
  let id = state.timeoutFds[fd]
  let entry = state.timeouts[id]
  state.runEntry(entry, $entry.t)
  if entry.t == ttTimeout:
    state.clearTimeout(id)
  return true

proc clearAll*(state: var TimeoutState) =
  for entry in state.timeouts.values:
    state.selector.unregister(entry.fd)
    JS_FreeValue(state.jsctx, entry.val)
  state.timeouts.clear()
  state.timeoutFds.clear()
