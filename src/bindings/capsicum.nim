{.push header: "sys/capsicum.h", importc.}

proc cap_enter*(): cint
proc cap_getmode*(modep: ptr cuint): cint

{.pop.}
