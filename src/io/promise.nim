import tables

import utils/opt

type
  PromiseState* = enum
    PROMISE_PENDING, PROMISE_FULFILLED, PROMISE_REJECTED

  EmptyPromise* = ref object of RootObj
    cb: (proc())
    next: EmptyPromise
    opaque: pointer
    state*: PromiseState

  Promise*[T] = ref object of EmptyPromise
    res: T
    get: GetValueProc[T]

  GetValueProc[T] = (proc(opaque: pointer, res: var T))

  PromiseMap* = object
    tab: Table[int, EmptyPromise]
    opaque*: pointer

proc newPromiseMap*(opaque: pointer): PromiseMap =
  return PromiseMap(
    opaque: opaque
  )

proc addPromise*[T](map: var PromiseMap, id: int, get: GetValueProc[T]): Promise[T] =
  let promise = Promise[T](get: get, opaque: map.opaque)
  map.tab[id] = promise
  return promise

proc addEmptyPromise*(map: var PromiseMap, id: int): EmptyPromise =
  let promise = EmptyPromise(opaque: map.opaque)
  map.tab[id] = promise
  return promise

proc resolve*(promise: EmptyPromise) =
  var promise = promise
  while true:
    if promise.cb != nil:
      promise.cb()
    promise.cb = nil
    promise.state = PROMISE_FULFILLED
    promise = promise.next
    if promise == nil:
      break
    promise.next = nil

proc resolve*[T](promise: Promise[T], res: T) =
  if promise.cb != nil:
    if promise.get != nil:
      promise.get(promise.opaque, promise.res)
      promise.get = nil
    promise.res = res
    promise.resolve()

proc resolve*(map: var PromiseMap, promiseid: int) =
  var promise: EmptyPromise
  if map.tab.pop(promiseid, promise):
    promise.resolve()

func empty*(map: PromiseMap): bool =
  map.tab.len == 0

proc then*(promise: EmptyPromise, cb: (proc())): EmptyPromise {.discardable.} =
  if promise == nil:
    doAssert false
    return
  promise.cb = cb
  promise.next = EmptyPromise()
  if promise.state == PROMISE_FULFILLED:
    promise.resolve()
  return promise.next

proc then*[T](promise: Promise[T], cb: (proc(x: T))): EmptyPromise {.discardable.} =
  doAssert promise != nil
  return promise.then(proc() =
    if promise.get != nil:
      promise.get(promise.opaque, promise.res)
      promise.get = nil
    cb(promise.res))

proc then*[T](promise: EmptyPromise, cb: (proc(): Promise[T])): Promise[T] {.discardable.} =
  doAssert promise != nil
  let next = Promise[T]()
  promise.then(proc() =
    var p2 = cb()
    if p2 != nil:
      p2.then(proc(x: T) =
        next.res = x
        next.resolve())
    else:
      next.resolve())
  return next

proc then*[T](promise: Promise[T], cb: (proc(x: T): EmptyPromise)): EmptyPromise {.discardable.} =
  doAssert promise != nil
  let next = EmptyPromise()
  promise.then(proc(x: T) =
    let p2 = cb(x)
    if p2 != nil:
      p2.then(proc() =
        next.resolve())
    else:
      next.resolve())
  return next

proc then*[T, U](promise: Promise[T], cb: (proc(x: T): U)): Promise[U] {.discardable.} =
  doAssert promise != nil
  let next = Promise[U]()
  promise.then(proc(x: T) =
    next.res = cb(x)
    next.resolve())
  return next

proc then*[T, U](promise: Promise[T], cb: (proc(x: T): Promise[U])): Promise[U] {.discardable.} =
  doAssert promise != nil
  let next = Promise[U]()
  promise.then(proc(x: T) =
    let p2 = cb(x)
    if p2 != nil:
      p2.then(proc(y: U) =
        next.res = y
        next.resolve())
    else:
      next.resolve())
  return next

proc then*[T, U](promise: Promise[T], cb: (proc(x: T): Opt[Promise[U]])):
    Promise[Opt[U]] {.discardable.} =
  doAssert promise != nil
  let next = Promise[Opt[U]]()
  promise.then(proc(x: T) =
    let p2 = cb(x)
    if p2.isOk:
      p2.get.then(proc(y: U) =
        next.res = opt(y)
        next.resolve())
    else:
      next.resolve())
  return next

proc all*(promises: seq[EmptyPromise]): EmptyPromise =
  let res = EmptyPromise()
  var i = 0
  for promise in promises:
    promise.then(proc() =
      inc i
      if i == promises.len:
        res.resolve())
  if promises.len == 0:
    res.resolve()
  return res
