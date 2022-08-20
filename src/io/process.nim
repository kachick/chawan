when defined(posix):
  import posix

proc doFork*(): Pid =
  result = fork()
  if result == -1:
    eprint "Failed to fork child process."
    quit(1)
  elif result != 0:
    return result
  discard setsid()
  let pid = fork()
  if pid != 0:
    quit(0)
  return 0

