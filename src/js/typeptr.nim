# Get a unique pointer for each type.
proc getTypePtr*[T](x: T): pointer =
  when T is RootRef:
    # I'm so sorry.
    # (This dereferences the object's first member, m_type. Probably.)
    return cast[ptr pointer](x)[]
  elif T is RootObj:
    return cast[pointer](x)
  else:
    return getTypeInfo(x)

func getTypePtr*(t: typedesc[ref object]): pointer =
  var x = t()
  return getTypePtr(x)

func getTypePtr*(t: type): pointer =
  var x: t
  return getTypePtr(x)
