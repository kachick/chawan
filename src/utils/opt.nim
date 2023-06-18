# Inspired by nim-results.

type
  Result*[T, E] = object
    when (T is void) and (E is void):
      has: bool
    else:
      case has: bool
      of true:
        when not (T is void):
          val: T
      else:
        when not (E is void):
          ex: E
        else:
          discard

  Opt*[T] = Result[T, void]

  Err*[E] = Result[void, E]

template ok*[E](t: type Err[E]): Err[E] =
  Err[E](has: true)

template ok*[T, E](t: type Result[T, E], x: T): Result[T, E] =
  Result[T, E](val: x, has: true)

template ok*[T](x: T): auto =
  ok(typeof(result), x)

template ok*(): auto =
  ok(typeof(result))

template ok*[T, E](res: var Result[T, E], x: T): Result[T, E] =
  res = Result[T, E](has: true, val: x)

template err*[T, E](t: type Result[T, E], e: E): Result[T, E] =
  Result[T, E](has: false, ex: e)

template err*[T](t: type Result[T, void]): Result[T, void] =
  Result[T, void](has: false)

template err*(): auto =
  err(typeof(result))

template err*[T, E](res: var Result[T, E], e: E) =
  res.ex = e

template err*[E](e: E): auto =
  err(typeof(result), e)

template isOk*(res: Result): bool = res.has
template isErr*(res: Result): bool = not res.has
template isSome*(res: Result): bool = res.isOk
template isNone*(res: Result): bool = res.isErr
template get*[T, E](res: Result[T, E]): T = res.val
template error*[T, E](res: Result[T, E]): E = res.ex

func isSameErr[T, E, F](a: type Result[T, E], b: type F): bool =
  return E is F

template `?`*[T, E](res: Result[T, E]): T =
  let x = res # for when res is a funcall
  if x.has:
    when not (T is void):
      x.get
    else:
      discard
  else:
    when typeof(result) is Result[T, E]:
      return x
    elif isSameErr(typeof(result), E):
      return err(x.error)
    else:
      return err()

template `?`*[E](res: Err[E]) =
  let x = res # for when res is a funcall
  if not x.has:
    when typeof(result) is Err[E]:
      return x
    elif isSameErr(typeof(result), E):
      return err(x.error)
    else:
      return err()
