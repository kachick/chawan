import radixtree
import json
import tables
import strutils
import unicode
import twtstr

proc genEntityMap(): RadixTree[string] =
  let entity = staticRead"entity.json"
  let entityJson = parseJson(entity)
  var entityMap = newRadixTree[string]()

  for k, v in entityJson:
    entityMap[k.substr(1)] = v{"characters"}.getStr()

  return entityMap

const entityMap* = genEntityMap()
