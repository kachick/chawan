import utils/opt

type
  JSError* = ref object of RootObj
    e*: JSErrorEnum
    message*: string

  JSErrorEnum* = enum
    # QuickJS internal errors
    JS_EVAL_ERROR0 = "EvalError"
    JS_RANGE_ERROR0 = "RangeError"
    JS_REFERENCE_ERROR0 = "ReferenceError"
    JS_SYNTAX_ERROR0 = "SyntaxError"
    JS_TYPE_ERROR0 = "TypeError"
    JS_URI_ERROR0 = "URIError"
    JS_INTERNAL_ERROR0 = "InternalError"
    JS_AGGREGATE_ERROR0 = "AggregateError"
    # Chawan errors
    JS_DOM_EXCEPTION = "DOMException"

  JSResult*[T] = Result[T, JSError]

const QuickJSErrors* = [
  JS_EVAL_ERROR0,
  JS_RANGE_ERROR0,
  JS_REFERENCE_ERROR0,
  JS_SYNTAX_ERROR0,
  JS_TYPE_ERROR0,
  JS_URI_ERROR0,
  JS_INTERNAL_ERROR0,
  JS_AGGREGATE_ERROR0
]

proc newEvalError*(message: string): JSError =
  return JSError(
    e: JS_EVAL_ERROR0,
    message: message
  )

proc newRangeError*(message: string): JSError =
  return JSError(
    e: JS_RANGE_ERROR0,
    message: message
  )

proc newReferenceError*(message: string): JSError =
  return JSError(
    e: JS_REFERENCE_ERROR0,
    message: message
  )

proc newSyntaxError*(message: string): JSError =
  return JSError(
    e: JS_SYNTAX_ERROR0,
    message: message
  )

proc newTypeError*(message: string): JSError =
  return JSError(
    e: JS_TYPE_ERROR0,
    message: message
  )

proc newURIError*(message: string): JSError =
  return JSError(
    e: JS_URI_ERROR0,
    message: message
  )

proc newInternalError*(message: string): JSError =
  return JSError(
    e: JS_INTERNAL_ERROR0,
    message: message
  )

proc newAggregateError*(message: string): JSError =
  return JSError(
    e: JS_AGGREGATE_ERROR0,
    message: message
  )
