import algorithm
import os
import strutils
import tables

type Charset* = enum
  CHARSET_UNKNOWN
  CHARSET_UTF_8 = "UTF-8"
  CHARSET_IBM866 = "IBM866"
  CHARSET_ISO_8859_2 = "ISO-8859-2"
  CHARSET_ISO_8859_3 = "ISO-8859-3"
  CHARSET_ISO_8859_4 = "ISO-8859-4"
  CHARSET_ISO_8859_5 = "ISO-8859-5"
  CHARSET_ISO_8859_6 = "ISO-8859-6"
  CHARSET_ISO_8859_7 = "ISO-8859-7"
  CHARSET_ISO_8859_8 = "ISO-8859-8"
  CHARSET_ISO_8859_8_I = "ISO-8859-8-I"
  CHARSET_ISO_8859_10 = "ISO-8859-10"
  CHARSET_ISO_8859_13 = "ISO-8859-13"
  CHARSET_ISO_8859_14 = "ISO-8859-14"
  CHARSET_ISO_8859_15 = "ISO-8859-15"
  CHARSET_ISO_8859_16 = "ISO-8859-16"
  CHARSET_KOI8_R = "KOI8-R"
  CHARSET_KOI8_U = "KOI8-U"
  CHARSET_MACINTOSH = "macintosh"
  CHARSET_WINDOWS_874 = "windows-874"
  CHARSET_WINDOWS_1250 = "windows-1250"
  CHARSET_WINDOWS_1251 = "windows-1251"
  CHARSET_WINDOWS_1252 = "windows-1252"
  CHARSET_WINDOWS_1253 = "windows-1253"
  CHARSET_WINDOWS_1254 = "windows-1254"
  CHARSET_WINDOWS_1255 = "windows-1255"
  CHARSET_WINDOWS_1256 = "windows-1256"
  CHARSET_WINDOWS_1257 = "windows-1257"
  CHARSET_WINDOWS_1258 = "windows-1258"
  CHARSET_X_MAC_CYRILLIC = "x-mac-cyrillic"
  CHARSET_GBK = "GBK"
  CHARSET_GB18030 = "gb18030"
  CHARSET_BIG5 = "Big5"
  CHARSET_EUC_JP = "EUC-JP"
  CHARSET_ISO_2022_JP = "ISO-2022-JP"
  CHARSET_SHIFT_JIS = "Shift_JIS"
  CHARSET_EUC_KR = "EUC-KR"
  CHARSET_REPLACEMENT = "replacement"
  CHARSET_UTF_16_BE = "UTF-16BE"
  CHARSET_UTF_16_LE = "UTF-16LE"
  CHARSET_X_USER_DEFINED = "x-user-defined"

