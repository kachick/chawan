import macros
import options
import sequtils
import streams
import strformat
import tables
import unicode

import utils/twtstr
import html/dom
import html/tags
import html/htmltokenizer
import css/sheet

type
  HTML5Parser = object
    case fragment: bool
    of true: ctx: Element
    else: discard
    openElements: seq[Element]
    insertionMode: InsertionMode
    oldInsertionMode: InsertionMode
    templateModes: seq[InsertionMode]
    head: Element
    tokenizer: Tokenizer
    document: Document
    form: HTMLFormElement
    fosterParenting: bool
    scripting: bool
    activeFormatting: seq[(Element, Token)] # nil => marker
    framesetok: bool
    ignoreLF: bool
    pendingTableChars: string
    pendingTableCharsWhitespace: bool

  AdjustedInsertionLocation = tuple[inside: Node, before: Node]

# 13.2.4.1
  InsertionMode = enum
    INITIAL, BEFORE_HTML, BEFORE_HEAD, IN_HEAD, IN_HEAD_NOSCRIPT, AFTER_HEAD,
    IN_BODY, TEXT, IN_TABLE, IN_TABLE_TEXT, IN_CAPTION, IN_COLUMN_GROUP,
    IN_TABLE_BODY, IN_ROW, IN_CELL, IN_SELECT, IN_SELECT_IN_TABLE, IN_TEMPLATE,
    AFTER_BODY, IN_FRAMESET, AFTER_FRAMESET, AFTER_AFTER_BODY,
    AFTER_AFTER_FRAMESET

proc resetInsertionMode(parser: var HTML5Parser) =
  template switch_insertion_mode_and_return(mode: InsertionMode) =
    parser.insertionMode = mode
    return
  for i in countdown(parser.openElements.high, 0):
    var node = parser.openElements[i]
    let last = i == 0
    if parser.fragment:
      node = parser.ctx
    if node.tagType == TAG_SELECT:
      if not last:
        for j in countdown(parser.openElements.high, 1):
          let ancestor = parser.openElements[j]
          case ancestor.tagType
          of TAG_TEMPLATE: break
          of TAG_TABLE: switch_insertion_mode_and_return IN_SELECT_IN_TABLE
          else: discard
      switch_insertion_mode_and_return IN_SELECT
    case node.tagType
    of TAG_TD, TAG_TH:
      if not last:
        switch_insertion_mode_and_return IN_CELL
    of TAG_TR: switch_insertion_mode_and_return IN_ROW
    of TAG_TBODY, TAG_THEAD, TAG_TFOOT: switch_insertion_mode_and_return IN_CAPTION
    of TAG_COLGROUP: switch_insertion_mode_and_return IN_COLUMN_GROUP
    of TAG_TABLE: switch_insertion_mode_and_return IN_TABLE
    of TAG_TEMPLATE: switch_insertion_mode_and_return parser.templateModes[^1]
    of TAG_HEAD:
      if not last:
        switch_insertion_mode_and_return IN_HEAD
    of TAG_BODY: switch_insertion_mode_and_return IN_BODY
    of TAG_FRAMESET: switch_insertion_mode_and_return IN_FRAMESET
    of TAG_HTML:
      if parser.head != nil:
        switch_insertion_mode_and_return BEFORE_HEAD
      else:
        switch_insertion_mode_and_return AFTER_HEAD
    else: discard
    if last:
      switch_insertion_mode_and_return IN_BODY

func currentNode(parser: HTML5Parser): Element =
  if parser.openElements.len == 0:
    assert false
  else:
    return parser.openElements[^1]

func adjustedCurrentNode(parser: HTML5Parser): Element =
  if parser.fragment: parser.ctx
  else: parser.currentNode

template parse_error() = discard

func lastElementOfTag(parser: HTML5Parser, tagType: TagType): tuple[element: Element, pos: int] =
  for i in countdown(parser.openElements.high, 0):
    if parser.openElements[i].tagType == tagType:
      return (parser.openElements[i], i)
  return (nil, -1)

template last_child_of(n: Node): AdjustedInsertionLocation =
  (n, nil)

# 13.2.6.1
func appropriatePlaceForInsert(parser: HTML5Parser, target: Element): AdjustedInsertionLocation =
  assert parser.openElements[0].tagType == TAG_HTML
  if parser.fosterParenting and target.tagType in {TAG_TABLE, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR}:
    let lastTemplate = parser.lastElementOfTag(TAG_TEMPLATE)
    let lastTable = parser.lastElementOfTag(TAG_TABLE)
    if lastTemplate.element != nil and (lastTable.element == nil or lastTable.pos < lastTemplate.pos):
      return last_child_of(HTMLTemplateElement(lastTemplate.element).content)
    if lastTable.element == nil:
      return last_child_of(parser.openElements[0])
    if lastTable.element.parentNode != nil:
      return (lastTable.element.parentNode, lastTable.element)
    let previousElement = parser.openElements[lastTable.pos - 1]
    result = last_child_of(previousElement)
  else:
    result = last_child_of(target)
  if result.inside.nodeType == ELEMENT_NODE and Element(result.inside).tagType == TAG_TEMPLATE:
    result = (HTMLTemplateElement(result.inside).content, nil)

func appropriatePlaceForInsert(parser: HTML5Parser): AdjustedInsertionLocation =
  parser.appropriatePlaceForInsert(parser.currentNode)

func hasElement(elements: seq[Element], tag: TagType): bool =
  for element in elements:
    if element.tagType == tag:
      return true
  return false

func hasElementInSpecificScope(elements: seq[Element], target: Element, list: set[TagType]): bool =
  for i in countdown(elements.high, 0):
    if elements[i] == target:
      return true
    if elements[i].tagType in list:
      return false
  assert false

func hasElementInSpecificScope(elements: seq[Element], target: TagType, list: set[TagType]): bool =
  for i in countdown(elements.high, 0):
    if elements[i].tagType == target:
      return true
    if elements[i].tagType in list:
      return false
  assert false

func hasElementInSpecificScope(elements: seq[Element], target: set[TagType], list: set[TagType]): bool =
  for i in countdown(elements.high, 0):
    if elements[i].tagType in target:
      return true
    if elements[i].tagType in list:
      return false
  assert false

const Scope = {TAG_APPLET, TAG_CAPTION, TAG_HTML, TAG_TABLE, TAG_TD, TAG_TH,
               TAG_MARQUEE, TAG_OBJECT, TAG_TEMPLATE} #TODO SVG (NOTE MathML not implemented)
func hasElementInScope(elements: seq[Element], target: TagType): bool =
  return elements.hasElementInSpecificScope(target, Scope)

func hasElementInScope(elements: seq[Element], target: set[TagType]): bool =
  return elements.hasElementInSpecificScope(target, Scope)

func hasElementInScope(elements: seq[Element], target: Element): bool =
  return elements.hasElementInSpecificScope(target, Scope)

func hasElementInListItemScope(elements: seq[Element], target: TagType): bool =
  return elements.hasElementInSpecificScope(target, Scope + {TAG_OL, TAG_UL})

func hasElementInButtonScope(elements: seq[Element], target: TagType): bool =
  return elements.hasElementInSpecificScope(target, Scope + {TAG_BUTTON})

func hasElementInTableScope(elements: seq[Element], target: TagType): bool =
  return elements.hasElementInSpecificScope(target, {TAG_HTML, TAG_TABLE, TAG_TEMPLATE})

func hasElementInTableScope(elements: seq[Element], target: set[TagType]): bool =
  return elements.hasElementInSpecificScope(target, {TAG_HTML, TAG_TABLE, TAG_TEMPLATE})

func hasElementInSelectScope(elements: seq[Element], target: TagType): bool =
  for i in countdown(elements.high, 0):
    if elements[i].tagType == target:
      return true
    if elements[i].tagType notin {TAG_OPTION, TAG_OPTGROUP}:
      return false
  assert false

func createElement(parser: HTML5Parser, token: Token, namespace: Namespace, intendedParent: Node): Element =
  #TODO custom elements
  let document = intendedParent.document
  let localName = token.tagname
  let element = document.newHTMLElement(localName, namespace, tagType = token.tagtype)
  for k, v in token.attrs:
    element.appendAttribute(k, v)
  if element.isResettable():
    element.reset()

  if element.tagType in FormAssociatedElements and parser.form != nil and
      not parser.openElements.hasElement(TAG_TEMPLATE) and
      (element.tagType notin ListedElements or not element.attrb("form")) and
      intendedParent.inSameTree(parser.form):
    element.setForm(parser.form)
  return element

proc insert(location: AdjustedInsertionLocation, node: Node) =
  location.inside.insert(node, location.before)

proc insertForeignElement(parser: var HTML5Parser, token: Token, namespace: Namespace): Element =
  let location = parser.appropriatePlaceForInsert()
  let element = parser.createElement(token, namespace, location.inside)
  if location.inside.preInsertionValidity(element, location.before):
    #TODO custom elements
    location.insert(element)
  parser.openElements.add(element)
  return element

proc insertHTMLElement(parser: var HTML5Parser, token: Token): Element =
  return parser.insertForeignElement(token, Namespace.HTML)

