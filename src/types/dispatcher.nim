import posix

import ips/forkserver

type Dispatcher* = ref object
  forkserver*: ForkServer
  mainproc*: Pid

proc newDispatcher*(): Dispatcher =
  new(result)
  result.forkserver = newForkServer()
  result.mainproc = getpid()
