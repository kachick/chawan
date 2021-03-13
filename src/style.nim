import enums
import unicode

type
  CSS2Properties* = ref object
    rawtext*: string
    fmttext*: seq[string]
    x*: int
    y*: int
    ex*: int
    ey*: int
    width*: int
    height*: int
    hidden*: bool
    before*: CSS2Properties
    after*: CSS2Properties
    margintop*: int
    marginbottom*: int
    marginleft*: int
    marginright*: int
    margin*: int
    centered*: bool
    display*: DisplayType
    bold*: bool
    italic*: bool
    underscore*: bool
    islink*: bool
    selected*: bool
    indent*: int

  CSSToken* = object
    case tokenType*: CSSTokenType
    of CSS_IDENT_TOKEN, CSS_FUNCTION_TOKEN, CSS_AT_KEYWORD_TOKEN,
       CSS_HASH_TOKEN, CSS_STRING_TOKEN, CSS_URL_TOKEN:
      value*: seq[Rune]
      tflaga*: bool #id / unrestricted
    of CSS_DELIM_TOKEN:
      rvalue*: Rune
    of CSS_NUMBER_TOKEN, CSS_PERCENTAGE_TOKEN, CSS_DIMENSION_TOKEN:
      ivalue*: int
      tflagb*: bool #integer / number
    else: discard
