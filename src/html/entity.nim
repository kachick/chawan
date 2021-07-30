import json

import ../utils/radixtree

const entity = staticRead"../../res/entity.json"
when defined(small):
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
else:
  proc genEntityMap(): StaticRadixTree[string] =
    let entityJson = parseJson(entity)
    var entityMap = newStaticRadixTree[string]()

    for k, v in entityJson:
      entityMap[k.substr(1)] = v{"characters"}.getStr()

    return entityMap
  const entityMap* = genEntityMap()
