# Very minimal Intl module... TODO make it more complete

import bindings/quickjs
import js/javascript
import js/tojs

type
  NumberFormat = ref object

jsDestructor(NumberFormat)

#TODO ...yeah
proc newNumberFormat(name: string = "en-US",
    options = none(JSValue)): NumberFormat {.jsctor.} =
  return NumberFormat()

#TODO: this should accept string/BigInt too
proc format(nf: NumberFormat, num: float64): string {.jsfunc.} =
  let s = $num
  var i = 0
  var L = s.len
  for k in countdown(s.high, 0):
    if s[k] == '.':
      L = k
      break
  if L mod 3 != 0:
    while i < L mod 3:
      result &= s[i]
      inc i
    if i < L:
      result &= ','
  let j = i
  while i < L:
    if j != i and i mod 3 == j:
      result &= ','
    result &= s[i]
    inc i
  if i + 1 < s.len and s[i] == '.':
    if not (s[i + 1] == '0' and s.len == i + 2):
      while i < s.len:
        result &= s[i]
        inc i

proc addIntlModule*(ctx: JSContext) =
  let global = JS_GetGlobalObject(ctx)
  let intl = JS_NewObject(ctx)
  ctx.registerType(NumberFormat, namespace = intl)
  ctx.defineProperty(global, "Intl", intl)
  JS_FreeValue(ctx, global)
