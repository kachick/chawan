import tables

import bindings/quickjs
import js/error
import js/fromjs
import js/javascript
import utils/twtstr

type
  Headers* = ref object
    table* {.jsget.}: Table[string, seq[string]]

  HeadersInitType = enum
    HEADERS_INIT_SEQUENCE, HEADERS_INIT_TABLE

  HeadersInit* = object
    case t: HeadersInitType
    of HEADERS_INIT_SEQUENCE:
      s: seq[(string, string)]
    of HEADERS_INIT_TABLE:
      tab: Table[string, string]

jsDestructor(Headers)

proc fromJS2*(ctx: JSContext, val: JSValue, res: var JSResult[HeadersInit]) =
  if JS_IsUndefined(val) or JS_IsNull(val):
    res.err(nil)
    return
  if isSequence(ctx, val):
    let x = fromJS[seq[(string, string)]](ctx, val)
    if x.isSome:
      res.ok(HeadersInit(t: HEADERS_INIT_SEQUENCE, s: x.get))
  else:
    let x = fromJS[Table[string, string]](ctx, val)
    if x.isSome:
      res.ok(HeadersInit(t: HEADERS_INIT_TABLE, tab: x.get))

proc fill*(headers: Headers, s: seq[(string, string)]) =
  for (k, v) in s:
    if k in headers.table:
      headers.table[k].add(v)
    else:
      headers.table[k] = @[v]

proc fill*(headers: Headers, tab: Table[string, string]) =
  for k, v in tab:
    if k in headers.table:
      headers.table[k].add(v)
    else:
      headers.table[k] = @[v]

proc fill*(headers: Headers, init: HeadersInit) =
  if init.t == HEADERS_INIT_SEQUENCE:
    headers.fill(init.s)
  else: # table
    headers.fill(init.tab)

func newHeaders*(): Headers =
  return Headers()

func newHeaders(obj = none(HeadersInit)): Headers {.jsctor.} =
  let headers = Headers()
  if obj.isSome:
    headers.fill(obj.get)
  return headers

func newHeaders*(table: Table[string, string]): Headers =
  let headers = Headers()
  for k, v in table:
    let k = k.toHeaderCase()
    if k in headers.table:
      headers.table[k].add(v)
    else:
      headers.table[k] = @[v]
  return headers

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
