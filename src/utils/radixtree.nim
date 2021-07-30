# Radix tree implementation. It isn't that much faster than a hash table,
# however it *is* faster. Use StaticRadixTree for saving trees in the
# executable and RadixNode otherwise (which needs less bounds checking).

import json
import tables

type
  RadixPair[T] = tuple[k: string, v: RadixNode[T]]

  RadixNode*[T] = ref object
    children*: seq[RadixPair[T]]
    case leaf*: bool
    of true: value*: T
    of false: discard

  StaticRadixPair = tuple[k: string, v: int]

  StaticRadixNode[T] = object
    children*: seq[StaticRadixPair]
    case leaf*: bool
    of true: value*: T
    of false: discard

  StaticRadixTree*[T] = object
    nodes*: seq[StaticRadixNode[T]]

func newStaticRadixTree*[T](): StaticRadixTree[T] =
  result.nodes.add(StaticRadixNode[T](leaf: false))

func newRadixTree*[T](): RadixNode[T] =
  new(result)

func toRadixTree*[T](table: Table[string, T]): RadixNode[T] =
  result = newRadixTree[T]()
  for k, v in table:
    result[k] = v

# getOrDefault: we have to compare the entire string but if it doesn't match
# exactly we can just return default.
func getOrDefault(pairseq: seq[StaticRadixPair], k: string, default: int): int =
  var i = 0
  while i < pairseq.len:
    if pairseq[i].k[0] == k[0]:
      if k.len != pairseq[i].k.len:
        return default
      var j = 1
      while j < k.len:
        if pairseq[i].k[j] != k[j]:
          return default
        inc j
      return pairseq[i].v
    inc i
  return default

func getOrDefault[T](node: RadixNode[T], k: string, default: RadixNode[T]): RadixNode[T] =
  var i = 0
  while i < node.children.len:
    if node.children[i].k[0] == k[0]:
      if k.len != node.children[i].k.len:
        return default
      var j = 1
      while j < k.len:
        if node.children[i].k[j] != k[j]:
          return default
        inc j
      return node.children[i].v
    inc i
  return default

iterator keys(pairseq: seq[StaticRadixPair]): string =
  var i = 0
  while i < pairseq.len:
    yield pairseq[i].k
    inc i

iterator keys*[T](node: RadixNode[T]): string =
  var i = 0
  while i < node.children.len:
    yield node.children[i].k
    inc i

func contains(pairseq: seq[StaticRadixPair], k: string): bool =
  var i = 0
  while i < pairseq.len:
    if pairseq[i].k[0] == k[0]:
      if k.len != pairseq[i].k.len:
        return false
      var j = 1
      while j < k.len:
        if pairseq[i].k[j] != k[j]:
          return false
        inc j
      return true
    inc i
  return false

func contains[T](node: RadixNode[T], k: string): bool =
  var i = 0
  while i < node.children.len:
    if node.children[i].k[0] == k[0]:
      if k.len != node.children[i].k.len:
        return false
      var j = 1
      while j < k.len:
        if node.children[i].k[j] != k[j]:
          return false
        inc j
      return true
    inc i
  return false

# Static insert
proc `[]=`*[T](tree: var StaticRadixTree[T], key: string, value: T) =
  var n = 0
  var p = 0
  var i = 0
  var j = 0
  var k = 0
  var t = ""
  # find last matching node
  var conflict = false
  while i < key.len:
    let m = i
    var o = 0
    for pk in tree.nodes[n].children.keys:
      if pk[0] == key[i]:
        var l = 0
        while l < pk.len and i + l < key.len:
          if pk[l] != key[i + l]:
            conflict = true
            break
          inc l
        p = n
        k = o
        n = tree.nodes[n].children[k].v
        t &= pk
        i += l
        if not conflict and pk.len == l:
          j = i
        break
      inc o
    if i == m:
      break
    if conflict:
      break

  # if first node, just add normally
  if n == 0:
    tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
    tree.nodes[n].children.add((k: key, v: int(tree.nodes.len - 1)))
  elif conflict:
    # conflict somewhere, so:
    # * add new non-leaf to parent
    # * add old to non-leaf
    # * add new to non-leaf
    # * remove old from parent
    tree.nodes[p].children.add((k: key.substr(j, i - 1), v: int(tree.nodes.len)))
    tree.nodes.add(StaticRadixNode[T](leaf: false))
    tree.nodes[^1].children.add((k: t.substr(i), v: n))
    tree.nodes[^1].children.add((k: key.substr(i), v: int(tree.nodes.len)))
    tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
    tree.nodes[p].children.del(k)
  elif key.len == t.len:
    # new matches a node, so replace
    tree.nodes[n] = StaticRadixNode[T](leaf: true, value: value, children: tree.nodes[n].children)
  elif i == j:
    # new is longer than the old, so add child to old
    tree.nodes[n].children.add((k: key.substr(i), v: int(tree.nodes.len)))
    tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
  else:
    # new is shorter than old, so:
    # * add new to parent
    # * add old to new
    # * remove old from parent
    tree.nodes[p].children.add((k: key.substr(j, i - 1), v: int(tree.nodes.len)))
    tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
    tree.nodes[^1].children.add((k: key.substr(i), v: n))
    tree.nodes[p].children.del(k)

