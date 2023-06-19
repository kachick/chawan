import streams

import bindings/quickjs
import io/promise
import io/request
import js/javascript
import types/url

type
  Response* = ref object
    res*: int
    fd*: int
    body*: Stream
    bodyUsed* {.jsget.}: bool
    contenttype* {.jsget.}: string
    status* {.jsget.}: uint16
    headers* {.jsget.}: Headers
    redirect*: Request
    url*: URL #TODO should be urllist?
    unregisterFun*: proc()
    bodyRead*: Promise[string]

proc newResponse*(res: int, request: Request, fd = -1, stream: Stream = nil):
    Response =
  return Response(
    res: res,
    url: request.url,
    body: stream,
    bodyRead: Promise[string](),
    fd: fd
  )

func sok(response: Response): bool {.jsfget: "ok".} =
  return response.status in 200u16 .. 299u16

func surl(response: Response): string {.jsfget: "url".} =
  return $response.url

#TODO: this should be a property of body
proc close*(response: Response) {.jsfunc.} =
  response.bodyUsed = true
  if response.unregisterFun != nil:
    response.unregisterFun()
  if response.body != nil:
    response.body.close()

proc text*(response: Response): Promise[string] {.jsfunc.} =
  return response.bodyRead

proc json(ctx: JSContext, this: Response): Promise[JSValue] {.jsfunc.} =
  return this.text().then(proc(s: string): JSValue =
    return JS_ParseJSON(ctx, cstring(s), cast[csize_t](s.len),
      cstring"<input>"))

proc addResponseModule*(ctx: JSContext) =
  ctx.registerType(Response)
