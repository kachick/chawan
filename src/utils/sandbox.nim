when defined(freebsd):
  import bindings/capsicum

  proc enterBufferSandbox*(sockPath: string) =
    # per man:cap_enter(2), it may return ENOSYS if the kernel was compiled
    # without CAPABILITY_MODE. So it seems better not to panic in this case.
    # (But TODO: when we get enough sandboxing coverage it should print a
    # warning or something.)
    discard cap_enter()

  proc enterNetworkSandbox*() =
    # no difference between buffer; Capsicum is quite straightforward
    # to use in this regard.
    discard cap_enter()
elif defined(openbsd):
  import bindings/pledge

  proc enterBufferSandbox*(sockPath: string) =
    # take whatever we need to
    # * fork
    # * create/use UNIX domain sockets in sockPath
    # * take FDs from the main process
    # cw is the minimum for being able to make sockets
    doAssert unveil(cstring(sockPath), "cw") == 0
    # note: ordering is important; pledge now removes the unveil promise.
    doAssert pledge("unix stdio sendfd recvfd proc cpath", nil) == 0

  proc enterNetworkSandbox*() =
    # we don't need much to write out data from sockets to stdout.
    doAssert pledge("stdio", nil) == 0
else:
  proc enterBufferSandbox*(sockPath: string) =
    discard

  proc enterNetworkSandbox*() =
    discard
