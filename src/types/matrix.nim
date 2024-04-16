type Matrix* = object
  me*: seq[float64]
  w: int
  h: int

proc newMatrix*(me: seq[float64]; w, h: int): Matrix =
  return Matrix(
    me: me,
    w: w,
    h: h
  )

proc newIdentityMatrix*(n: int): Matrix =
  var me = newSeq[float64](n * n)
  for i in 0 ..< n:
    me[n * i + i] = 1
  return Matrix(
    me: me,
    w: n,
    h: n
  )

proc newMatrixUninitialized*(w, h: int): Matrix =
  return Matrix(
    me: newSeqUninitialized[float64](w * h),
    w: w,
    h: h
  )

#TODO this is extremely inefficient
proc `*`*(a, b: Matrix): Matrix =
  assert a.w == b.h
  let h = a.h
  let w = b.w
  let n = a.w
  var c = newMatrixUninitialized(w, h)
  for x in 0 ..< w:
    for y in 0 ..< h:
      var val: float64 = 0
      for i in 0 ..< n:
        val += a.me[y * a.w + i] * b.me[i * b.w + x]
      c.me[y * c.w + x] = val
  return c

proc `*=`*(a: var Matrix; b: Matrix) =
  a = a * b
