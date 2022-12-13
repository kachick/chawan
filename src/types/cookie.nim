import options
import strutils
import times

import io/urlfilter
import js/javascript
import js/regex
import types/url
import utils/twtstr

type
  Cookie* = ref object
    name {.jsget.}: string
    value {.jsget.}: string
    expires {.jsget.}: int64 # unix time
    maxAge {.jsget.}: int64
    secure {.jsget.}: bool
    httponly {.jsget.}: bool
    samesite {.jsget.}: bool
    domain {.jsget.}: string
    path {.jsget.}: string

  CookieJar* = ref object
    filter*: URLFilter
    cookies*: seq[Cookie]

proc parseCookieDate(val: string): Option[DateTime] =
  # cookie-date
  const Delimiters = {'\t', ' '..'/', ';'..'@', '['..'`', '{'..'~'}
  const NonDigit = AllChars - AsciiDigit
  var foundTime = false
  var foundDayOfMonth = false
  var foundMonth = false
  var foundYear = false
  # date-token-list
  var time: array[3, int]
  var dayOfMonth: int
  var month: int
  var year: int
  for dateToken in val.split(Delimiters):
    if dateToken == "": continue # *delimiter
    if not foundTime:
      block timeBlock: # test for time
        let hmsTime = dateToken.until(NonDigit - {':'})
        var i = 0
        for timeField in hmsTime.split(':'):
          if i > 2: break timeBlock # too many time fields
          # 1*2DIGIT
          if timeField.len != 1 and timeField.len != 2: break timeBlock
          var timeFields: array[3, int]
          for c in timeField:
            if c notin AsciiDigit: break timeBlock
            timeFields[i] *= 10
            timeFields[i] += c.decValue
          time = timeFields
          inc i
        if i != 3: break timeBlock
        foundTime = true
        continue
    if not foundDayOfMonth:
      block dayOfMonthBlock: # test for day-of-month
        let digits = dateToken.until(NonDigit)
        if digits.len != 1 and digits.len != 2: break dayOfMonthBlock
        var n = 0
        for c in digits:
          if c notin AsciiDigit: break dayOfMonthBlock
          n *= 10
          n += c.decValue
        dayOfMonth = n
        foundDayOfMonth = true
        continue
    if not foundMonth:
      block monthBlock: # test for month
        if dateToken.len < 3: break monthBlock
        case dateToken.substr(0, 2).toLower()
        of "jan": month = 1
        of "feb": month = 2
        of "mar": month = 3
        of "apr": month = 4
        of "may": month = 5
        of "jun": month = 6
        of "jul": month = 7
        of "aug": month = 8
        of "sep": month = 9
        of "oct": month = 10
        of "nov": month = 11
        of "dec": month = 12
        else: break monthBlock
        foundMonth = true
        continue
    if not foundYear:
      block yearBlock: # test for year
        let digits = dateToken.until(NonDigit)
        if digits.len != 2 and digits.len != 4: break yearBlock
        var n = 0
        for c in digits:
          if c notin AsciiDigit: break yearBlock
          n *= 10
          n += c.decValue
        year = n
        foundYear = true
        continue
  if not (foundDayOfMonth and foundMonth and foundYear and foundTime): return none(DateTime)
  if dayOfMonth notin 0..31: return none(DateTime)
  if year < 1601: return none(DateTime)
  if time[0] > 23: return none(DateTime)
  if time[1] > 59: return none(DateTime)
  if time[2] > 59: return none(DateTime)
  var dateTime = dateTime(year, Month(month), MonthdayRange(dayOfMonth), HourRange(time[0]), MinuteRange(time[1]), SecondRange(time[2]))
  return some(dateTime)

# For debugging
proc `$`*(cookiejar: CookieJar): string =
  result &= $cookiejar.filter
  result &= "\n"
  for cookie in cookiejar.cookies:
    result &= "Cookie "
    result &= $cookie[]

proc serialize*(cookiejar: CookieJar, location: URL): string =
  if not cookiejar.filter.match(location):
    return "" # fail
  let t = now().toTime().toUnix()
  for i in countdown(cookiejar.cookies.high, 0):
    let cookie = cookiejar.cookies[i]
    if cookie.expires <= t:
      cookiejar.cookies.delete(i)
    elif cookie.domain == "" or location.host.endsWith(cookie.domain):
      result.percentEncode(cookie.name, UserInfoPercentEncodeSet)
      result &= "="
      result.percentEncode(cookie.value, UserInfoPercentEncodeSet)
      result &= ";"

proc newCookie*(str: string): Cookie {.jsctor.} =
  let cookie = new(Cookie)
  var first = true
  for part in str.split(';'):
    if first:
      cookie.name = part.until('=')
      cookie.value = part.after('=')
      first = false
      continue
    let part = percentDecode(part).strip(leading = true, trailing = false, AsciiWhitespace)
    var n = 0
    for i in 0..part.high:
      if part[i] == '=':
        n = i
        break
    if n == 0:
      continue
    let key = part.substr(0, n - 1)
    let val = part.substr(n + 1)
    case key.toLower()
    of "expires":
      let date = parseCookieDate(val)
      if date.issome:
        cookie.expires = date.get.toTime().toUnix()
    of "max-age":
      cookie.expires = now().toTime().toUnix() + parseInt64(val)
    of "secure": cookie.secure = true
    of "httponly": cookie.httponly = true
    of "samesite": cookie.samesite = true
    of "path": cookie.path = val
    of "domain": cookie.domain = val
  return cookie

proc newCookieJar*(location: URL, allowhosts: seq[Regex]): CookieJar =
  return CookieJar(
    filter: newURLFilter(
      scheme = some(location.scheme),
      allowhost = some(location.host),
      allowhosts = some(allowhosts)
    )
  )

proc addCookieModule*(ctx: JSContext) =
  ctx.registerType(Cookie)
