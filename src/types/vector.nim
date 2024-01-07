import std/math

type Vector2D* = object
  x*: float64
  y*: float64

func `-`*(v1, v2: Vector2D): Vector2D =
  return Vector2D(x: v1.x - v2.x, y: v1.y - v2.y)

func `+`*(v1, v2: Vector2D): Vector2D =
  return Vector2D(x: v1.x + v2.x, y: v1.y + v2.y)

proc `+=`*(v1: var Vector2D, v2: Vector2D) =
  v1.x += v2.x
  v1.y += v2.y

proc `-=`*(v1: var Vector2D, v2: Vector2D) =
  v1.x -= v2.x
  v1.y -= v2.y

# scalar multiplication
func `*`*(v: Vector2D, s: float64): Vector2D =
  return Vector2D(x: v.x * s, y: v.y * s)

func `/`*(v: Vector2D, s: float64): Vector2D =
  return Vector2D(x: v.x / s, y: v.y / s)

# dot product
func `*`*(v1, v2: Vector2D): float64 =
  return v1.x * v2.x + v1.y * v2.y

func norm*(v: Vector2D): float64 =
  return sqrt(v.x * v.x + v.y * v.y)

# kind of a cross product?
func cross*(v1, v2: Vector2D): float64 =
  return v1.x * v2.y - v1.y * v2.x

# https://en.wikipedia.org/wiki/Inner_product_space
func innerAngle*(v1, v2: Vector2D): float64 =
  return arccos((v1 * v2) / (v1.norm() * v2.norm()))

func rotate*(v: Vector2D, alpha: float64): Vector2D =
  let sa = sin(alpha)
  let ca = cos(alpha)
  return Vector2D(
    x: v.x * ca - v.y * sa,
    y: v.x * sa + v.y * ca
  )

func collinear*(v1, v2, v3: Vector2D): bool =
  return almostEqual((v1.y - v2.y) * (v1.x - v3.x),
    (v1.y - v3.y) * (v1.x - v2.x))