const CharsetMap = {
  # UTF-8 (The Encoding)
  "unicode-1-1-utf-8": CHARSET_UTF_8,
  "unicode11utf-8": CHARSET_UTF_8,
  "unicode20utf-8": CHARSET_UTF_8,
  "utf-8": CHARSET_UTF_8,
  "utf8": CHARSET_UTF_8,
  "x-unicode20utf8": CHARSET_UTF_8,
  # IBM866
  "866": CHARSET_IBM_866,
  "cp866": CHARSET_IBM_866,
  "csibm866": CHARSET_IBM_866,
  "ibm866": CHARSET_IBM_866,
  # ISO-8859-2
  "csisolatin2": CHARSET_ISO_8859_2,
  "iso-8859-2": CHARSET_ISO_8859_2,
  "iso-ir-101": CHARSET_ISO_8859_2,
  "iso8859-2": CHARSET_ISO_8859_2,
  "iso88592": CHARSET_ISO_8859_2,
  "iso_8859-2": CHARSET_ISO_8859_2,
  "iso_8859-2:1987": CHARSET_ISO_8859_2,
  "l2": CHARSET_ISO_8859_2,
  "latin2": CHARSET_ISO_8859_2,
  # ISO-8859-3
  "csisolatin3": CHARSET_ISO_8859_3,
  "iso-8859-3": CHARSET_ISO_8859_3,
  "iso-ir-109": CHARSET_ISO_8859_3,
  "iso8859-3": CHARSET_ISO_8859_3,
  "iso88593": CHARSET_ISO_8859_3,
  "iso_8859-3": CHARSET_ISO_8859_3,
  "iso_8859-3:1988": CHARSET_ISO_8859_3,
  "l3": CHARSET_ISO_8859_3,
  "latin3": CHARSET_ISO_8859_3,
  # ISO-8859-4
  "csisolatin4": CHARSET_ISO_8859_4,
  "iso-8859-4": CHARSET_ISO_8859_4,
  "iso-ir-110": CHARSET_ISO_8859_4,
  "iso8859-4": CHARSET_ISO_8859_4,
  "iso88594": CHARSET_ISO_8859_4,
  "iso_8859-4": CHARSET_ISO_8859_4,
  "iso_8859-4:1988": CHARSET_ISO_8859_4,
  "l4": CHARSET_ISO_8859_4,
  "latin4": CHARSET_ISO_8859_4,
  # ISO-8859-5
  "csisolatincyrillic": CHARSET_ISO_8859_5,
  "cyrillic": CHARSET_ISO_8859_5,
  "iso-8859-5": CHARSET_ISO_8859_5,
  "iso-ir-144": CHARSET_ISO_8859_5,
  "iso8859-5": CHARSET_ISO_8859_5,
  "iso88595": CHARSET_ISO_8859_5,
  "iso_8859-5": CHARSET_ISO_8859_5,
  "iso_8859-5:1988": CHARSET_ISO_8859_5,
  # ISO-8859-6
  "arabic": CHARSET_ISO_8859_6,
  "asmo-708": CHARSET_ISO_8859_6,
  "csiso88596e": CHARSET_ISO_8859_6,
  "csiso88596i": CHARSET_ISO_8859_6,
  "csisolatinarabic": CHARSET_ISO_8859_6,
  "ecma-114": CHARSET_ISO_8859_6,
  "iso-8859-6": CHARSET_ISO_8859_6,
  "iso-8859-6-e": CHARSET_ISO_8859_6,
  "iso-8859-6-i": CHARSET_ISO_8859_6,
  "iso-ir-127": CHARSET_ISO_8859_6,
  "iso8859-6": CHARSET_ISO_8859_6,
  "iso88596": CHARSET_ISO_8859_6,
  "iso_8859-6": CHARSET_ISO_8859_6,
  "iso_8859-6:1987": CHARSET_ISO_8859_6,
  # ISO-8859-7
  "csisolatingreek": CHARSET_ISO_8859_7,
  "ecma-118": CHARSET_ISO_8859_7,
  "elot_928": CHARSET_ISO_8859_7,
  "greek": CHARSET_ISO_8859_7,
  "greek8": CHARSET_ISO_8859_7,
  "iso-8859-7": CHARSET_ISO_8859_7,
  "iso-ir-126": CHARSET_ISO_8859_7,
  "iso8859-7": CHARSET_ISO_8859_7,
  "iso88597": CHARSET_ISO_8859_7,
  "iso_8859-7": CHARSET_ISO_8859_7,
  "iso_8859-7:1987": CHARSET_ISO_8859_7,
  "sun_eu_greek": CHARSET_ISO_8859_7,
  # ISO-8859-8
  "csiso88598e": CHARSET_ISO_8859_8,
  "csisolatinhebrew": CHARSET_ISO_8859_8,
  "hebrew": CHARSET_ISO_8859_8,
  "iso-8859-8": CHARSET_ISO_8859_8,
  "iso-8859-8-e": CHARSET_ISO_8859_8,
  "iso-ir-138": CHARSET_ISO_8859_8,
  "iso8859-8": CHARSET_ISO_8859_8,
  "iso88598": CHARSET_ISO_8859_8,
  "iso_8859-8": CHARSET_ISO_8859_8,
  "iso_8859-8:1988": CHARSET_ISO_8859_8,
  "visual": CHARSET_ISO_8859_8,
  # ISO-8859-8-I
  "csiso88598i": CHARSET_ISO_8859_8_I,
  "iso-8859-8-i": CHARSET_ISO_8859_8_I,
  "logical": CHARSET_ISO_8859_8_I,
  # ISO-8859-10
  "csisolatin6": CHARSET_ISO_8859_10,
  "iso-8859-10": CHARSET_ISO_8859_10,
  "iso-ir-157": CHARSET_ISO_8859_10,
  "iso8859-10": CHARSET_ISO_8859_10,
  "iso885910": CHARSET_ISO_8859_10,
  "l6": CHARSET_ISO_8859_10,
  "latin6": CHARSET_ISO_8859_10,
  # ISO-8859-13
  "iso-8859-13": CHARSET_ISO_8859_13,
  "iso8859-13": CHARSET_ISO_8859_13,
  "iso885913": CHARSET_ISO_8859_13,
  # ISO-8859-14
  "iso-8859-14": CHARSET_ISO_8859_14,
  "iso8859-14": CHARSET_ISO_8859_14,
  "iso885914": CHARSET_ISO_8859_14,
  # ISO-8859-15
  "csisolatin9": CHARSET_ISO_8859_15,
  "iso-8859-15": CHARSET_ISO_8859_15,
  "iso8859-15": CHARSET_ISO_8859_15,
  "iso885915": CHARSET_ISO_8859_15,
  "iso_8859-15": CHARSET_ISO_8859_15,
  "l9": CHARSET_ISO_8859_15,
  # ISO-8859-16
  "iso-8859-16": CHARSET_ISO_8859_16,
  # KOI8-R
  "cskoi8r": CHARSET_KOI8_R,
  "koi": CHARSET_KOI8_R,
  "koi8": CHARSET_KOI8_R,
  "koi8-r": CHARSET_KOI8_R,
  "koi8_r": CHARSET_KOI8_R,
  # KOI8-U
  "koi8-ru": CHARSET_KOI8_U,
  "koi8-u": CHARSET_KOI8_U,
  # macintosh
  "csmacintosh": CHARSET_MACINTOSH,
  "mac": CHARSET_MACINTOSH,
  "macintosh": CHARSET_MACINTOSH,
  "x-mac-roman": CHARSET_MACINTOSH,
  # windows-874
  "dos-874": CHARSET_WINDOWS_874,
  "iso-8859-11": CHARSET_WINDOWS_874,
  "iso8859-11": CHARSET_WINDOWS_874,
  "iso885911": CHARSET_WINDOWS_874,
  "tis-620": CHARSET_WINDOWS_874,
  "windows-874": CHARSET_WINDOWS_874,
  # windows-1250
  "cp1250": CHARSET_WINDOWS_1250,
  "windows-1250": CHARSET_WINDOWS_1250,
  "x-cp1250" : CHARSET_WINDOWS_1250,
  # windows-1251
  "cp1251": CHARSET_WINDOWS_1251,
  "windows-1251": CHARSET_WINDOWS_1251,
  "x-cp1251": CHARSET_WINDOWS_1251,
  # windows-1252
  "ansi_x3.4-1968": CHARSET_WINDOWS_1252,
  "ascii": CHARSET_WINDOWS_1252, # lol
  "cp1252": CHARSET_WINDOWS_1252,
  "cp819": CHARSET_WINDOWS_1252,
  "csisolatin1": CHARSET_WINDOWS_1252,
  "ibm819": CHARSET_WINDOWS_1252,
  "iso-8859-1": CHARSET_WINDOWS_1252,
  "iso88591": CHARSET_WINDOWS_1252,
  "iso_8859-1:1987": CHARSET_WINDOWS_1252,
  "l1": CHARSET_WINDOWS_1252,
  "latin1": CHARSET_WINDOWS_1252,
  "us-ascii": CHARSET_WINDOWS_1252,
  "windows-1252": CHARSET_WINDOWS_1252,
  "x-cp1252": CHARSET_WINDOWS_1252,
  # windows-1253
  "cp1253": CHARSET_WINDOWS_1253,
  "windows-1253": CHARSET_WINDOWS_1253,
  "x-cp1253": CHARSET_WINDOWS_1253,
  # windows-1254
  "cp1254": CHARSET_WINDOWS_1254,
  "csisolatin5": CHARSET_WINDOWS_1254,
  "iso-8859-9": CHARSET_WINDOWS_1254,
  "iso-ir-148": CHARSET_WINDOWS_1254,
  "iso8859-9": CHARSET_WINDOWS_1254,
  "iso88599": CHARSET_WINDOWS_1254,
  "iso_8859-9": CHARSET_WINDOWS_1254,
  "iso_8859-9:1989": CHARSET_WINDOWS_1254,
  "l5": CHARSET_WINDOWS_1254,
  "latin5": CHARSET_WINDOWS_1254,
  "windows-1254": CHARSET_WINDOWS_1254,
  "x-cp1254": CHARSET_WINDOWS_1254,
  # windows-1255
  "cp1255": CHARSET_WINDOWS_1255,
  "windows-1255": CHARSET_WINDOWS_1255,
  "x-cp1255": CHARSET_WINDOWS_1255,
  # windows-1256
  "cp1256": CHARSET_WINDOWS_1256,
  "windows-1256": CHARSET_WINDOWS_1256,
  "x-cp1256": CHARSET_WINDOWS_1256,
  # windows-1257
  "cp1257": CHARSET_WINDOWS_1257,
  "windows-1257": CHARSET_WINDOWS_1257,
  "x-cp1257": CHARSET_WINDOWS_1257,
  # windows-1258
  "cp1258": CHARSET_WINDOWS_1258,
  "windows-1258": CHARSET_WINDOWS_1258,
  "x-cp1258": CHARSET_WINDOWS_1258,
  # x-mac-cyrillic
  "x-mac-cyrillic": CHARSET_X_MAC_CYRILLIC,
  "x-mac-ukrainian": CHARSET_X_MAC_CYRILLIC,
  # GBK
  "chinese": CHARSET_GBK,
  "csgb2312": CHARSET_GBK,
  "csiso58gb231280": CHARSET_GBK,
  "gb2312": CHARSET_GBK,
  "gb_2312": CHARSET_GBK,
  "gb_2312-80": CHARSET_GBK,
  "gbk": CHARSET_GBK,
  "iso-ir-58": CHARSET_GBK,
  "x-gbk": CHARSET_GBK,
  # gb18030
  "gb18030": CHARSET_GB18030,
  # Big5
  "big5": CHARSET_BIG5,
  "big5-hkscs": CHARSET_BIG5,
  "cn-big5": CHARSET_BIG5,
  "csbig5": CHARSET_BIG5,
  "x-x-big5": CHARSET_BIG5,
  # EUC-JP
  "cseucpkdfmtjapanese": CHARSET_EUC_JP,
  "euc-jp": CHARSET_EUC_JP,
  "x-euc-jp": CHARSET_EUC_JP,
  # ISO-2022-JP (ugh)
  "csiso2022jp": CHARSET_ISO_2022_JP,
  "iso-2022-jp": CHARSET_ISO_2022_JP,
  # Shift_JIS
  "csshiftjis": CHARSET_SHIFT_JIS,
  "ms932": CHARSET_SHIFT_JIS,
  "ms_kanji": CHARSET_SHIFT_JIS,
  "shift-jis": CHARSET_SHIFT_JIS,
  "shift_jis": CHARSET_SHIFT_JIS,
  "sjis": CHARSET_SHIFT_JIS,
  "windows-31j": CHARSET_SHIFT_JIS,
  "x-sjis": CHARSET_SHIFT_JIS,
  # EUC-KR
  "cseuckr": CHARSET_EUC_KR,
  "csksc56011987": CHARSET_EUC_KR,
  "euc-kr": CHARSET_EUC_KR,
  "iso-ir-149": CHARSET_EUC_KR,
  "korean": CHARSET_EUC_KR,
  "ks_c_5601-1987": CHARSET_EUC_KR,
  "ks_c_5601-1989": CHARSET_EUC_KR,
  "ksc5601": CHARSET_EUC_KR,
  "ksc_5601": CHARSET_EUC_KR,
  "windows-949": CHARSET_EUC_KR,
  # replacement
  "csiso2022kr": CHARSET_REPLACEMENT,
  "hz-gb-2312": CHARSET_REPLACEMENT,
  "iso-2022-cn": CHARSET_REPLACEMENT,
  "iso-2022-cn-ext": CHARSET_REPLACEMENT,
  "iso-2022-kr": CHARSET_REPLACEMENT,
  "replacement": CHARSET_REPLACEMENT,
  # UTF-16BE
  "unicodefffe": CHARSET_UTF_16_BE,
  "utf-16be": CHARSET_UTF_16_BE,
  # UTF-16LE
  "csunicode": CHARSET_UTF_16_LE,
  "iso-10646-ucs-2": CHARSET_UTF_16_LE,
  "ucs-2": CHARSET_UTF_16_LE,
  "unicode": CHARSET_UTF_16_LE,
  "unicodefeff": CHARSET_UTF_16_LE,
  "utf-16": CHARSET_UTF_16_LE,
  "utf-16le": CHARSET_UTF_16_LE,
  # x-user-defined
  "x-user-defined": CHARSET_X_USER_DEFINED
}.toTable()

