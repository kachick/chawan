import json

import utils/radixtree

const entity = staticRead"res/entity.json"
proc genEntityMap(data: seq[tuple[a: string, b: string]]): RadixNode[string] =
  result = newRadixTree[string]()
  for pair in data:
    result[pair.a] = pair.b

proc genEntityTable(): seq[tuple[a: string, b: string]] =
  let entityJson = parseJson(entity)

  for k, v in entityJson:
    result.add((k.substr(1), v{"characters"}.getStr()))
const entityTable = genEntityTable()
let entityMap* = genEntityMap(entityTable)
