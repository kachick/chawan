# Radix tree implementation, with some caveats:
# * insertion takes forever, so try to insert only during compile-time
# * it isn't that much faster than a hash table, even when used for e.g. parsing
#
# Update: now it also has a version using references. Should be somewhat faster
# at the cost of having to initialize it every time the program is started.

import strutils
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
  StaticRadixPairSeq = seq[StaticRadixPair]

  StaticRadixNode[T] = object
    children*: StaticRadixPairSeq
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

# PairSeq Insert: theoretically this should only be called when there's no
# conflicts...  TODO: so we should be able to just compare the first char?
# probably a bad idea...
proc `[]=`(pairseq: var StaticRadixPairSeq, k: string, v: int) =
  var i = 0
  while i < pairseq.len:
    if pairseq[i].k == k:
      pairseq[i].v = v
      return
    inc i

  pairseq.add((k: k, v: v))

proc `[]=`[T](node: RadixNode[T], k: string, n: RadixNode[T]) =
  var i = 0
  assert(k.len > 0)
  while i < node.children.len:
    if node.children[i].k == k:
      node.children[i].v = n
      return
    inc i

  node.children.add((k: k, v: n))

# PairSeq Lookup: since we're sure k is in pairseq, return the first match.
func `[]`(pairseq: StaticRadixPairSeq, k: string): int =
  var i = 0
  while i < pairseq.len:
    if pairseq[i].k[0] == k[0]:
      return pairseq[i].v
    inc i
  
  return -1

func `[]`[T](node: RadixNode[T], k: string): RadixNode[T] =
  var i = 0
  while i < node.children.len:
    if node.children[i].k[0] == k[0]:
      return node.children[i].v
    inc i

  return nil

# getOrDefault: we have to compare the entire string but if it doesn't match
# exactly we can just return default.
func getOrDefault(pairseq: StaticRadixPairSeq, k: string, default: int): int =
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
        debugecho "defa: ", k, " ", node.children[i].k
        return default
      var j = 1
      while j < k.len:
        if node.children[i].k[j] != k[j]:
          return default
        inc j
      return node.children[i].v
    inc i
  return default

func getOrDefault[T](node: RadixNode[T], k: string, default: int): int =
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
      return i
    inc i
  return default

iterator keys(pairseq: StaticRadixPairSeq): string =
  var i = 0
  while i < pairseq.len:
    yield pairseq[i].k
    inc i

iterator keys*[T](node: RadixNode[T]): string =
  var i = 0
  while i < node.children.len:
    yield node.children[i].k
    inc i

# AKA `in`.
func contains(pairseq: StaticRadixPairSeq, k: string): bool =
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

# Delete proc: again we should be able to check for first char only... TODO?
proc del(pairseq: var StaticRadixPairSeq, k: string) =
  var i = 0
  while i < pairseq.len:
    if pairseq[i].k == k:
      pairseq.del(i)
      return
    inc i

proc add[T](node: RadixNode[T], k: string, v: T) =
  node.children.add((k, RadixNode[T](leaf: true, value: v)))

proc add[T](node: RadixNode[T], k: string) =
  node.children.add((k, RadixNode[T](leaf: false)))

# Insert: this is ugly and I'm not quite sure about what it does at all. Oh
# well.
proc `[]=`*[T](tree: var StaticRadixTree[T], key: string, value: T) =
  var n = 0
  var p = 0
  var i = 0
  var j = 0
  var s = ""
  var t = ""
  var nodeKey = ""
  # find last matching node
  while i < key.len:
    s &= key[i]
    inc i
    if s in tree.nodes[n].children:
      p = n
      n = tree.nodes[n].children[s]
      t &= s
      j = i
      nodeKey = s
      s = ""

  for k in tree.nodes[n].children.keys:
    if s.len > 0 and k[0] == s[0]:
      p = n
      n = tree.nodes[n].children[k]
      t &= k
      nodeKey = k
      break

  # if first node, just add normally
  if n == 0:
    tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
    tree.nodes[n].children[key] = int(tree.nodes.len - 1)
  else:
    i = 0
    var conflict = false
    # compare new key with the one we found so far
    while i < t.len and i < key.len:
      if key[i] == t[i]:
        inc i
      else:
        conflict = true
        break

    if conflict:
      # conflict somewhere, so:
      # * add new non-leaf to parent
      # * add old to non-leaf
      # * add new to non-leaf
      # * remove old from parent
      assert(i != 0)

      tree.nodes[p].children[key.substr(j, i - 1)] = int(tree.nodes.len)
      tree.nodes.add(StaticRadixNode[T](leaf: false))
      tree.nodes[^1].children[t.substr(i)] = n
      tree.nodes[^1].children[key.substr(i)] = int(tree.nodes.len)
      tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
      tree.nodes[p].children.del(nodeKey)
    else: # new is either substr of old or old is substr of new
      # new matches a node, so replace
      if key.len == t.len:
        let children = tree.nodes[n].children
        tree.nodes[n] = StaticRadixNode[T](leaf: true, value: value)
        tree.nodes[n].children = children
      elif i == j:
      # new is longer than the old, so add child to old
        tree.nodes[n].children[key.substr(i)] = int(tree.nodes.len)
        tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
      elif i > 0:
      # new is shorter than old, so:
      # * add new to parent
      # * add old to new
      # * remove old from parent
        tree.nodes[p].children[key.substr(j, i - 1)] = int(tree.nodes.len)
        tree.nodes.add(StaticRadixNode[T](leaf: true, value: value))
        tree.nodes[^1].children[t.substr(i)] = n
        tree.nodes[p].children.del(nodeKey)

