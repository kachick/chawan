import radixtree
import json

when defined(small):
  proc genEntityMap(data: seq[tuple[a: string, b: string]]): StaticRadixTree[string] =
    result = newStaticRadixTree[string]()
    for pair in data:
      result[pair.a] = pair.b

  proc genEntityHashMap(): seq[tuple[a: string, b: string]] =
    let entity = staticRead"../res/entity.json"
    let entityJson = parseJson(entity)

    for k, v in entityJson:
      result.add((k.substr(1), v{"characters"}.getStr()))
  const entityHashMap = genEntityHashMap()
  let entityMap* = genEntityMap(entityHashMap) #TODO: use refs here
else:
  import tables
  proc genEntityMap(): StaticRadixTree[string] =
    let entity = staticRead"../res/entity.json"
    let entityJson = parseJson(entity)
    var entityMap = newStaticRadixTree[string]()

    for k, v in entityJson:
      entityMap[k.substr(1)] = v{"characters"}.getStr()

    return entityMap
  const entityMap* = genEntityMap()
