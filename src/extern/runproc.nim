import streams
import posix

import display/term

proc c_system(cmd: cstring): cint {.
  importc: "system", header: "<stdlib.h>".}

# Run process (without suspending the terminal controller).
proc runProcess*(cmd: string): bool =
  let wstatus = c_system(cstring(cmd))
  if wstatus == -1:
    result = false
  else:
    result = WIFEXITED(wstatus) and WEXITSTATUS(wstatus) == 0
    if not result:
      # Hack.
      #TODO this is a very bad idea, e.g. say the editor is writing into the
      # file, then receives SIGINT, now the file is corrupted but Chawan will
      # happily read it as if nothing happened.
      # We should find a proper solution for this.
      result = WIFSIGNALED(wstatus) and WTERMSIG(wstatus) == SIGINT

# Run process (and suspend the terminal controller).
proc runProcess*(term: Terminal, cmd: string, wait = false): bool =
  term.quit()
  result = runProcess(cmd)
  if wait:
    term.anyKey()
  term.restart()

# Run process, and capture its output.
proc runProcessCapture*(term: Terminal, cmd: string, outs: var string): bool =
  let file = popen(cmd, "r")
  if file == nil:
    return false
  let fs = newFileStream(file)
  outs = fs.readAll()
  let rv = pclose(file)
  if rv == -1:
    return false
  return rv == 0
