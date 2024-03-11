import std/streams

import js/javascript

type Console* = ref object
  err*: Stream
  clearFun: proc()
  showFun: proc()
  hideFun: proc()

jsDestructor(Console)

proc newConsole*(err: Stream; clearFun: proc() = nil; showFun: proc() = nil;
    hideFun: proc() = nil): Console =
  return Console(
    err: err,
    clearFun: clearFun,
    showFun: showFun,
    hideFun: hideFun
  )

proc log*(console: Console, ss: varargs[string]) {.jsfunc.} =
  for i in 0..<ss.len:
    console.err.write(ss[i])
    if i != ss.high:
      console.err.write(' ')
  console.err.write('\n')
  console.err.flush()

proc clear(console: Console) {.jsfunc.} =
  if console.clearFun != nil:
    console.clearFun()

# For now, these are the same as log().
proc debug(console: Console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc error(console: Console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc info(console: Console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc warn(console: Console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc show(console: Console, ss: varargs[string]) {.jsfunc.} =
  if console.showFun != nil:
    console.showFun()

proc hide(console: Console, ss: varargs[string]) {.jsfunc.} =
  if console.hideFun != nil:
    console.hideFun()

proc addConsoleModule*(ctx: JSContext) =
  #TODO console should not have a prototype
  # "For historical reasons, console is lowercased."
  ctx.registerType(Console, nointerface = true, name = "console")
