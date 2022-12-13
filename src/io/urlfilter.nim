import options

import js/regex
import types/url

#TODO add denyhost/s for blocklists
type URLFilter* = object
  scheme: Option[string]
  allowhost*: Option[string]
  allowhosts: seq[Regex]
  default: bool

proc newURLFilter*(scheme = none(string), allowhost = none(string),
                   allowhosts: seq[Regex] = @[], default = false): URLFilter =
  return URLFilter(
    scheme: scheme,
    allowhost: allowhost,
    allowhosts: allowhosts,
    default: default
  )

# Filters as follows:
# If scheme is given, only URLs with the same scheme are matched.
# Then, allowhost and allowhosts are checked; if none of these match the host,
# the function returns the value of `default'.
proc match*(filter: URLFilter, url: URL): bool =
  if filter.scheme.isSome and filter.scheme.get != url.scheme:
    return false
  let host = url.host
  if filter.allowhost.isSome and filter.allowhost.get == host:
    return true
  for regex in filter.allowhosts:
    if regex.match(host):
      return true
  return filter.default
