{.push header: "<unistd.h>", importc.}

proc pledge*(promises, execpromises: cstring): cint
proc unveil*(path, permissions: cstring): cint

{.pop.}