proc adjustSVGAttributes(token: var Token) =
  const adjusted = {
    "attributename": "attributeName",
    "attributetype": "attributeType",
    "basefrequency": "baseFrequency",
    "baseprofile": "baseProfile",
    "calcmode": "calcMode",
    "clippathunits": "clipPathUnits",
    "diffuseconstant": "diffuseConstant",
    "edgemode": "edgeMode",
    "filterunits": "filterUnits",
    "glyphref": "glyphRef",
    "gradienttransform": "gradientTransform",
    "gradientunits": "gradientUnits",
    "kernelmatrix": "kernelMatrix",
    "kernelunitlength": "kernelUnitLength",
    "keypoints": "keyPoints",
    "keysplines": "keySplines",
    "keytimes": "keyTimes",
    "lengthadjust": "lengthAdjust",
    "limitingconeangle": "limitingConeAngle",
    "markerheight": "markerHeight",
    "markerunits": "markerUnits",
    "markerwidth": "markerWidth",
    "maskcontentunits": "maskContentUnits",
    "maskunits": "maskUnits",
    "numoctaves": "numOctaves",
    "pathlength": "pathLength",
    "patterncontentunits": "patternContentUnits",
    "patterntransform": "patternTransform",
    "patternunits": "patternUnits",
    "pointsatx": "pointsAtX",
    "pointsaty": "pointsAtY",
    "pointsatz": "pointsAtZ",
    "preservealpha": "preserveAlpha",
    "preserveaspectratio": "preserveAspectRatio",
    "primitiveunits": "primitiveUnits",
    "refx": "refX",
    "refy": "refY",
    "repeatcount": "repeatCount",
    "repeatdur": "repeatDur",
    "requiredextensions": "requiredExtensions",
    "requiredfeatures": "requiredFeatures",
    "specularconstant": "specularConstant",
    "specularexponent": "specularExponent",
    "spreadmethod": "spreadMethod",
    "startoffset": "startOffset",
    "stddeviation": "stdDeviation",
    "stitchtiles": "stitchTiles",
    "surfacescale": "surfaceScale",
    "systemlanguage": "systemLanguage",
    "tablevalues": "tableValues",
    "targetx": "targetX",
    "targety": "targetY",
    "textlength": "textLength",
    "viewbox": "viewBox",
    "viewtarget": "viewTarget",
    "xchannelselector": "xChannelSelector",
    "ychannelselector": "yChannelSelector",
    "zoomandpan": "zoomAndPan",
  }.toTable()
  var todo: seq[string]
  for k in token.attrs.keys:
    if k in adjusted:
      todo.add(k)
  for s in todo:
    token.attrs[adjusted[s]] = token.attrs[s]

template insert_character_impl(parser: var HTML5Parser, data: typed) =
  let location = parser.appropriatePlaceForInsert()
  if location.inside.nodeType == DOCUMENT_NODE:
    return
  let insertNode = if location.before == nil:
    location.inside.lastChild
  else:
    location.before.previousSibling
  assert location.before == nil
  if insertNode != nil and insertNode.nodeType == TEXT_NODE:
    dom.Text(insertNode).data &= data
  else:
    let text = location.inside.document.newText($data)
    location.insert(text)

  if location.inside.nodeType == ELEMENT_NODE:
    let parent = Element(location.inside)
    if parent.tagType == TAG_STYLE:
      let parent = HTMLStyleElement(parent)
      parent.sheet_invalid = true

proc insertCharacter(parser: var HTML5Parser, data: string) =
  insert_character_impl(parser, data)

proc insertCharacter(parser: var HTML5Parser, data: char) =
  insert_character_impl(parser, data)

proc insertCharacter(parser: var HTML5Parser, data: Rune) =
  insert_character_impl(parser, data)

proc insertComment(parser: var HTML5Parser, token: Token, position: AdjustedInsertionLocation) =
  position.insert(position.inside.document.newComment(token.data))

proc insertComment(parser: var HTML5Parser, token: Token) =
  let position = parser.appropriatePlaceForInsert()
  position.insert(position.inside.document.newComment(token.data))

const PublicIdentifierEquals = [
  "-//W3O//DTD W3 HTML Strict 3.0//EN//",
  "-/W3C/DTD HTML 4.0 Transitional/EN",
  "HTML" 
]

const PublicIdentifierStartsWith = [
  "+//Silmaril//dtd html Pro v0r11 19970101//",
  "-//AS//DTD HTML 3.0 asWedit + extensions//",
  "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
  "-//IETF//DTD HTML 2.0 Level 1//",
  "-//IETF//DTD HTML 2.0 Level 2//",
  "-//IETF//DTD HTML 2.0 Strict Level 1//",
  "-//IETF//DTD HTML 2.0 Strict Level 2//",
  "-//IETF//DTD HTML 2.0 Strict//",
  "-//IETF//DTD HTML 2.0//",
  "-//IETF//DTD HTML 2.1E//",
  "-//IETF//DTD HTML 3.0//",
  "-//IETF//DTD HTML 3.2 Final//",
  "-//IETF//DTD HTML 3.2//",
  "-//IETF//DTD HTML 3//",
  "-//IETF//DTD HTML Level 0//",
  "-//IETF//DTD HTML Level 1//",
  "-//IETF//DTD HTML Level 2//",
  "-//IETF//DTD HTML Level 3//",
  "-//IETF//DTD HTML Strict Level 0//",
  "-//IETF//DTD HTML Strict Level 1//",
  "-//IETF//DTD HTML Strict Level 2//",
  "-//IETF//DTD HTML Strict Level 3//",
  "-//IETF//DTD HTML Strict//",
  "-//IETF//DTD HTML//",
  "-//Metrius//DTD Metrius Presentational//",
  "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
  "-//Microsoft//DTD Internet Explorer 2.0 HTML//",
  "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
  "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
  "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
  "-//Microsoft//DTD Internet Explorer 3.0 Tables//",
  "-//Netscape Comm. Corp.//DTD HTML//",
  "-//Netscape Comm. Corp.//DTD Strict HTML//",
  "-//O'Reilly and Associates//DTD HTML 2.0//",
  "-//O'Reilly and Associates//DTD HTML Extended 1.0//",
  "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
  "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
  "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
  "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
  "-//Spyglass//DTD HTML 2.0 Extended//",
  "-//Sun Microsystems Corp.//DTD HotJava HTML//",
  "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
  "-//W3C//DTD HTML 3 1995-03-24//",
  "-//W3C//DTD HTML 3.2 Draft//",
  "-//W3C//DTD HTML 3.2 Final//",
  "-//W3C//DTD HTML 3.2//",
  "-//W3C//DTD HTML 3.2S Draft//",
  "-//W3C//DTD HTML 4.0 Frameset//",
  "-//W3C//DTD HTML 4.0 Transitional//",
  "-//W3C//DTD HTML Experimental 19960712//",
  "-//W3C//DTD HTML Experimental 970421//",
  "-//W3C//DTD W3 HTML//",
  "-//W3O//DTD W3 HTML 3.0//",
  "-//WebTechs//DTD Mozilla HTML 2.0//",
  "-//WebTechs//DTD Mozilla HTML//", 
]

const SystemIdentifierMissingAndPublicIdentifierStartsWith = [
  "-//W3C//DTD HTML 4.01 Frameset//",
  "-//W3C//DTD HTML 4.01 Transitional//"
]

const PublicIdentifierStartsWithLimited = [
  "-//W3C//DTD XHTML 1.0 Frameset//",
  "-//W3C//DTD XHTML 1.0 Transitional//"
]

const SystemIdentifierNotMissingAndPublicIdentifierStartsWith = [
  "-//W3C//DTD HTML 4.01 Frameset//",
  "-//W3C//DTD HTML 4.01 Transitional//"
]

func quirksConditions(token: Token): bool =
  if token.quirks: return true
  if token.name.isnone or token.name.get != "html": return true
  if token.sysid.issome:
    if token.sysid.get == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd":
      return true
  if token.pubid.issome:
    if token.pubid.get in PublicIdentifierEquals:
      return true
    for id in PublicIdentifierStartsWith:
      if token.pubid.get.startsWithNoCase(id):
        return true
    if token.sysid.isnone:
      for id in SystemIdentifierMissingAndPublicIdentifierStartsWith:
        if token.pubid.get.startsWithNoCase(id):
          return true
  return false

func limitedQuirksConditions(token: Token): bool =
  if token.pubid.isnone: return false
  for id in PublicIdentifierStartsWithLimited:
    if token.pubid.get.startsWithNoCase(id):
      return true
  if token.sysid.isnone: return false
  for id in SystemIdentifierNotMissingAndPublicIdentifierStartsWith:
    if token.pubid.get.startsWithNoCase(id):
      return true
  return false

# 13.2.6.2
proc genericRawtextElementParsingAlgorithm(parser: var HTML5Parser, token: Token) =
  discard parser.insertHTMLElement(token)
  parser.tokenizer.state = RAWTEXT
  parser.oldInsertionMode = parser.insertionMode
  parser.insertionMode = TEXT

proc genericRCDATAElementParsingAlgorithm(parser: var HTML5Parser, token: Token) =
  discard parser.insertHTMLElement(token)
  parser.tokenizer.state = RCDATA
  parser.oldInsertionMode = parser.insertionMode
  parser.insertionMode = TEXT

# 13.2.6.3
proc generateImpliedEndTags(parser: var HTML5Parser) =
  const tags = {TAG_DD, TAG_DT, TAG_LI, TAG_OPTGROUP, TAG_OPTION, TAG_P,
                TAG_RB, TAG_RP, TAG_RT, TAG_RTC}
  while parser.currentNode.tagType in tags:
    discard parser.openElements.pop()