proc getCharset*(s: string): Charset =
  return CharsetMap.getOrDefault(s.strip().toLower(), CHARSET_UNKNOWN)

iterator mappairs(path: string): tuple[a, b: int] =
  let s = staticRead(path)
  for line in s.split('\n'):
    if line.len == 0 or line[0] == '#': continue
    var i = 0
    while line[i] == ' ': inc i
    var j = i
    while i < line.len and line[i] in '0'..'9': inc i
    let index = parseInt(line.substr(j, i - 1))
    inc i # tab
    j = i
    while i < line.len and line[i] in {'0'..'9', 'A'..'F', 'x'}: inc i
    let n = parseHexInt(line.substr(j, i - 1))
    yield (index, n)

# I'm pretty sure single-byte encodings map to ucs-2.
func loadCharsetMap8(path: string): tuple[
      decode: array[char, uint16],
      encode: seq[
        tuple[
          ucs: uint16,
          val: char
        ]
      ],
    ] =
  var m: int
  for index, n in mappairs("res/map" / path):
    result.decode[char(index)] = uint16(n)
    if index > m: m = index
  for index in low(char) .. char(m):
    let val = result.decode[index] 
    if val != 0u16:
      result.encode.add((val, index))
  result.encode.sort()

func loadCharsetMap8Encode(path: string): seq[tuple[ucs: uint16, val: char]] =
  for index, n in mappairs("res/map" / path):
    result.add((uint16(n), char(index)))
  result.sort()