# Non-static insert, for extra fun - and code duplication :(
proc `[]=`*[T](tree: RadixNode[T], key: string, value: T) =
  var n = tree
  var p: RadixNode[T] = nil
  var i = 0
  var j = 0
  var k = 0
  var s = ""
  var t = ""
  var l = 0
  # find last matching node
  while i < key.len:
    s &= key[i]
    inc i
    let pk = n.getOrDefault(s, -1)
    if pk != -1:
      k = pk
      p = n
      n = n.children[k].v
      t &= s
      j = i
      s = ""

  l = 0
  for ki in n.keys:
    if s.len > 0 and ki[0] == s[0]:
      p = n
      n = n[ki]
      t &= ki
      k = l
      break
    inc l

  # TODO: this below could be a better algorithm for what we do above
  # but I'm kinda scared of touching it
  #n = tree
  #i = 0
  #j = 0
  #k = 0
  #t = ""
  #p = nil

  #var conflict = false
  #while i < key.len:
  #  k = 0
  #  for pk in n.keys:
  #    if pk[0] == key[i]:
  #      var l = 0
  #      while l < pk.len and i + l < key.len:
  #        if pk[l] != key[i + l]:
  #          conflict = true
  #          break
  #        inc l
  #      if not conflict:
  #        p = n
  #        n = n.children[k].v
  #        t &= pk
  #        i += l
  #        j = i
  #        break
  #    inc k
  #  inc i


  # if first node, just add normally
  if n == tree:
    tree.add(key, value)
  else:
    i = 0
    var conflict = false
    # compare new key with the one we found so far
    while i < t.len and i < key.len:
      if key[i] == t[i]:
        inc i
      else:
        conflict = true
        break

    if conflict:
      # conflict somewhere, so:
      # * add new non-leaf to parent
      # * add old to non-leaf
      # * add new to non-leaf
      # * remove old from parent
      debugecho "conflict: ", i, " ", j, " ", t, " ", key, ": ", key.substr(j, i - 1)
      p[key.substr(j, i - 1)] = RadixNode[T](leaf: false)
      p.children[^1].v[t.substr(i)] = n
      p.children[^1].v[key.substr(i)] = RadixNode[T](leaf: true, value: value)
      p.children.del(k)
    else: # new is either substr of old or old is substr of new
      # new matches a node, so replace
      if key.len == t.len:
        p.children[k].v = RadixNode[T](leaf: true, value: value, children: n.children)
      elif key.len > t.len:
      # new is longer than the old, so add child to old
        debugecho "longer: ", i, " ", j, " ", t, " ", key, ": ", key.substr(i)
        n[key.substr(i)] = RadixNode[T](leaf: true, value: value)
      else:
        assert(i > 0)
      # new is shorter than old, so:
      # * add new to parent
      # * add old to new
      # * remove old from parent
        debugecho "shorter: ", i, " ", j, " ", t, " ", key, ": ", key.substr(i)
        p[key.substr(j, i - 1)] = RadixNode[T](leaf: true, value: value)
        p.children[^1].v[t.substr(i)] = n
        p.children.del(k)

func `{}`*[T](tree: StaticRadixTree[T], key: string, at: int = 0): int =
  return tree.nodes[at].children.getOrDefault(key, at)

func `{}`*[T](tree: RadixNode[T], key: string, at: RadixNode[T] = tree): RadixNode[T] =
  return tree.getOrDefault(key, at)

func hasPrefix*[T](tree: StaticRadixTree[T], prefix: string, at: int = 0): bool =
  var n = at
  var i = 0
  var j = 0
  var s = ""
  while i < prefix.len:
    s &= prefix[i]
    inc i
    if s in tree.nodes[n].children:
      n = tree.nodes[n].children[s]
      j = i

  if j == prefix.len:
    return true

  for k in tree.nodes[n].children.keys:
    if prefix.len - j < k.len and k[0] == prefix[j]:
      i = 1
      inc j
      while j < prefix.len:
        inc i
        inc j
        if k[i] != k[j]:
          return false
      return true

  return false

func hasPrefix*[T](tree: RadixNode[T], prefix: string, at: RadixNode[T] = tree): bool =
  var n = at
  var i = 0
  var j = 0
  var s = ""
  while i < prefix.len:
    s &= prefix[i]
    inc i
    if s in n:
      n = n[s]
      j = i

  if j == prefix.len:
    return true

  for k in n.keys:
    if prefix.len - j < k.len and k[0] == prefix[j]:
      i = 1
      inc j
      while j < prefix.len:
        inc i
        inc j
        if k[i] != k[j]:
          return false
      return true

  return false
