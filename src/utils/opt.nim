# Inspired by nim-results.

type
  Result*[T, E] = object
    val: T
    has: bool
    when not (E is void):
      ex: E

  Opt*[T] = Result[T, void]

template ok*[T, E](t: type Result[T, E], x: T): Result[T, E] =
  Result[T, E](val: x, has: true)

template ok*[T](x: T): auto =
  ok(typeof(result), x)

template ok*[T, E](res: var Result[T, E], x: T): Result[T, E] =
  res.val = x
  res.has = true

template err*[T, E](t: type Result[T, E], e: E): Result[T, E] =
  Result[T, E](ex: e)

template err*[E](e: E): auto =
  err(typeof(result), e)

template err*[T, E](res: var Result[T, E], e: E) =
  res.ex = e

template isOk*(res: Result): bool = res.has
template isErr*(res: Result): bool = not res.has
template get*[T, E](res: Result[T, E]): T = res.val
template error*[T, E](res: Result[T, E]): E = res.ex