proc generateImpliedEndTags(parser: var HTML5Parser, exclude: TagType) =
  let tags = {TAG_DD, TAG_DT, TAG_LI, TAG_OPTGROUP, TAG_OPTION, TAG_P,
                TAG_RB, TAG_RP, TAG_RT, TAG_RTC} - {exclude}
  while parser.currentNode.tagType in tags:
    discard parser.openElements.pop()

proc generateImpliedEndTagsThoroughly(parser: var HTML5Parser) =
  const tags = {TAG_CAPTION, TAG_COLGROUP, TAG_DD, TAG_DT, TAG_LI,
                TAG_OPTGROUP, TAG_OPTION, TAG_P, TAG_RB, TAG_RP, TAG_RT,
                TAG_RTC, TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH, TAG_THEAD,
                TAG_TR}
  while parser.currentNode.tagType in tags:
    discard parser.openElements.pop()

# 13.2.4.3
proc pushOntoActiveFormatting(parser: var HTML5Parser, element: Element, token: Token) =
  var count = 0
  for i in countdown(parser.activeFormatting.high, 0):
    let it = parser.activeFormatting[i]
    if it[0] == nil: break
    if it[0].tagType != element.tagType: continue
    if it[0].tagType == TAG_UNKNOWN:
      if it[0].localName != element.localName: continue
    if it[0].namespace != element.namespace: continue
    var fail = false
    for k, v in it[0].attributes:
      if k notin element.attributes:
        fail = true
        break
      if v != element.attributes[k]:
        fail = true
        break
    if fail: continue
    for k, v in element.attributes:
      if k notin it[0].attributes:
        fail = true
        break
    if fail: continue
    inc count
    if count == 3:
      parser.activeFormatting.del(i)
      break
  parser.activeFormatting.add((element, token))

proc reconstructActiveFormatting(parser: var HTML5Parser) =
  type State = enum
    REWIND, ADVANCE, CREATE
  if parser.activeFormatting.len == 0:
    return
  if parser.activeFormatting[^1][0] == nil or parser.openElements.hasElement(parser.activeFormatting[^1][0].tagType):
    return
  var i = parser.activeFormatting.high
  template entry: Element = (parser.activeFormatting[i][0])
  var state = REWIND
  while true:
    {.computedGoto.}
    case state
    of REWIND:
      if i == 0:
        state = CREATE
        continue
      dec i
      if entry != nil and not parser.openElements.hasElement(entry.tagType):
        continue
      state = ADVANCE
    of ADVANCE:
      inc i
      state = CREATE
    of CREATE:
      parser.activeFormatting[i] = (parser.insertHTMLElement(parser.activeFormatting[i][1]), parser.activeFormatting[i][1])
      if i != parser.activeFormatting.high:
        state = ADVANCE
        continue
      break

proc clearActiveFormattingTillMarker(parser: var HTML5Parser) =
  while parser.activeFormatting.len > 0 and parser.activeFormatting.pop()[0] != nil: discard

template pop_current_node = discard parser.openElements.pop()

func isHTMLIntegrationPoint(node: Element): bool =
  return false #TODO SVG (NOTE MathML not implemented)

# Following is an implementation of the state (?) machine defined in
# https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inhtml
# It uses the ad-hoc pattern matching macro `match' to apply the following
# transformations:
# * First, pairs of patterns and actions are stored in tuples (and `discard'
#   statements...)
# * These pairs are then assigned to token types, later mapped to legs of the
#   first case statement.
# * Another case statement is constructed where needed, e.g. for switching on
#   characters/tags/etc.
# * Finally, the whole thing is wrapped in a named block, to implement a
#   pseudo-goto by breaking out only when the else statement needn't be
#   executed.
#
# e.g. the following code:
#
#   match token:
#     TokenType.COMMENT => (block: echo "comment")
#     ("<p>", "<a>", "</div>") => (block: echo "p, a or closing div")
#     ("<div>", "</p>") => (block: anything_else)
#     (TokenType.START_TAG, TokenType.END_TAG) => (block: assert false, "invalid")
#     _ => (block: echo "anything else")
#
# (effectively) generates this:
#
#   block inside_not_else:
#     case token.t
#     of TokenType.COMMENT:
#       echo "comment"
#       break inside_not_else
#     of TokenType.START_TAG:
#       case token.tagtype
#       of {TAG_P, TAG_A}:
#         echo "p, a or closing div"
#         break inside_not_else
#       of TAG_DIV: discard
#       else:
#         assert false
#         break inside_not_else
#     of TokenType.END_TAG:
#       case token.tagtype
#       of TAG_DIV:
#         echo "p, a or closing div"
#         break inside_not_else
#       of TAG_P: discard
#       else:
#         assert false
#         break inside_not_else
#     else: discard
#     echo "anything else"
#
# This duplicates any code that applies for several token types, except for the
# else branch.
macro match(token: Token, body: typed): untyped =
  type OfBranchStore = object
    ofBranches: seq[(seq[NimNode], NimNode)]
    defaultBranch: NimNode
    painted: bool

  # Stores 'of' branches
  var ofBranches: array[TokenType, OfBranchStore]
  # Stores 'else', 'elif' branches
  var defaultBranch: NimNode

  const tokenTypes = (func(): Table[string, TokenType] =
    for tt in TokenType:
      result[$tt] = tt)()

  for disc in body:
    let tup = disc[0] # access actual tuple
    let pattern = `tup`[0]
    let lambda = `tup`[1]
    var action = lambda.findChild(it.kind notin {nnkSym, nnkEmpty, nnkFormalParams})
    if pattern.kind != nnkDiscardStmt and not (action.len == 2 and action[1].kind == nnkDiscardStmt and action[1][0] == newStrLitNode("anything_else")):
      action = quote do:
        `action`
        #eprint token #debug
        break inside_not_else

    var patterns = @[pattern]
    while patterns.len > 0:
      let pattern = patterns.pop()
      case pattern.kind
      of nnkSym: # simple symbols; we assume these are the enums
        ofBranches[tokenTypes[pattern.strVal]].defaultBranch = action
        ofBranches[tokenTypes[pattern.strVal]].painted = true
      of nnkCharLit:
        ofBranches[CHARACTER_ASCII].ofBranches.add((@[pattern], action))
        ofBranches[CHARACTER_ASCII].painted = true
      of nnkCurly:
        case pattern[0].kind
        of nnkCharLit:
          ofBranches[CHARACTER_ASCII].ofBranches.add((@[pattern], action))
          ofBranches[CHARACTER_ASCII].painted = true
        else: error fmt"Unsupported curly of kind {pattern[0].kind}"
      of nnkStrLit:
        var tempTokenizer = newTokenizer(newStringStream(pattern.strVal))
        for token in tempTokenizer.tokenize:
          let tt = int(token.tagtype)
          case token.t
          of START_TAG, END_TAG:
            var found = false
            for i in 0..ofBranches[token.t].ofBranches.high:
              if ofBranches[token.t].ofBranches[i][1] == action:
                found = true
                ofBranches[token.t].ofBranches[i][0].add((quote do: TagType(`tt`)))
                ofBranches[token.t].painted = true
                break
            if not found:
              ofBranches[token.t].ofBranches.add((@[(quote do: TagType(`tt`))], action))
              ofBranches[token.t].painted = true
          else: error fmt"{pattern.strVal}: Unsupported token {token} of kind {token.t}"
          break
      of nnkDiscardStmt:
        defaultBranch = action
      of nnkTupleConstr:
        for child in pattern:
          patterns.add(child)
      else: error fmt"{pattern}: Unsupported pattern of kind {pattern.kind}"

  func tokenBranchOn(tok: TokenType): NimNode =
    case tok
    of START_TAG, END_TAG:
      return quote do: token.tagtype
    of CHARACTER:
      return quote do: token.r
    of CHARACTER_ASCII:
      return quote do: token.c
    else: error fmt"Unsupported branching of token {tok}"

  template add_to_case(branch: typed) =
    if branch[0].len == 1:
      tokenCase.add(newNimNode(nnkOfBranch).add(branch[0][0]).add(branch[1]))
    else:
      var curly = newNimNode(nnkCurly)
      for node in branch[0]:
        curly.add(node)
      tokenCase.add(newNimNode(nnkOfBranch).add(curly).add(branch[1]))

  # Build case statements
  var mainCase = newNimNode(nnkCaseStmt).add(quote do: `token`.t)
  for tt in TokenType:
    let ofBranch = newNimNode(nnkOfBranch).add(quote do: TokenType(`tt`))
    let tokenCase = newNimNode(nnkCaseStmt)
    if ofBranches[tt].defaultBranch != nil:
      if ofBranches[tt].ofBranches.len > 0:
        tokenCase.add(tokenBranchOn(tt))
        for branch in ofBranches[tt].ofBranches:
          add_to_case branch
        tokenCase.add(newNimNode(nnkElse).add(ofBranches[tt].defaultBranch))
        ofBranch.add(tokenCase)
        mainCase.add(ofBranch)
      else:
        ofBranch.add(ofBranches[tt].defaultBranch)
        mainCase.add(ofBranch)
    else:
      if ofBranches[tt].ofBranches.len > 0:
        tokenCase.add(tokenBranchOn(tt))
        for branch in ofBranches[tt].ofBranches:
          add_to_case branch
        ofBranch.add(tokenCase)
        tokenCase.add(newNimNode(nnkElse).add(quote do: discard))
        mainCase.add(ofBranch)
      else:
        discard

  for t in TokenType:
    if not ofBranches[t].painted:
      mainCase.add(newNimNode(nnkElse).add(quote do: discard))
      break

  var stmts = newStmtList().add(mainCase)
  for stmt in defaultBranch:
    stmts.add(stmt)
  result = newBlockStmt(ident("inside_not_else"), stmts)

