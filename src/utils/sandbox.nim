when defined(freebsd):
  import bindings/capsicum

when defined(freebsd):
  proc enterSandbox*() =
    # per man:cap_enter(2), it may return ENOSYS if the kernel was compiled
    # without CAPABILITY_MODE. So it seems better not to panic in this case.
    # (But TODO: when we get enough sandboxing coverage it should print a
    # warning or something.)
    discard cap_enter()
else:
  proc enterSandbox*() =
    discard
