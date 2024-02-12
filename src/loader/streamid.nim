# Identifier for remote streams; it is a tuple of the client's process ID and
# file descriptor.

type
  StreamId* = tuple[pid, fd: int]

const NullStreamId* = StreamId((-1, -1))