proc processInHTMLContent(parser: var HTML5Parser, token: Token, insertionMode = parser.insertionMode) =
  template pop_all_nodes =
    while parser.openElements.len > 1: pop_current_node
  template anything_else = discard "anything_else"
  macro `=>`(v: typed, body: untyped): untyped =
    quote do:
      discard (`v`, proc() = `body`)
  template _ = discard
  template reprocess(tok: Token) =
    parser.processInHTMLContent(tok)

  case insertionMode
  of INITIAL:
    match token:
      AsciiWhitespace => (block: discard)
      TokenType.COMMENT => (block: parser.insertComment(token, last_child_of(parser.document)))
      TokenType.DOCTYPE => (block:
        if token.name.isnone or token.name.get != "html" or token.pubid.issome or (token.sysid.issome and token.sysid.get != "about:legacy-compat"):
          parse_error
        let doctype = parser.document.newDocumentType(token.name.get(""), token.pubid.get(""), token.sysid.get(""))
        parser.document.append(doctype)
        if not parser.document.is_iframe_srcdoc and not parser.document.parser_cannot_change_the_mode_flag:
          if quirksConditions(token):
            parser.document.mode = QUIRKS
          elif limitedQuirksConditions(token):
            parser.document.mode = LIMITED_QUIRKS
        parser.insertionMode = BEFORE_HTML
      )
      _ => (block:
        if not parser.document.is_iframe_srcdoc:
          parse_error
        if not parser.document.parser_cannot_change_the_mode_flag:
          parser.document.mode = QUIRKS
        parser.insertionMode = BEFORE_HTML
        reprocess token
      )

  of BEFORE_HTML:
    match token:
      TokenType.DOCTYPE => (block: parse_error)
      TokenType.COMMENT => (block: parser.insertComment(token, last_child_of(parser.document)))
      AsciiWhitespace => (block: discard)
      "<html>" => (block:
        let element = parser.createElement(token, Namespace.HTML, parser.document)
        parser.document.append(element)
        parser.openElements.add(element)
        parser.insertionMode = BEFORE_HEAD
      )
      ("</head>", "</body>", "</html>", "</br>") => (block: anything_else)
      TokenType.END_TAG => (block: parse_error)
      _ => (block:
        let element = parser.document.newHTMLElement(TAG_HTML, Namespace.HTML)
        parser.document.append(element)
        parser.openElements.add(element)
        parser.insertionMode = BEFORE_HEAD
        reprocess token
      )

  of BEFORE_HEAD:
    match token:
      AsciiWhitespace => (block: discard)
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "<head>" => (block:
        parser.head = parser.insertHTMLElement(token)
        parser.insertionMode = IN_HEAD
      )
      ("</head>", "</body>", "</html>", "</br>") => (block: anything_else)
      TokenType.END_TAG => (block: parse_error)
      _ => (block:
        parser.head = parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_HEAD))
        parser.insertionMode = IN_HEAD
        reprocess token
      )

  of IN_HEAD:
    match token:
      AsciiWhitespace => (block: discard)
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      ("<base>", "<basefont>", "<bgsound>", "<link>") => (block:
        discard parser.insertHTMLElement(token)
        pop_current_node
      )
      "<meta>" => (block:
        discard parser.insertHTMLElement(token)
        pop_current_node
        #TODO encodings
      )
      "<title>" => (block: parser.genericRCDATAElementParsingAlgorithm(token))
      "<noscript>" => (block:
        if not parser.scripting:
          discard parser.insertHTMLElement(token)
          parser.insertionMode = IN_HEAD_NOSCRIPT
        else:
          parser.genericRawtextElementParsingAlgorithm(token)
      )
      ("<noframes>", "<style>") => (block: parser.genericRawtextElementParsingAlgorithm(token))
      "<script>" => (block:
        let location = parser.appropriatePlaceForInsert()
        let element = HTMLScriptElement(parser.createElement(token, Namespace.HTML, location.inside))
        element.parserDocument = parser.document
        element.forceAsync = false
        if parser.fragment:
          element.alreadyStarted = true
        #TODO document.write (?)
        location.insert(element)
        parser.openElements.add(element)
        parser.tokenizer.state = SCRIPT_DATA
        parser.insertionMode = TEXT
      )
      "</head>" => (block:
        pop_current_node
        parser.insertionMode = AFTER_HEAD
      )
      ("</body>", "</html>", "</br>") => (block: anything_else)
      "<template>" => (block:
        discard parser.insertHTMLElement(token)
        parser.activeFormatting.add((nil, nil))
        parser.framesetok = false
        parser.insertionMode = IN_TEMPLATE
        parser.templateModes.add(IN_TEMPLATE)
      )
      "</template>" => (block:
        if not parser.openElements.hasElement(TAG_TEMPLATE):
          parse_error
        else:
          parser.generateImpliedEndTagsThoroughly()
          if parser.currentNode.tagType != TAG_TEMPLATE:
            parse_error
          while parser.openElements.pop().tagType != TAG_TEMPLATE: discard
          parser.clearActiveFormattingTillMarker()
          discard parser.templateModes.pop()
          parser.resetInsertionMode()
      )
      ("<head>", TokenType.END_TAG) => (block: parse_error)
      _ => (block:
        pop_current_node
        parser.insertionMode = AFTER_HEAD
        reprocess token
      )

  of IN_HEAD_NOSCRIPT:
    match token:
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "</noscript>" => (block:
        pop_current_node
        parser.insertionMode = IN_HEAD
      )
      (AsciiWhitespace,
       TokenType.COMMENT,
       "<basefont>", "<bgsound>", "<link>", "<meta>", "<noframes>", "<style>") => (block:
        parser.processInHTMLContent(token, IN_HEAD))
      "</br>" => (block: anything_else)
      ("<head>", "<noscript>") => (block: parse_error)
      TokenType.END_TAG => (block: parse_error)
      _ => (block:
        pop_current_node
        parser.insertionMode = IN_HEAD
        reprocess token
      )

  of AFTER_HEAD:
    match token:
      AsciiWhitespace => (block: parser.insertCharacter(token.c))
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "<body>" => (block:
        discard parser.insertHTMLElement(token)
        parser.framesetok = false
        parser.insertionMode = IN_BODY
      )
      "<frameset>" => (block:
        discard parser.insertHTMLElement(token)
        parser.insertionMode = IN_FRAMESET
      )
      ("<base>", "<basefont>", "<bgsound>", "<link>", "<meta>", "<noframes>", "<script>", "<style>", "<template>", "<title>") => (block:
        parse_error
        parser.openElements.add(parser.head)
        parser.processInHTMLContent(token, IN_HEAD)
        for i in countdown(parser.openElements.high, 0):
          if parser.openElements[i] == parser.head:
            parser.openElements.del(i)
      )
      "</template>" => (block: parser.processInHTMLContent(token, IN_HEAD))
      ("</body>", "</html>", "</br>") => (block: anything_else)
      ("<head>", TokenType.END_TAG) => (block: parse_error)
      _ => (block:
        discard parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_BODY))
        parser.insertionMode = IN_BODY
        reprocess token
      )

  of IN_BODY:
    proc closeP(parser: var HTML5Parser) =
      parser.generateImpliedEndTags(TAG_P)
      if parser.currentNode.tagType != TAG_P: parse_error
      while parser.openElements.pop().tagType != TAG_P: discard

    proc adoptionAgencyAlgorithm(parser: var HTML5Parser, token: Token): bool =
      if parser.currentNode.tagType != TAG_UNKNOWN and parser.currentNode.tagtype == token.tagtype or parser.currentNode.localName == token.tagname:
        var fail = true
        for it in parser.activeFormatting:
          if it[0] == parser.currentNode:
            fail = false
        if fail:
          pop_current_node
          return false
      var i = 0
      while true:
        if i >= 8: return false
        inc i
        if parser.activeFormatting.len == 0: return true
        var formatting: Element
        var formattingIndex: int
        for j in countdown(parser.activeFormatting.high, 0):
          let element = parser.activeFormatting[j][0]
          if element == nil:
            return true
          if element.tagType != TAG_UNKNOWN and element.tagtype == token.tagtype or element.qualifiedName == token.tagname:
            formatting = element
            formattingIndex = j
            break
          if j == 0:
            return true
        let stackIndex = parser.openElements.find(formatting)
        if stackIndex < 0:
          parse_error
          parser.activeFormatting.del(formattingIndex)
          return false
        if not parser.openElements.hasElementInScope(formatting):
          parse_error
          return false
        if formatting != parser.currentNode: parse_error
        var furthestBlock: Element = nil
        var furthestBlockIndex: int
        for j in countdown(parser.openElements.high, 0):
          if parser.openElements[j] == formatting:
            break
          if parser.openElements[j].tagType in SpecialElements:
            furthestBlock = parser.openElements[j]
            furthestBlockIndex = j
            break
        if furthestBlock == nil:
          while parser.openElements.pop() != formatting: discard
          parser.activeFormatting.del(formattingIndex)
          return false
        let commonAncestor = parser.openElements[stackIndex - 1]
        var bookmark = formattingIndex
        var node = furthestBlock
        var aboveNode = parser.openElements[furthestBlockIndex - 1]
        var lastNode = furthestBlock
        var j = 0
        while true:
          inc j
          node = aboveNode
          if node == formatting: break
          var nodeFormattingIndex = -1
          for i in countdown(parser.activeFormatting.high, 0):
            if parser.activeFormatting[i][0] == node:
              nodeFormattingIndex = i
              break
          if j > 3 and nodeFormattingIndex >= 0:
            parser.activeFormatting.del(nodeFormattingIndex)
            if nodeFormattingIndex < bookmark:
              dec bookmark # a previous node got deleted, so decrease bookmark by one
          let nodeStackIndex = parser.openElements.find(node)
          if nodeFormattingIndex < 0:
            parser.openElements.del(nodeStackIndex)
            if nodeStackIndex < furthestBlockIndex:
              dec furthestBlockIndex
            continue
          let element = parser.createElement(parser.activeFormatting[nodeFormattingIndex][1], Namespace.HTML, commonAncestor)
          parser.activeFormatting[nodeFormattingIndex] = (element, parser.activeFormatting[nodeFormattingIndex][1])
          parser.openElements[nodeFormattingIndex] = element
          aboveNode = parser.openElements[nodeFormattingIndex - 1]
          node = element
          if lastNode == furthestBlock:
            bookmark = nodeFormattingIndex
          node.append(lastNode)
          lastNode = node
        let location = parser.appropriatePlaceForInsert(commonAncestor)
        location.inside.insert(lastNode, location.before)
        let token = parser.activeFormatting[formattingIndex][1]
        let element = parser.createElement(token, Namespace.HTML, furthestBlock)
        for child in furthestBlock.childNodes:
          child.remove()
          element.append(child)
        furthestBlock.append(element)
        parser.activeFormatting.insert((element, token), bookmark)
        parser.activeFormatting.del(formattingIndex)
        parser.openElements.insert(element, furthestBlockIndex)
        parser.openElements.del(stackIndex)

    template any_other_start_tag() =
      parser.reconstructActiveFormatting()
      discard parser.insertHTMLElement(token)

    template any_other_end_tag() =
      for i in countdown(parser.openElements.high, 0):
        let node = parser.openElements[i]
        if node.tagType != TAG_UNKNOWN and node.tagType == token.tagtype or node.localName == token.tagname:
          parser.generateImpliedEndTags(token.tagtype)
          if node != parser.currentNode: parse_error
          while parser.openElements.pop() != node: discard
          break
        elif node.tagType in SpecialElements:
          parse_error
          return
    
    match token:
      '\0' => (block: parse_error)
      AsciiWhitespace => (block:
        parser.reconstructActiveFormatting()
        parser.insertCharacter(token.c)
      )
      TokenType.CHARACTER_ASCII => (block:
        parser.reconstructActiveFormatting()
        parser.insertCharacter(token.c)
        parser.framesetOk = false
      )
      TokenType.CHARACTER => (block:
        parser.reconstructActiveFormatting()
        parser.insertCharacter(token.r)
        parser.framesetOk = false
      )
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block:
        parse_error
        if parser.openElements.hasElement(TAG_TEMPLATE):
          discard
        else:
          for k, v in token.attrs:
            if k notin parser.openElements[0].attributes:
              parser.openElements[0].attributes[k] = v
      )
      ("<base>", "<basefont>", "<bgsound>", "<link>", "<meta>", "<noframes>", "<script>", "<style>", "<template>", "<title>",
       "</template>") => (block: parser.processInHTMLContent(token, IN_HEAD))
      "<body>" => (block:
        parse_error
        if parser.openElements.len == 1 or parser.openElements[1].tagType != TAG_BODY or parser.openElements.hasElement(TAG_TEMPLATE):
          discard
        else:
          parser.framesetOk = false
          for k, v in token.attrs:
            if k notin parser.openElements[1].attributes:
              parser.openElements[1].attributes[k] = v
      )
      "<frameset>" => (block:
        parse_error
        if parser.openElements.len == 1 or parser.openElements[1].tagType != TAG_BODY or not parser.framesetOk:
          discard
        else:
          if parser.openElements[1].parentNode != nil:
            parser.openElements[1].remove()
            pop_all_nodes
      )
      TokenType.EOF => (block:
        if parser.templateModes.len > 0:
          parser.processInHTMLContent(token, IN_TEMPLATE)
        else:
          #NOTE parse error omitted
          discard # stop
      )
      "</body>" => (block:
        if not parser.openElements.hasElementInScope(TAG_BODY):
          parse_error
        else:
          #NOTE parse error omitted
          parser.insertionMode = AFTER_BODY
      )
      "</html>" => (block:
        if not parser.openElements.hasElementInScope(TAG_BODY):
          parse_error
        else:
          #NOTE parse error omitted
          parser.insertionMode = AFTER_BODY
          reprocess token
      )
      ("<address>", "<article>", "<aside>", "<blockquote>", "<center>",
      "<details>", "<dialog>", "<dir>", "<div>", "<dl>", "<fieldset>",
      "<figcaption>", "<figure>", "<footer>", "<header>", "<hgroup>", "<main>",
      "<menu>", "<nav>", "<ol>", "<p>", "<section>", "<summary>", "<ul>") => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
      )
      ("<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>") => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        if parser.currentNode.tagType in HTagTypes:
          parse_error
          pop_current_node
        discard parser.insertHTMLElement(token)
      )
      ("<pre>", "<listing>") => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
        parser.ignoreLF = true
        parser.framesetOk = false
      )
      "<form>" => (block:
        let hasTemplate = parser.openElements.hasElement(TAG_TEMPLATE)
        if parser.form != nil and not hasTemplate:
          parse_error
        else:
          if parser.openElements.hasElementInButtonScope(TAG_P):
            parser.closeP()
          let element = parser.insertHTMLElement(token)
          if not hasTemplate:
            parser.form = HTMLFormElement(element)
      )
      "<li>" => (block:
        parser.framesetOk = false
        for i in countdown(parser.openElements.high, 0):
          let node = parser.openElements[i]
          case node.tagType
          of TAG_LI:
            parser.generateImpliedEndTags(TAG_LI)
            if parser.currentNode.tagType != TAG_LI: parse_error
            while parser.openElements.pop().tagType != TAG_LI: discard
            break
          of SpecialElements - {TAG_ADDRESS, TAG_DIV, TAG_P, TAG_LI}:
            break
          else: discard
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
      )
      ("<dd>", "<dt>") => (block:
        parser.framesetOk = false
        for i in countdown(parser.openElements.high, 0):
          let node = parser.openElements[i]
          case node.tagType
          of TAG_DD:
            parser.generateImpliedEndTags(TAG_DD)
            if parser.currentNode.tagType != TAG_DD: parse_error
            while parser.openElements.pop().tagType != TAG_DD: discard
            break
          of TAG_DT:
            parser.generateImpliedEndTags(TAG_DT)
            if parser.currentNode.tagType != TAG_DT: parse_error
            while parser.openElements.pop().tagType != TAG_DT: discard
            break
          of SpecialElements - {TAG_ADDRESS, TAG_DIV, TAG_P, TAG_DD, TAG_DT}:
            break
          else: discard
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
      )
      "<plaintext>" => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
        parser.tokenizer.state = PLAINTEXT
      )
      "<button>" => (block:
        if parser.openElements.hasElementInScope(TAG_BUTTON):
          parse_error
          parser.generateImpliedEndTags()
          while parser.openElements.pop().tagType != TAG_BUTTON: discard
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
        parser.framesetOk = false
      )
      ("</address>", "</article>", "</aside>", "</blockquote>", "</button>",
       "</center>", "</details>", "</dialog>", "</dir>", "</div>", "</dl>",
       "</fieldset>", "</figcaption>", "</figure>", "</footer>", "</header>",
       "</hgroup>", "</listing>", "</main>", "</menu>", "</nav>", "</ol>",
       "</pre>", "</section>", "</summary>", "</ul>") => (block:
        if not parser.openElements.hasElementInScope(token.tagtype):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != token.tagtype: parse_error
          while parser.openElements.pop().tagType != token.tagtype: discard
      )
      "</form>" => (block:
        if not parser.openElements.hasElement(TAG_TEMPLATE):
          let node = parser.form
          parser.form = nil
          if node == nil or not parser.openElements.hasElementInScope(node.tagType):
            parse_error
            return
          parser.generateImpliedEndTags()
          if parser.currentNode != node: parse_error
          parser.openElements.del(parser.openElements.find(node))
        else:
          if not parser.openElements.hasElementInScope(TAG_FORM):
            parse_error
            return
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != TAG_FORM: parse_error
          while parser.openElements.pop().tagType != TAG_FORM: discard
      )
      "</p>" => (block:
        if not parser.openElements.hasElementInButtonScope(TAG_P):
          parse_error
          discard parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_P))
        parser.closeP()
      )
      "</li>" => (block:
        if not parser.openElements.hasElementInListItemScope(TAG_LI):
          parse_error
        else:
          parser.generateImpliedEndTags(TAG_LI)
          if parser.currentNode.tagType != TAG_LI: parse_error
          while parser.openElements.pop().tagType != TAG_LI: discard
      )
      ("</dd>", "</dt>") => (block:
        if not parser.openElements.hasElementInScope(token.tagtype):
          parse_error
        else:
          parser.generateImpliedEndTags(token.tagtype)
          if parser.currentNode.tagType != token.tagtype: parse_error
          while parser.openElements.pop().tagType != token.tagtype: discard
      )
      ("</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>") => (block:
        if not parser.openElements.hasElementInScope(HTagTypes):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != token.tagtype: parse_error
          while parser.openElements.pop().tagType notin HTagTypes: discard
      )
      "</sarcasm>" => (block:
        #*deep breath*
        anything_else
      )
      "<a>" => (block:
        var anchor: Element = nil
        for i in countdown(parser.activeFormatting.high, 0):
          let format = parser.activeFormatting[i]
          if format[0] == nil:
            break
          if format[0].tagType == TAG_A:
            anchor = format[0]
            break
        if anchor != nil:
          parse_error
          if parser.adoptionAgencyAlgorithm(token):
            any_other_end_tag
            return
          for i in 0..parser.activeFormatting.high:
            if parser.activeFormatting[i][0] == anchor:
              parser.activeFormatting.del(i)
              break
          for i in 0..parser.openElements.high:
            if parser.openElements[i] == anchor:
              parser.openElements.del(i)
              break
        parser.reconstructActiveFormatting()
        let element = parser.insertHTMLElement(token)
        parser.pushOntoActiveFormatting(element, token)
      )
      ("<b>", "<big>", "<code>", "<em>", "<font>", "<i>", "<s>", "<small>",
       "<strike>", "<strong>", "<tt>", "<u>") => (block:
        parser.reconstructActiveFormatting()
        let element = parser.insertHTMLElement(token)
        parser.pushOntoActiveFormatting(element, token)
      )
      "<nobr>" => (block:
        parser.reconstructActiveFormatting()
        if parser.openElements.hasElementInScope(TAG_NOBR):
          parse_error
          if parser.adoptionAgencyAlgorithm(token):
            any_other_end_tag
            return
          parser.reconstructActiveFormatting()
        let element = parser.insertHTMLElement(token)
        parser.pushOntoActiveFormatting(element, token)
      )
      ("</a>", "</b>", "</big>", "</code>", "</em>", "</font>", "</i>",
       "</nobr>", "</s>", "</small>", "</strike>", "</strong>", "</tt>",
       "</u>") => (block:
        if parser.adoptionAgencyAlgorithm(token):
          any_other_end_tag
          return
      )
      ("<applet>", "<marquee>", "<object>") => (block:
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
        parser.activeFormatting.add((nil, nil))
        parser.framesetOk = false
      )
      ("</applet>", "</marquee>", "</object>") => (block:
        if not parser.openElements.hasElementInScope(token.tagtype):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != token.tagtype: parse_error
          while parser.openElements.pop().tagType != token.tagtype: discard
          parser.clearActiveFormattingTillMarker()
      )
      "<table>" => (block:
        if parser.document.mode != QUIRKS:
          if parser.openElements.hasElementInButtonScope(TAG_P):
            parser.closeP()
        discard parser.insertHTMLElement(token)
        parser.framesetOk = false
        parser.insertionMode = IN_TABLE
      )
      "</br>" => (block:
        parse_error
        parser.processInHTMLContent(Token(t: START_TAG, tagtype: TAG_BR))
      )
      ("<area>", "<br>", "<embed>", "<img>", "<keygen>", "<wbr>") => (block:
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
        pop_current_node
        parser.framesetOk = false
      )
      "<input>" => (block:
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
        pop_current_node
        if not token.attrs.getOrDefault("type").equalsIgnoreCase("hidden"):
          parser.framesetOk = false
      )
      ("<param>", "<source>", "<track>") => (block:
        discard parser.insertHTMLElement(token)
        pop_current_node
      )
      "<hr>" => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        discard parser.insertHTMLElement(token)
        pop_current_node
        parser.framesetOk = false
      )
      "<image>" => (block:
        #TODO ew
        let token = Token(t: START_TAG, tagtype: TAG_IMG, tagname: "img", selfclosing: token.selfclosing, attrs: token.attrs)
        reprocess token
      )
      "<textarea>" => (block:
        discard parser.insertHTMLElement(token)
        parser.ignoreLF = true
        parser.tokenizer.state = RCDATA
        parser.oldInsertionMode = parser.insertionMode
        parser.framesetOk = false
        parser.insertionMode = TEXT
      )
      "<xmp>" => (block:
        if parser.openElements.hasElementInButtonScope(TAG_P):
          parser.closeP()
        parser.reconstructActiveFormatting()
        parser.framesetOk = false
        parser.genericRawtextElementParsingAlgorithm(token)
      )
      "<iframe>" => (block:
        parser.framesetOk = false
        parser.genericRawtextElementParsingAlgorithm(token)
      )
      "<noembed>" => (block:
        parser.genericRawtextElementParsingAlgorithm(token)
      )
      "<noscript>" => (block:
        if parser.scripting:
          parser.genericRawtextElementParsingAlgorithm(token)
        else:
          any_other_start_tag
      )
      "<select>" => (block:
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
        parser.framesetOk = false
        if parser.insertionMode in {IN_TABLE, IN_CAPTION, IN_TABLE_BODY, IN_CELL}:
          parser.insertionMode = IN_SELECT_IN_TABLE
        else:
          parser.insertionMode = IN_SELECT
      )
      ("<optgroup>", "<option>") => (block:
        if parser.currentNode.tagType == TAG_OPTION:
          pop_current_node
        parser.reconstructActiveFormatting()
        discard parser.insertHTMLElement(token)
      )
      ("<rb>", "<rtc>") => (block:
        if parser.openElements.hasElementInScope(TAG_RUBY):
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != TAG_RUBY: parse_error
        discard parser.insertHTMLElement(token)
      )
      ("<rp>", "<rt>") => (block:
        if parser.openElements.hasElementInScope(TAG_RUBY):
          parser.generateImpliedEndTags(TAG_RTC)
          if parser.currentNode.tagType notin {TAG_RUBY, TAG_RTC}: parse_error
        discard parser.insertHTMLElement(token)
      )
      #NOTE <math> (not implemented)
      #TODO <svg> (SVG)
      ("<caption>", "<col>", "<colgroup>", "<frame>", "<head>", "<tbody>",
       "<td>", "<tfoot>", "<th>", "<thead>", "<tr>") => (block: parse_error)
      TokenType.START_TAG => (block: any_other_start_tag)
      TokenType.END_TAG => (block: any_other_end_tag)

  of TEXT:
    match token:
      TokenType.CHARACTER_ASCII => (block:
        assert token.c != '\0'
        parser.insertCharacter(token.c)
      )
      TokenType.CHARACTER => (block:
        parser.insertCharacter(token.r)
      )
      TokenType.EOF => (block:
        parse_error
        if parser.currentNode.tagType == TAG_SCRIPT:
          HTMLScriptElement(parser.currentNode).alreadyStarted = true
        pop_current_node
        parser.insertionMode = parser.oldInsertionMode
        reprocess token
      )
      "</script>" => (block:
        #TODO microtask
        pop_current_node
        parser.insertionMode = parser.oldInsertionMode
        #TODO document.write() ?
        #TODO prepare script element
        #TODO uh implement scripting or something
      )
      TokenType.END_TAG => (block:
        pop_current_node
        parser.insertionMode = parser.oldInsertionMode
      )

  of IN_TABLE:
    template clear_the_stack_back_to_a_table_context() =
      while parser.currentNode.tagType notin {TAG_TABLE, TAG_TEMPLATE, TAG_HTML}:
        pop_current_node

    match token:
      (TokenType.CHARACTER_ASCII, TokenType.CHARACTER) => (block:
        if parser.currentNode.tagType in {TAG_TABLE, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR}:
          parser.pendingTableChars = ""
          parser.pendingTableCharsWhitespace = true
          parser.oldInsertionMode = parser.insertionMode
          parser.insertionMode = IN_TABLE_TEXT
          reprocess token
        else: # anything else
          parse_error
          parser.fosterParenting = true
          parser.processInHTMLContent(token, IN_BODY)
          parser.fosterParenting = false
      )
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<caption>" => (block: 
        clear_the_stack_back_to_a_table_context
        parser.activeFormatting.add((nil, nil))
        discard parser.insertHTMLElement(token)
        parser.insertionMode = IN_CAPTION
      )
      "<colgroup>" => (block:
        clear_the_stack_back_to_a_table_context
        discard parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_COLGROUP))
        parser.insertionMode = IN_COLUMN_GROUP
      )
      ("<tbody>", "<tfoot>", "<thead>") => (block:
        clear_the_stack_back_to_a_table_context
        discard parser.insertHTMLElement(token)
        parser.insertionMode = IN_TABLE_BODY
      )
      ("<td>", "<th>", "<tr>") => (block:
        clear_the_stack_back_to_a_table_context
        discard parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_TBODY))
        parser.insertionMode = IN_TABLE_BODY
      )
      "<table>" => (block:
        parse_error
        if not parser.openElements.hasElementInScope(TAG_TABLE):
          discard
        else:
          while parser.openElements.pop().tagType != TAG_TABLE: discard
          parser.resetInsertionMode()
          reprocess token
      )
      "</table>" => (block:
        if not parser.openElements.hasElementInScope(TAG_TABLE):
          parse_error
        else:
          while parser.openElements.pop().tagType != TAG_TABLE: discard
          parser.resetInsertionMode()
      )
      ("</body>", "</caption>", "</col>", "</colgroup>", "</html>", "</tbody>",
       "</td>", "</tfoot>", "</th>", "</thead>", "</tr>") => (block:
        parse_error
      )
      ("<style>", "<script>", "<template>", "</template>") => (block:
        parser.processInHTMLContent(token, IN_HEAD)
      )
      "<input>" => (block:
        if not token.attrs.getOrDefault("type").equalsIgnoreCase("hidden"):
          # anything else
          parse_error
          parser.fosterParenting = true
          parser.processInHTMLContent(token, IN_BODY)
          parser.fosterParenting = false
        else:
          parse_error
          discard parser.insertHTMLElement(token)
          pop_current_node
      )
      "<form>" => (block:
        parse_error
        if parser.form != nil or parser.openElements.hasElement(TAG_TEMPLATE):
          discard
        else:
          parser.form = HTMLFormElement(parser.insertHTMLElement(token))
          pop_current_node
      )
      TokenType.EOF => (block:
        parser.processInHTMLContent(token, IN_BODY)
      )
      _ => (block:
        parse_error
        parser.fosterParenting = true
        parser.processInHTMLContent(token, IN_BODY)
        parser.fosterParenting = false
      )

  of IN_TABLE_TEXT:
    match token:
      '\0' => (block: parse_error)
      TokenType.CHARACTER_ASCII => (block:
        if token.c notin AsciiWhitespace:
          parser.pendingTableCharsWhitespace = false
        parser.pendingTableChars &= token.c
      )
      TokenType.CHARACTER => (block:
        parser.pendingTableChars &= token.r
        parser.pendingTableCharsWhitespace = false
      )
      _ => (block:
        if not parser.pendingTableCharsWhitespace:
          # I *think* this is effectively the same thing the specification wants...
          parse_error
          parser.fosterParenting = true
          parser.reconstructActiveFormatting()
          parser.insertCharacter(token.c)
          parser.framesetOk = false
          parser.fosterParenting = false
        else:
          parser.insertCharacter(parser.pendingTableChars)
        parser.insertionMode = parser.oldInsertionMode
        reprocess token
      )

  of IN_CAPTION:
    match token:
      "</caption>" => (block:
        if parser.openElements.hasElementInTableScope(TAG_CAPTION):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != TAG_CAPTION: parse_error
          while parser.openElements.pop().tagType != TAG_CAPTION: discard
          parser.clearActiveFormattingTillMarker()
          parser.insertionMode = IN_TABLE
      )
      ("<caption>", "<col>", "<colgroup>", "<tbody>", "<td>", "<tfoot>",
       "<th>", "<thead>", "<tr>", "</table>") => (block:
        if not parser.openElements.hasElementInTableScope(TAG_CAPTION):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != TAG_CAPTION: parse_error
          parser.clearActiveFormattingTillMarker()
          parser.insertionMode = IN_TABLE
          reprocess token
      )
      ("</body>", "</col>", "</colgroup>", "</html>", "</tbody>", "</td>",
       "</tfoot>", "</th>", "</thead>", "</tr>") => (block: parse_error)
      _ => (block: parser.processInHTMLContent(token, IN_BODY))

  of IN_COLUMN_GROUP:
    match token:
      AsciiWhitespace => (block: parser.insertCharacter(token.c))
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "<col>" => (block:
        discard parser.insertHTMLElement(token)
        pop_current_node
      )
      "</colgroup>" => (block:
        if parser.currentNode.tagType != TAG_COLGROUP:
          parse_error
        else:
          pop_current_node
          parser.insertionMode = IN_TABLE
      )
      "</col>" => (block: parse_error)
      ("<template>", "</template>") => (block:
        parser.processInHTMLContent(token, IN_HEAD)
      )
      TokenType.EOF => (block: parser.processInHTMLContent(token, IN_BODY))
      _ => (block:
        if parser.currentNode.tagType != TAG_COLGROUP:
          parse_error
        else:
          pop_current_node
          parser.insertionMode = IN_TABLE
          reprocess token
      )

  of IN_TABLE_BODY:
    template clear_the_stack_back_to_a_table_body_context() =
      while parser.currentNode.tagType notin {TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TEMPLATE, TAG_HTML}:
        pop_current_node

    match token:
      "<tr>" => (block:
        clear_the_stack_back_to_a_table_body_context
        discard parser.insertHTMLElement(token)
        parser.insertionMode = IN_ROW
      )
      ("<th>", "<td>") => (block:
        parse_error
        clear_the_stack_back_to_a_table_body_context
        discard parser.insertHTMLElement(Token(t: START_TAG, tagtype: TAG_TR))
        parser.insertionMode = IN_ROW
        reprocess token
      )
      ("</tbody>", "</tfoot>", "</thead>") => (block:
        if not parser.openElements.hasElementInTableScope(token.tagtype):
          parse_error
        else:
          clear_the_stack_back_to_a_table_body_context
          pop_current_node
          parser.insertionMode = IN_TABLE
      )
      ("<caption>", "<col>", "<colgroup>", "<tbody>", "<tfoot>", "<thead>",
       "</table>") => (block:
        if not parser.openElements.hasElementInTableScope({TAG_TBODY, TAG_THEAD, TAG_TFOOT}):
          parse_error
        else:
          clear_the_stack_back_to_a_table_body_context
          pop_current_node
          parser.insertionMode = IN_TABLE
          reprocess token
      )
      ("</body>", "</caption>", "</col>", "</colgroup>", "</html>", "</td>",
       "</th>", "</tr>") => (block:
        parse_error
      )
      _ => (block: parser.processInHTMLContent(token, IN_TABLE))

  of IN_ROW:
    template clear_the_stack_back_to_a_table_row_context() =
      while parser.currentNode.tagType notin {TAG_TR, TAG_TEMPLATE, TAG_HTML}:
        pop_current_node

    match token:
      ("<th>", "<td>") => (block:
        clear_the_stack_back_to_a_table_row_context
        discard parser.insertHTMLElement(token)
        parser.insertionMode = IN_CELL
        parser.activeFormatting.add((nil, nil))
      )
      "</tr>" => (block:
        if not parser.openElements.hasElementInTableScope(TAG_TR):
          parse_error
        else:
          clear_the_stack_back_to_a_table_row_context
          pop_current_node
          parser.insertionMode = IN_TABLE_BODY
      )
      ("<caption>", "<col>", "<colgroup>", "<tbody>", "<tfoot>", "<thead>",
       "<tr>", "</table>") => (block:
        if not parser.openElements.hasElementInTableScope(TAG_TR):
          parse_error
        else:
          clear_the_stack_back_to_a_table_row_context
          pop_current_node
          parser.insertionMode = IN_TABLE_BODY
          reprocess token
      )
      ("</tbody>", "</tfoot>", "</thead>") => (block:
        if not parser.openElements.hasElementInTableScope(token.tagtype):
          parse_error
        elif not parser.openElements.hasElementInTableScope(TAG_TR):
          discard
        else:
          clear_the_stack_back_to_a_table_row_context
          pop_current_node
          parser.insertionMode = IN_BODY
          reprocess token
      )
      ("</body>", "</caption>", "</col>", "</colgroup>", "</html>", "</td>",
       "</th>") => (block: parse_error)
      _ => (block: parser.processInHTMLContent(token, IN_TABLE))

  of IN_CELL:
    template close_cell() =
      parser.generateImpliedEndTags()
      if parser.currentNode.tagType notin {TAG_TD, TAG_TH}: parse_error
      while parser.openElements.pop().tagType notin {TAG_TD, TAG_TH}: discard
      parser.clearActiveFormattingTillMarker()
      parser.insertionMode = IN_ROW

    match token:
      ("</td>", "</th>") => (block:
        if not parser.openElements.hasElementInTableScope(token.tagtype):
          parse_error
        else:
          parser.generateImpliedEndTags()
          if parser.currentNode.tagType != token.tagtype: parse_error
          while parser.openElements.pop().tagType != token.tagtype: discard
          parser.clearActiveFormattingTillMarker()
          parser.insertionMode = IN_ROW
      )
      ("<caption>", "<col>", "<colgroup>", "<tbody>", "<td>", "<tfoot>",
       "<thead>", "<tr>") => (block:
        if not parser.openElements.hasElementInTableScope({TAG_TD, TAG_TH}):
          parse_error
        else:
          close_cell
      )
      ("</body>", "</caption>", "</col>", "</colgroup>",
       "</html>") => (block: parse_error)
      ("</table>", "</tbody>", "</tfoot>", "</thead>", "</tr>") => (block:
        if not parser.openElements.hasElementInTableScope(token.tagtype):
          parse_error
        else:
          close_cell
          reprocess token
      )
      _ => (block: parser.processInHTMLContent(token, IN_BODY))

  of IN_SELECT:
    match token:
      '\0' => (block: parse_error)
      TokenType.CHARACTER_ASCII => (block: parser.insertCharacter(token.c))
      TokenType.CHARACTER => (block: parser.insertCharacter(token.r))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "<option>" => (block:
        if parser.currentNode.tagType == TAG_OPTION:
          pop_current_node
        discard parser.insertHTMLElement(token)
      )
      "<optgroup>" => (block:
        if parser.currentNode.tagType == TAG_OPTION:
          pop_current_node
        if parser.currentNode.tagType == TAG_OPTGROUP:
          pop_current_node
        discard parser.insertHTMLElement(token)
      )
      "</optgroup>" => (block:
        if parser.currentNode.tagType == TAG_OPTION:
          if parser.openElements.len > 1 and parser.openElements[^2].tagType == TAG_OPTGROUP:
            pop_current_node
        if parser.currentNode.tagType == TAG_OPTGROUP:
          pop_current_node
        else:
          parse_error
      )
      "</option>" => (block:
        if parser.currentNode.tagType == TAG_OPTION:
          pop_current_node
        else:
          parse_error
      )
      "</select>" => (block:
        if not parser.openElements.hasElementInSelectScope(TAG_SELECT):
          parse_error
        else:
          while parser.openElements.pop().tagType != TAG_SELECT: discard
          parser.resetInsertionMode()
      )
      ("<input>", "<keygen>", "<textarea>") => (block:
        parse_error
        if not parser.openElements.hasElementInSelectScope(TAG_SELECT):
          discard
        else:
          while parser.openElements.pop().tagType != TAG_SELECT: discard
          parser.resetInsertionMode()
          reprocess token
      )
      ("<script>", "<template>", "</template>") => (block: parser.processInHTMLContent(token, IN_HEAD))
      TokenType.EOF => (block: parser.processInHTMLContent(token, IN_BODY))
      _ => (block: parse_error)

  of IN_SELECT_IN_TABLE:
    match token:
      ("<caption>", "<table>", "<tbody>", "<tfoot>", "<thead>", "<tr>", "<td>",
       "<th>") => (block:
        parse_error
        while parser.openElements.pop().tagType != TAG_SELECT: discard
        parser.resetInsertionMode()
        reprocess token
      )
      ("</caption>", "</table>", "</tbody>", "</tfoot>", "</thead>", "</tr>",
       "</td>", "</th>") => (block:
        parse_error
        if not parser.openElements.hasElementInTableScope(token.tagtype):
          discard
        else:
          while parser.openElements.pop().tagType != TAG_SELECT: discard
          parser.resetInsertionMode()
          reprocess token
      )
      _ => (block: parser.processInHTMLContent(token, IN_SELECT))

  of IN_TEMPLATE:
    match token:
      (TokenType.CHARACTER_ASCII, TokenType.CHARACTER, TokenType.DOCTYPE) => (block:
        parser.processInHTMLContent(token, IN_BODY)
      )
      ("<base>", "<basefont>", "<bgsound>", "<link>", "<meta>", "<noframes>",
       "<script>", "<style>", "<template>", "<title>", "</template>") => (block:
        parser.processInHTMLContent(token, IN_HEAD)
      )
      ("<caption>", "<colgroup>", "<tbody>", "<tfoot>", "<thead>") => (block:
        discard parser.templateModes.pop()
        parser.templateModes.add(IN_TABLE)
        parser.insertionMode = IN_TABLE
        reprocess token
      )
      "<col>" => (block:
        discard parser.templateModes.pop()
        parser.templateModes.add(IN_COLUMN_GROUP)
        parser.insertionMode = IN_COLUMN_GROUP
        reprocess token
      )
      "<tr>" => (block:
        discard parser.templateModes.pop()
        parser.templateModes.add(IN_TABLE_BODY)
        parser.insertionMode = IN_TABLE_BODY
        reprocess token
      )
      ("<td>", "<th>") => (block:
        discard parser.templateModes.pop()
        parser.templateModes.add(IN_ROW)
        parser.insertionMode = IN_ROW
        reprocess token
      )
      TokenType.START_TAG => (block:
        discard parser.templateModes.pop()
        parser.templateModes.add(IN_BODY)
        parser.insertionMode = IN_BODY
        reprocess token
      )
      TokenType.END_TAG => (block: parse_error)
      TokenType.EOF => (block:
        if not parser.openElements.hasElement(TAG_TEMPLATE):
          discard # stop
        else:
          parse_error
          while parser.openElements.pop().tagType != TAG_TEMPLATE: discard
          parser.clearActiveFormattingTillMarker()
          discard parser.templateModes.pop()
          parser.resetInsertionMode()
          reprocess token
      )

  of AFTER_BODY:
    match token:
      AsciiWhitespace => (block: parser.processInHTMLContent(token, IN_BODY))
      TokenType.COMMENT => (block: parser.insertComment(token, last_child_of(parser.openElements[0])))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "</html>" => (block:
        if parser.fragment:
          parse_error
        else:
          parser.insertionMode = AFTER_AFTER_BODY
      )
      TokenType.EOF => (block: discard) # stop
      _ => (block:
        parse_error
        parser.insertionMode = IN_BODY
        reprocess token
      )

  of IN_FRAMESET:
    match token:
      AsciiWhitespace => (block: parser.insertCharacter(token.c))
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "<frameset>" => (block:
        if parser.currentNode == parser.document.html:
          parse_error
        else:
          pop_current_node
        if not parser.fragment and parser.currentNode.tagType != TAG_FRAMESET:
          parser.insertionMode = AFTER_FRAMESET
      )
      "<frame>" => (block:
        discard parser.insertHTMLElement(token)
        pop_current_node
      )
      "<noframes>" => (block: parser.processInHTMLContent(token, IN_HEAD))
      TokenType.EOF => (block:
        if parser.currentNode != parser.document.html: parse_error
        # stop
      )
      _ => (block: parse_error)

  of AFTER_FRAMESET:
    match token:
      AsciiWhitespace => (block: parser.insertCharacter(token.c))
      TokenType.COMMENT => (block: parser.insertComment(token))
      TokenType.DOCTYPE => (block: parse_error)
      "<html>" => (block: parser.processInHTMLContent(token, IN_BODY))
      "</html>" => (block: parser.insertionMode = AFTER_AFTER_FRAMESET)
      "<noframes>" => (block: parser.processInHTMLContent(token, IN_HEAD))
      TokenType.EOF => (block: discard) # stop
      _ => (block: parse_error)

  of AFTER_AFTER_BODY:
    match token:
      TokenType.COMMENT => (block: parser.insertComment(token, last_child_of(parser.document)))
      (TokenType.DOCTYPE, AsciiWhitespace, "<html>") => (block: parser.processInHTMLContent(token, IN_BODY))
      TokenType.EOF => (block: discard) # stop
      _ => (block:
        parse_error
        parser.insertionMode = IN_BODY
        reprocess token
      )

  of AFTER_AFTER_FRAMESET:
    match token:
      TokenType.COMMENT => (block: parser.insertComment(token, last_child_of(parser.document)))
      (TokenType.DOCTYPE, AsciiWhitespace, "<html>") => (block: parser.processInHTMLContent(token, IN_BODY))
      TokenType.EOF => (block: discard) # stop
      "<noframes>" => (block: parser.processInHTMLContent(token, IN_HEAD))
      _ => (block: parse_error)

