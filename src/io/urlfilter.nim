import options

import types/url

type URLFilter* = object
  scheme: Option[string]
  host: Option[string]

proc newURLFilter*(scheme = none(string), host = none(string)): URLFilter =
  return URLFilter(
    scheme: scheme,
    host: host
  )

func match*(filter: URLFilter, url: URL): bool =
  if filter.scheme.isSome and filter.scheme.get != url.scheme:
    return false
  if filter.host.isSome and filter.host.get != url.host:
    return false
  return true
