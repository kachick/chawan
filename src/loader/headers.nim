import std/tables

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

proc fromJSHeadersInit(ctx: JSContext; val: JSValue): JSResult[HeadersInit] =
  if JS_IsUndefined(val) or JS_IsNull(val):
    return err(nil)
  if isSequence(ctx, val):
    let x = fromJS[seq[(string, string)]](ctx, val)
    if x.isSome:
      return ok(HeadersInit(t: HEADERS_INIT_SEQUENCE, s: x.get))
  let x = ?fromJS[Table[string, string]](ctx, val)
  return ok(HeadersInit(t: HEADERS_INIT_TABLE, tab: x))

proc fill*(headers: Headers; s: seq[(string, string)]) =
  for (k, v) in s:
    if k in headers.table:
      headers.table[k].add(v)
    else:
      headers.table[k] = @[v]

proc fill*(headers: Headers; tab: Table[string, string]) =
  for k, v in tab:
    if k in headers.table:
      headers.table[k].add(v)
    else:
      headers.table[k] = @[v]

proc fill*(headers: Headers; init: HeadersInit) =
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

func newHeaders*(table: openArray[(string, string)]): Headers =
  let headers = Headers()
  for (k, v) in table:
    let k = k.toHeaderCase()
    headers.table.withValue(k, vs):
      vs[].add(v)
    do:
      headers.table[k] = @[v]
  return headers

func newHeaders*(table: Table[string, string]): Headers =
  let headers = Headers()
  for k, v in table:
    let k = k.toHeaderCase()
    headers.table.withValue(k, vs):
      vs[].add(v)
    do:
      headers.table[k] = @[v]
  return headers

func clone*(headers: Headers): Headers =
  return Headers(
    table: headers.table
  )

proc add*(headers: Headers; k, v: string) =
  let k = k.toHeaderCase()
  headers.table.withValue(k, p):
    p[].add(v)
  do:
    headers.table[k] = @[v]

proc `[]=`*(headers: Headers; k: static string, v: string) =
  const k = k.toHeaderCase()
  headers.table[k] = @[v]

func `[]`*(headers: Headers; k: static string): string =
  const k = k.toHeaderCase()
  return headers.table[k][0]

func contains*(headers: Headers; k: static string): bool =
  const k = k.toHeaderCase()
  return k in headers.table

func getOrDefault*(headers: Headers; k: static string; default = ""): string =
  const k = k.toHeaderCase()
  headers.table.withValue(k, p):
    return p[][0]
  do:
    return default

proc addHeadersModule*(ctx: JSContext) =
  ctx.registerType(Headers)
