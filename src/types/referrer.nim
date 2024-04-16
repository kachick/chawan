import std/options

import types/url

type ReferrerPolicy* = enum
  STRICT_ORIGIN_WHEN_CROSS_ORIGIN
  NO_REFERRER
  NO_REFERRER_WHEN_DOWNGRADE
  STRICT_ORIGIN
  ORIGIN
  SAME_ORIGIN
  ORIGIN_WHEN_CROSS_ORIGIN
  UNSAFE_URL

const DefaultPolicy* = STRICT_ORIGIN_WHEN_CROSS_ORIGIN

proc getReferrerPolicy*(s: string): Option[ReferrerPolicy] =
  case s
  of "no-referrer":
    return some(NO_REFERRER)
  of "no-referrer-when-downgrade":
    return some(NO_REFERRER_WHEN_DOWNGRADE)
  of "origin":
    return some(ORIGIN)
  of "origin-when-cross-origin":
    return some(ORIGIN_WHEN_CROSS_ORIGIN)
  of "same-origin":
    return some(SAME_ORIGIN)
  of "strict-origin":
    return some(STRICT_ORIGIN)
  of "strict-origin-when-cross-origin":
    return some(STRICT_ORIGIN_WHEN_CROSS_ORIGIN)
  of "unsafe-url":
    return some(UNSAFE_URL)

proc getReferrer*(prev, target: URL; policy: ReferrerPolicy): string =
  let origin = prev.origin0
  if origin.isNone:
    return ""
  if prev.scheme != "http" and prev.scheme != "https":
    return ""
  if target.scheme != "http" and target.scheme != "https":
    return ""
  case policy
  of NO_REFERRER:
    return ""
  of NO_REFERRER_WHEN_DOWNGRADE:
    if prev.scheme == "https" and target.scheme == "http":
      return ""
    return $origin & prev.pathname & prev.search
  of SAME_ORIGIN:
    if origin == target.origin0:
      return $origin
    return ""
  of ORIGIN:
    return $origin
  of STRICT_ORIGIN:
    if prev.scheme == "https" and target.scheme == "http":
      return ""
    return $origin
  of ORIGIN_WHEN_CROSS_ORIGIN:
    if origin != target.origin0:
      return $origin
    return $origin & prev.pathname & prev.search
  of STRICT_ORIGIN_WHEN_CROSS_ORIGIN:
    if prev.scheme == "https" and target.scheme == "http":
      return $origin
    if origin != target.origin0:
      return $origin
    return $origin & prev.pathname & prev.search
  of UNSAFE_URL:
    return $origin & prev.pathname & prev.search