func loadGb18030Ranges(path: string): tuple[
        decode: seq[
          tuple[
            p: uint16,
            ucs: uint16 ]],
        encode: seq[
          tuple[
            ucs: uint16,
            p: uint16 ]]] =
  for index, n in mappairs("res/map" / path):
    if uint32(index) > uint32(high(uint16)): break
    result.decode.add((uint16(index), uint16(n)))
    result.encode.add((uint16(n), uint16(index)))
  result.encode.sort()

func loadCharsetMap16(path: string, len: static uint16): tuple[
        decode: array[len, uint16],
        encode: seq[
          tuple[
            ucs: uint16,
            p: uint16 ]]] =
  for index, n in mappairs("res/map" / path):
    result.decode[uint16(index)] = uint16(n)
    result.encode.add((uint16(n), uint16(index)))
  result.encode.sort()

func loadBig5Map(path: string, offset: static uint16): tuple[
        decode: array[19782u16 - offset, uint32], # ouch (+75KB...)
        encode: seq[
          tuple[
            ucs: uint32,
            p: uint16 ]]] =
  for index, n in mappairs("res/map" / path):
    result.decode[uint16(index) - offset] = uint32(n)
    result.encode.add((uint32(n), uint16(index)))
  #for i in result.decode: assert x != 0 # fail
  result.encode.sort()

