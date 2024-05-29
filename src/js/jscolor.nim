import std/strutils

import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/quickjs
import monoucha/tojs
import types/color
import types/opt
import utils/charcategory
import utils/twtstr

func parseLegacyColor*(s: string): JSResult[RGBColor] =
  if s == "":
    return errTypeError("Color value must not be the empty string")
  let s = s.strip(chars = AsciiWhitespace).toLowerAscii()
  if s == "transparent":
    return errTypeError("Color must not be transparent")
  return ok(parseLegacyColor0(s))

proc toJS*(ctx: JSContext; rgb: RGBColor): JSValue =
  var res = "#"
  res.pushHex(rgb.r)
  res.pushHex(rgb.g)
  res.pushHex(rgb.b)
  return toJS(ctx, res)

proc fromJSRGBColor*(ctx: JSContext; val: JSValue): JSResult[RGBColor] =
  return parseLegacyColor(?fromJS[string](ctx, val))

proc toJS*(ctx: JSContext; rgba: ARGBColor): JSValue =
  var res = "#"
  res.pushHex(rgba.r)
  res.pushHex(rgba.g)
  res.pushHex(rgba.b)
  res.pushHex(rgba.a)
  return toJS(ctx, res)

proc fromJSARGBColor*(ctx: JSContext; val: JSValue): JSResult[ARGBColor] =
  if JS_IsNumber(val):
    # as hex
    return ok(ARGBColor(?fromJS[uint32](ctx, val)))
  # parse
  let x = parseARGBColor(?fromJS[string](ctx, val))
  if x.isSome:
    return ok(x.get)
  return errTypeError("Unrecognized color")
