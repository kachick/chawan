import streams

import bindings/quickjs
import io/headers
import io/promise
import io/request
import js/exception
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

jsDestructor(Response)

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

proc text*(response: Response): Promise[Result[string, JSError]] {.jsfunc.} =
  if response.bodyRead == nil:
    let p = Promise[Result[string, JSError]]()
    let err = Result[string, JSError]
      .err(newTypeError("Body has already been consumed"))
    p.resolve(err)
    return p
  let bodyRead = response.bodyRead
  response.bodyRead = nil
  return bodyRead.then(proc(s: string): Result[string, JSError] =
    ok(s))

proc json(ctx: JSContext, this: Response): Promise[Result[JSValue, JSError]]
    {.jsfunc.} =
  return this.text().then(proc(s: Result[string, JSError]):
      Result[JSValue, JSError] =
    let s = ?s
    return ok(JS_ParseJSON(ctx, cstring(s), cast[csize_t](s.len),
      cstring"<input>")))

proc addResponseModule*(ctx: JSContext) =
  ctx.registerType(Response)
