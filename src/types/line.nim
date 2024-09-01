import types/vector

type
  Line* = object
    p0*: Vector2D
    p1*: Vector2D

  LineSegment* = object
    line: Line
    miny*: float64
    maxy*: float64
    minyx*: float64
    islope*: float64

func minx*(line: Line): float64 =
  return min(line.p0.x, line.p1.x)

func maxx*(line: Line): float64 =
  return max(line.p0.x, line.p1.x)

func minyx*(line: Line): float64 =
  if line.p0.y < line.p1.y:
    return line.p0.x
  return line.p1.x

func maxyx*(line: Line): float64 =
  if line.p0.y > line.p1.y:
    return line.p0.x
  return line.p1.x

func miny*(line: Line): float64 =
  return min(line.p0.y, line.p1.y)

func maxy*(line: Line): float64 =
  return max(line.p0.y, line.p1.y)

func slope*(line: Line): float64 =
  let xdiff = (line.p0.x - line.p1.x)
  if xdiff == 0:
    return 0
  return (line.p0.y - line.p1.y) / xdiff

# inverse slope
func islope*(line: Line): float64 =
  let ydiff = (line.p0.y - line.p1.y)
  if ydiff == 0:
    return 0
  return (line.p0.x - line.p1.x) / ydiff

proc cmpLineSegmentY*(l1, l2: LineSegment): int =
  return cmp(l1.miny, l2.miny)

proc cmpLineSegmentX*(l1, l2: LineSegment): int =
  return cmp(l1.minyx, l2.minyx)

func p0*(ls: LineSegment): Vector2D {.inline.} = ls.line.p0
func p1*(ls: LineSegment): Vector2D {.inline.} = ls.line.p1

proc toLineSegment*(line: Line): LineSegment =
  LineSegment(
    line: line,
    miny: line.miny,
    maxy: line.maxy,
    minyx: line.minyx,
    islope: line.islope
  )