const (IBM866Decode*, IBM866Encode*) = loadCharsetMap8("index-ibm866.txt")
const (ISO88592Decode*, ISO88592Encode*) = loadCharsetMap8("index-iso-8859-2.txt")
const (ISO88593Decode*, ISO88593Encode*) = loadCharsetMap8("index-iso-8859-3.txt")
const (ISO88594Decode*, ISO88594Encode*) = loadCharsetMap8("index-iso-8859-4.txt")
const (ISO88595Decode*, ISO88595Encode*) = loadCharsetMap8("index-iso-8859-5.txt")
const (ISO88596Decode*, ISO88596Encode*) = loadCharsetMap8("index-iso-8859-6.txt")
const (ISO88597Decode*, ISO88597Encode*) = loadCharsetMap8("index-iso-8859-7.txt")
const (ISO88598Decode*, ISO88598Encode*) = loadCharsetMap8("index-iso-8859-8.txt")
const (ISO885910Decode*, ISO885910Encode*) = loadCharsetMap8("index-iso-8859-10.txt")
const (ISO885913Decode*, ISO885913Encode*) = loadCharsetMap8("index-iso-8859-13.txt")
const (ISO885914Decode*, ISO885914Encode*) = loadCharsetMap8("index-iso-8859-14.txt")
const (ISO885915Decode*, ISO885915Encode*) = loadCharsetMap8("index-iso-8859-15.txt")
const (ISO885916Decode*, ISO885916Encode*) = loadCharsetMap8("index-iso-8859-16.txt")
const (KOI8RDecode*, KOI8REncode*) = loadCharsetMap8("index-koi8-r.txt")
const (KOI8UDecode*, KOI8UEncode*) = loadCharsetMap8("index-koi8-u.txt")
const (MacintoshDecode*, MacintoshEncode*) = loadCharsetMap8("index-macintosh.txt")
const (Windows874Decode*, Windows874Encode*) = loadCharsetMap8("index-windows-874.txt")
const (Windows1250Decode*, Windows1250Encode*) = loadCharsetMap8("index-windows-1250.txt")
const (Windows1251Decode*, Windows1251Encode*) = loadCharsetMap8("index-windows-1251.txt")
const (Windows1252Decode*, Windows1252Encode*) = loadCharsetMap8("index-windows-1252.txt")
const (Windows1253Decode*, Windows1253Encode*) = loadCharsetMap8("index-windows-1253.txt")
const (Windows1254Decode*, Windows1254Encode*) = loadCharsetMap8("index-windows-1254.txt")
const (Windows1255Decode*, Windows1255Encode*) = loadCharsetMap8("index-windows-1255.txt")
const (Windows1256Decode*, Windows1256Encode*) = loadCharsetMap8("index-windows-1256.txt")
const (Windows1257Decode*, Windows1257Encode*) = loadCharsetMap8("index-windows-1257.txt")
const (Windows1258Decode*, Windows1258Encode*) = loadCharsetMap8("index-windows-1258.txt")
const (XMacCyrillicDecode*, XMacCyrillicEncode*) = loadCharsetMap8("index-x-mac-cyrillic.txt")
const (Gb18030RangesDecode*, Gb18030RangesEncode*) = loadGb18030Ranges("index-gb18030-ranges.txt")
const (Gb18030Decode*, Gb18030Encode*) = loadCharsetMap16("index-gb18030.txt", len = 23940)
#for x in Gb18030Decode: assert x != 0 # success
const Big5DecodeOffset* = 942
const (Big5Decode*, Big5Encode*) = loadBig5Map("index-big5.txt", offset = Big5DecodeOffset)
const (Jis0208Decode*, Jis0208Encode*) = loadCharsetMap16("index-jis0208.txt", len = 11104)
const (Jis0212Decode*, Jis0212Encode*) = loadCharsetMap16("index-jis0212.txt", len = 7211)
const ISO2022JPKatakanaEncode* = loadCharsetMap8Encode("index-iso-2022-jp-katakana.txt")
const (EUCKRDecode*, EUCKREncode*) = loadCharsetMap16("index-euc-kr.txt", len = 23750)