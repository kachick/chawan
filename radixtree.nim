import tables
import strutils
import json

type
  RadixNode[T] = object
    children*: Table[string, uint16]
    case leaf*: bool
    of true: value*: T
    of false: discard

  RadixTree*[T] = object
    nodes*: seq[RadixNode[T]]

func newRadixTree*[T](): RadixTree[T] =
  result.nodes.add(RadixNode[T](leaf: false))

proc `[]=`*[T](tree: var RadixTree[T], key: string, value: T) =
  var n: uint16 = 0
  var p: uint16 = 0
  var i = 0
  var j = 0
  var s = ""
  var t = ""
  var nodeKey = ""
  # find last matching node
  while i < key.len:
    s &= key[i]
    if s in tree.nodes[n].children:
      p = n
      n = tree.nodes[n].children[s]
      t &= s
      j += s.len
      nodeKey = s
      s = ""
    inc i

  for k in tree.nodes[n].children.keys:
    if s.len > 0 and k.startsWith(s[0]):
      p = n
      n = tree.nodes[n].children[k]
      t &= k
      nodeKey = k
      break

  # if first node, just add normally
  if n == 0:
    tree.nodes.add(RadixNode[T](leaf: true, value: value))
    tree.nodes[n].children[key] = uint16(tree.nodes.len - 1)
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

      tree.nodes[p].children[key.substr(j, i - 1)] = uint16(tree.nodes.len)
      tree.nodes.add(RadixNode[T](leaf: false))
      tree.nodes[^1].children[t.substr(i)] = n
      tree.nodes[^1].children[key.substr(i)] = uint16(tree.nodes.len)
      tree.nodes.add(RadixNode[T](leaf: true, value: value))
      tree.nodes[p].children.del(nodeKey)
    else: # new is either substr of old or old is substr of new
      # new matches a node, so replace
      if key.len == t.len:
        let children = tree.nodes[n].children
        tree.nodes[n] = RadixNode[T](leaf: true, value: value)
        tree.nodes[n].children = children
      elif i == j:
      # new is longer than the old, so add child to old
        tree.nodes[n].children[key.substr(i)] = uint16(tree.nodes.len)
        tree.nodes.add(RadixNode[T](leaf: true, value: value))
      elif i > 0:
      # new is shorter than old, so:
      # * add new to parent
      # * add old to new
      # * remove old from parent
        tree.nodes[p].children[key.substr(j, i - 1)] = uint16(tree.nodes.len)
        tree.nodes.add(RadixNode[T](leaf: true, value: value))
        tree.nodes[^1].children[t.substr(i)] = n
        tree.nodes[p].children.del(nodeKey)

func getPrefix*[T](tree: RadixTree[T], prefix: string, at: uint16 = 0): uint16 =
  var s = ""
  var t = ""
  var n = at
  var i = 0
  while t.len < prefix.len:
    s &= prefix[i]
    t &= prefix[i]
    if s in tree.nodes[n].children:
      n = tree.nodes[n].children[s]
      s = ""
    inc i

  return n

func hasPrefix*[T](tree: RadixTree[T], prefix: string, at: uint16 = 0): bool =
  var s = ""
  var t = ""
  var n = at
  var i = 0
  while i < prefix.len:
    s &= prefix[i]
    if s in tree.nodes[n].children:
      n = tree.nodes[n].children[s]
      t &= s
      s = ""
    inc i

  if t.len == prefix.len:
    return true

  for k in tree.nodes[n].children.keys:
    if k.startsWith(prefix.substr(t.len)):
      return true

  return false

#tests
#var tree = newRadixTree[string]()
#tree.insert("hb", "abc")
#tree.insert("hi", "second")
#tree.insert("hia", "second")
#tree.insert("hia", "third")
#tree.insert("hiahhhooo", "two point fifth")
#tree.insert("hiahhho", "two point sixth")
#assert(tree.hasPrefix("h"))
#assert(tree.hasPrefix("hi"))
#assert(not tree.hasPrefix("hio"))
#assert(tree.hasPrefix("hiah"))
#assert(tree.hasPrefix("hiahhho"))
#assert(tree.hasPrefix("hiahhhooo"))
#assert(tree.lookup("hi", "error") != "error")
#assert(tree.lookup("hb", "error") != "error")
#assert(tree.lookup("hio", "error") == "error")
#assert(tree.lookup("hia", "error") != "error")
#assert(tree.lookup("hiahhhooo", "error") != "error")
#assert(tree.lookup("hiahhho", "error") != "error")
#assert(tree.lookup("hiahhhoo", "error") == "error")
#assert(tree.lookup("h", "error") == "error")