proc processInForeignContent(parser: var HTML5Parser, token: Token) =
  macro `=>`(v: typed, body: untyped): untyped =
    quote do:
      discard (`v`, proc() = `body`)
  template script_end_tag() =
    pop_current_node
    #TODO document.write (?)
    #TODO SVG
  template any_other_end_tag() =
    if parser.currentNode.localName != token.tagname: parse_error
    for i in countdown(parser.openElements.high, 1):
      let node = parser.openElements[i]
      if node.localName == token.tagname:
        while parser.openElements.pop() != node: discard
        break
      if node.namespace == Namespace.HTML: break
      parser.processInHTMLContent(token)

  match token:
    '\0' => (block:
      parse_error
      parser.insertCharacter(Rune(0xFFFD))
    )
    AsciiWhitespace => (block: parser.insertCharacter(token.c))
    TokenType.CHARACTER_ASCII => (block: parser.insertCharacter(token.c))
    TokenType.CHARACTER => (block: parser.insertCharacter(token.r))
    TokenType.DOCTYPE => (block: parse_error)
    ("<b>", "<big>", "<blockquote>", "<body>", "<br>", "<center>", "<code>",
     "<dd>", "<div>", "<dl>", "<dt>", "<em>", "<embed>", "<h1>", "<h2>", "<h3>",
     "<h4>", "<h5>", "<h6>", "<head>", "<hr>", "<i>", "<img>", "<li>",
     "<listing>", "<menu>", "<meta>", "<nobr>", "<ol>", "<p>", "<pre>",
     "<ruby>", "<s>", "<small>", "<span>", "<strong>", "<strike>", "<sub>",
     "<sup>", "<table>", "<tt>", "<u>", "<ul>", "<var>") => (block:
      parse_error
      #NOTE MathML not implemented
      while not (parser.currentNode.isHTMLIntegrationPoint() or parser.currentNode.inHTMLNamespace()):
        pop_current_node
      parser.processInHTMLContent(token)
    )
    TokenType.START_TAG => (block:
      #NOTE MathML not implemented
      #TODO SVG
      #TODO adjust foreign attributes
      let element = parser.insertForeignElement(token, parser.adjustedCurrentNode.namespace)
      if token.selfclosing and element.inSVGNamespace():
        script_end_tag
      else:
        pop_current_node
    )
    "</script>" => (block:
      if parser.currentNode.namespace == Namespace.SVG and parser.currentNode.localName == "script": #TODO SVG
        script_end_tag
      else:
        any_other_end_tag
    )
    TokenType.END_TAG => (block: any_other_end_tag)

proc constructTree(parser: var HTML5Parser): Document =
  for token in parser.tokenizer.tokenize:
    if parser.ignoreLF:
      parser.ignoreLF = false
      if token.t == CHARACTER_ASCII and token.c == '\n':
        continue
    if parser.openElements.len == 0 or
       parser.adjustedCurrentNode.inHTMLNamespace() or
       parser.adjustedCurrentNode.isHTMLIntegrationPoint() and token.t in {START_TAG, CHARACTER, CHARACTER_ASCII} or
       token.t == EOF:
      #NOTE MathML not implemented
      parser.processInHTMLContent(token)
    else:
      parser.processInForeignContent(token)

  #TODO document.write (?)
  #TODO etc etc...

  return parser.document

proc parseHTML5*(inputStream: Stream): Document =
  var parser: HTML5Parser
  parser.document = newDocument()
  parser.tokenizer = inputStream.newTokenizer()
  return parser.constructTree()
