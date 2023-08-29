import tables

import js/fromjs
import js/javascript
import utils/twtstr

type Headers* = ref object
  table* {.jsget.}: Table[string, seq[string]]

jsDestructor(Headers)

proc fill*(headers: Headers, ctx: JSContext, val: JSValue) =
  if isSequence(ctx, val):
    let x = fromJS[seq[(string, string)]](ctx, val)
    if x.isSome:
      for (k, v) in x.get:
        if k in headers.table:
          headers.table[k].add(v)
        else:
          headers.table[k] = @[v]
  else:
    let x = fromJS[Table[string, string]](ctx, val)
    if x.isSome:
      for k, v in x.get:
        if k in headers.table:
          headers.table[k].add(v)
        else:
          headers.table[k] = @[v]

func newHeaders*(): Headers =
  new(result)

func newHeaders*(ctx: JSContext, obj = none(JSValue)): Headers {.jsctor.} =
  new(result)
  if obj.isSome:
    result.fill(ctx, obj.get)

func newHeaders*(table: Table[string, string]): Headers =
  new(result)
  for k, v in table:
    let k = k.toHeaderCase()
    if k in result.table:
      result.table[k].add(v)
    else:
      result.table[k] = @[v]

func clone*(headers: Headers): Headers =
  return Headers(
    table: headers.table
  )

proc add*(headers: var Headers, k, v: string) =
  let k = k.toHeaderCase()
  if k notin headers.table:
    headers.table[k] = @[v]
  else:
    headers.table[k].add(v)

proc `[]=`*(headers: var Headers, k, v: string) =
  headers.table[k.toHeaderCase()] = @[v]

func getOrDefault*(headers: Headers, k: string, default = ""): string =
  let k = k.toHeaderCase()
  if k in headers.table:
    headers.table[k][0]
  else:
    default

proc addHeadersModule*(ctx: JSContext) =
  ctx.registerType(Headers)