# O(1) add procedures for insert
proc add[T](node: RadixNode[T], k: string, v: T) =
  node.children.add((k, RadixNode[T](leaf: true, value: v)))

proc add[T](node: RadixNode[T], k: string) =
  node.children.add((k, RadixNode[T](leaf: false)))

proc add[T](node: RadixNode[T], k: string, v: RadixNode[T]) =
  node.children.add((k, v))

# Non-static insert
proc `[]=`*[T](tree: RadixNode[T], key: string, value: T) =
  var n = tree
  var p: RadixNode[T] = nil
  var i = 0
  var j = 0
  var k = 0
  var t = ""

  # find last matching node
  var conflict = false
  while i < key.len:
    let m = i
    var o = 0
    for pk in n.keys:
      if pk[0] == key[i]:
        var l = 0
        while l < pk.len and i + l < key.len:
          if pk[l] != key[i + l]:
            conflict = true
            #t = key.substr(0, i + l - 1) & pk.substr(l)
            break
          inc l
        p = n
        k = o
        n = n.children[k].v
        t &= pk
        i += l
        if not conflict and pk.len == l:
          j = i 
        #  t = key.substr(0, i - 1)
        #elif not conflict and pk.len > l:
        #  t = key & pk.substr(l)
        break
      inc o
    if i == m:
      break
    if conflict:
      break

  if n == tree:
    # first node, just add normally
    tree.add(key, value)
  elif conflict:
    # conflict somewhere, so:
    # * add new non-leaf to parent
    # * add old to non-leaf
    # * add new to non-leaf
    # * remove old from parent
    p.add(key.substr(j, i - 1))
    p.children[^1].v.add(t.substr(i), n)
    p.children[^1].v.add(key.substr(i), value)
    p.children.del(k)
  elif key.len == t.len:
    # new matches a node, so replace
    p.children[k].v = RadixNode[T](leaf: true, value: value, children: n.children)
  elif key.len > t.len:
    # new is longer than the old, so add child to old
    n.add(key.substr(i), value)
  else:
    # new is shorter than old, so:
    # * add new to parent
    # * add old to new
    # * remove old from parent
    p.add(key.substr(j, i - 1), value)
    p.children[^1].v.add(t.substr(i), n)
    p.children.del(k)

func `{}`*[T](tree: StaticRadixTree[T], key: string, at: int = 0): int =
  return tree.nodes[at].children.getOrDefault(key, at)

func `{}`*[T](node: RadixNode[T], key: string): RadixNode[T] =
  return node.getOrDefault(key, node)

func hasPrefix*[T](tree: StaticRadixTree[T], prefix: string, at: int = 0): bool =
  var n = at
  var i = 0

  while i < prefix.len:
    let m = i
    var j = 0
    for pk in tree.nodes[n].children.keys:
      if pk[0] == prefix[i]:
        var l = 0
        while l < pk.len and i + l < prefix.len:
          if pk[l] != prefix[i + l]:
            return false
          inc l
        n = tree.nodes[n].children[j].v
        i += l
        break
      inc j
    if i == m:
      return false

  return true

func hasPrefix*[T](tree: RadixNode[T], prefix: string, at: RadixNode[T] = tree): bool =
  var n = at
  var i = 0

  while i < prefix.len:
    let m = i
    var j = 0
    for pk in n.keys:
      if pk[0] == prefix[i]:
        var l = 0
        while l < pk.len and i + l < prefix.len:
          if pk[l] != prefix[i + l]:
            return false
          inc l
        n = n.children[j].v
        i += l
        break
      inc j
    if i == m:
      return false

  return true
