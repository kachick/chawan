import tables

import bindings/quickjs
import js/error
import js/javascript

const NamesTable = {
  "IndexSizeError": 1u16,
  "HierarchyRequestError": 3u16,
  "WrongDocumentError": 4u16,
  "InvalidCharacterError": 5u16,
  "NoModificationAllowedError": 7u16,
  "NotFoundError": 8u16,
  "NotSupportedError": 9u16,
  "InUseAttributeError": 10u16,
  "InvalidStateError": 11u16,
  "SyntaxError": 12u16,
  "InvalidModificationError": 13u16,
  "NamespaceError": 14u16,
  "InvalidAccessError": 15u16,
  "TypeMismatchError": 17u16,
  "SecurityError": 18u16,
  "NetworkError": 19u16,
  "AbortError": 20u16,
  "URLMismatchError": 21u16,
  "QuotaExceededError": 22u16,
  "TimeoutError": 23u16,
  "InvalidNodeTypeError": 24u16,
  "DataCloneError": 25u16
}.toTable()

type
  DOMException* = ref object of JSError
    name* {.jsget.}: string

  DOMResult*[T] = Result[T, DOMException]

jsDestructor(DOMException)

proc newDOMException*(message = "", name = "Error"): DOMException {.jsctor.} =
  return DOMException(
    e: JS_DOM_EXCEPTION,
    name: name,
    message: message
  )

template errDOMException*(message, name: string): untyped =
  err(newDOMException(message, name))

func message0(this: DOMException): string {.jsfget: "message".} =
  return this.message

func code(this: DOMException): uint16 {.jsfget.} =
  return NamesTable.getOrDefault(this.name, 0u16)

proc addDOMExceptionModule*(ctx: JSContext) =
  ctx.registerType(DOMException, JS_CLASS_ERROR, errid = opt(JS_DOM_EXCEPTION))
