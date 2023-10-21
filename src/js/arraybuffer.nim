import bindings/quickjs

type
  JSArrayBuffer* = object
    p*: ptr UncheckedArray[uint8]
    len*: csize_t
    dealloc*: JSFreeArrayBufferDataFunc

  JSArrayBufferView* = object
    abuf*: JSArrayBuffer
    offset*: csize_t # offset into the buffer
    nmemb*: csize_t # number of members
    nsize*: csize_t # member size

  JSUint8Array* = object
    abuf*: JSArrayBuffer
    offset*: csize_t # offset into the buffer
    nmemb*: csize_t # number of members
