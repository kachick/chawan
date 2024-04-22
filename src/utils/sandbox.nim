# Security model with sandboxing:
#
# Buffer processes are the most security-sensitive, since they parse
# various resources retrieved from the network (CSS, HTML) and sometimes
# even execute untrusted code (JS, with an engine written in C). So the
# main goal is to give buffers as few permissions as possible.
#
# On FreeBSD, we create a file descriptor to the directory sockets
# reside in, and then use that for manipulating our sockets.
#(TODO: currently this is the same directory as the cache directory, which
# is sub-optimal because rogue buffers could access cached files.)
#
# Capsicum does not enable more fine-grained capability control, but
# in practice the things it does enable should not be enough to harm the
# user's system.
#
# On OpenBSD, we pledge the minimum amount of promises we need, and
# do not unveil anything. It seems to be roughly equivalent to the
# security we get with FreeBSD Capsicum.
#
# On Linux, we use libseccomp so that I don't have to manually write
# BPF filters.
# Sandboxing on Linux is at the moment slightly less safe than on the
# two BSDs, because a rogue buffer could in theory connect to whatever
# open UNIX domain socket on the system that the user has access to.
#TODO look into integrating Landlock to fix this.
#
# We do not have OS-level sandboxing on other systems (yet).
#
# Aside from sandboxing in buffer processes, we also have a more
# restrictive "network" sandbox that is intended for CGI processes that
# just read/write from/to the network and stdin/stdout. At the moment this
# is only used in the HTTP process.
#TODO add it to more CGI scripts

const disableSandbox {.booldefine.} = false

when defined(freebsd) and not disableSandbox:
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
elif defined(openbsd) and not disableSandbox:
  import bindings/pledge

  proc enterBufferSandbox*(sockPath: string) =
    # take whatever we need to
    # * fork
    # * connect to UNIX domain sockets
    # * take FDs from the main process
    doAssert pledge("unix stdio sendfd recvfd proc", nil) == 0

  proc enterNetworkSandbox*() =
    # we don't need much to write out data from sockets to stdout.
    doAssert pledge("stdio", nil) == 0
elif defined(linux) and not disableSandbox:
  import std/posix
  import bindings/libseccomp

  proc enterBufferSandbox*(sockPath: string) =
    onSignal SIGSYS:
      discard sig
      raise newException(Defect, "Sandbox violation in buffer")
    let ctx = seccomp_init(SCMP_ACT_TRAP)
    doAssert pointer(ctx) != nil
    const allowList = [
      cstring"accept", # for incoming requests to our controlling socket
      "accept4", # for when accept is implemented as accept4
      "bind", # for outgoing requests to loader
      "brk", # memory allocation
      "clock_gettime", # used by QuickJS in atomics
      "clone", # for when fork is implemented as clone
      "close", # duh
      "connect", # for outgoing requests to loader
      "epoll_create", "epoll_create1", "epoll_ctl", "epoll_wait", # epoll stuff
      "eventfd", # used by Nim selectors
      "exit_group", # for quit
      "fcntl", "fcntl64", # for changing blocking status
      "fork", # for when fork is really fork
      "fstat", # glibc fread seems to call it
      "getpid", # for determining current PID after we fork
      "getrlimit", # glibc uses it after fork it seems
      "getsockname", # Nim needs it for connecting
      "gettimeofday", # used by QuickJS in Date.now()
      "mmap", # memory allocation
      "mmap2", # memory allocation
      "munmap", # memory allocation
      "pipe", # for pipes to child process
      "pipe2", # for when pipe is implemented as pipe2
      "prlimit64", # for when getrlimit is implemented as prlimit64
      "read", "recv", "recvfrom", "recvmsg", # for reading from sockets
      "send", "sendmsg", "sendto", # for writing to sockets
      "set_robust_list", # glibc seems to need it for whatever reason
      "setrlimit", # glibc seems to use it for whatever reason
      "timerfd_create", # used by Nim selectors
      "timerfd_gettime", # not actually used by Nim but may be in the future
      "timerfd_settime", # used by Nim selectors
      "write" # for writing to sockets
    ]
    for it in allowList:
      let syscall = seccomp_syscall_resolve_name(it)
      doAssert seccomp_rule_add(ctx, SCMP_ACT_ALLOW, syscall, 0) == 0
    block allowUnixSockets:
      # only allow creation of UNIX domain sockets.
      let syscall = seccomp_syscall_resolve_name("socket")
      let arg0 = scmp_arg_cmp(
        arg: 0, # domain
        op: SCMP_CMP_EQ, # equals
        datum_a: 1 # PF_LOCAL == PF_UNIX == AF_UNIX
      )
      doAssert seccomp_rule_add(ctx, SCMP_ACT_ALLOW, syscall, 1, arg0) == 0
    doAssert seccomp_load(ctx) == 0
    seccomp_release(ctx)

  proc enterNetworkSandbox*() =
    onSignal SIGSYS:
      discard sig
      raise newException(Defect, "Sandbox violation in network process")
    let ctx = seccomp_init(SCMP_ACT_TRAP)
    doAssert pointer(ctx) != nil
    const allowList = [
      cstring"close", "exit_group", # duh
      "read", "write", "recv", "send", "recvfrom", "sendto", # socket i/o
      "fcntl", "fcntl64", # so we can set nonblock etc.
      "mmap", "mmap2", "munmap", "brk", # memory allocation
      "poll", # curl needs poll
      "fstat", # glibc fread seems to call it
      # maybe it will need epoll too in the future
      "epoll_create", "epoll_create1", "epoll_ctl", "epoll_wait",
      "ppoll", # or ppoll
      # we either have to use CURLOPT_NOSIGNAL or allow signals.
      # do the latter, otherwise the default name resolver will never time out.
      "signal", "sigaction", "rt_sigaction",
    ]
    for it in allowList:
      doAssert seccomp_rule_add(ctx, SCMP_ACT_ALLOW,
        seccomp_syscall_resolve_name(it), 0) == 0
    doAssert seccomp_load(ctx) == 0
    seccomp_release(ctx)
else:
  {.warning: "Building without OS-level sandboxing!".}
  proc enterBufferSandbox*(sockPath: string) =
    discard

  proc enterNetworkSandbox*() =
    discard
