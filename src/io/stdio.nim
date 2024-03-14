import std/posix

proc closeHandle(fd, flags: cint) =
  let devnull = open("/dev/null", flags)
  doAssert devnull != -1
  if devnull != fd:
    discard dup2(devnull, fd)
    discard close(devnull)

proc closeStdin*() =
  closeHandle(0, O_RDONLY)

proc closeStdout*() =
  closeHandle(1, O_WRONLY)

proc closeStderr*() =
  closeHandle(2, O_WRONLY)

proc safeClose*(fd: cint) =
  if fd == 0:
    closeStdin()
  elif fd == 1 or fd == 2:
    closeHandle(fd, O_WRONLY)
  else:
    discard close(fd)
