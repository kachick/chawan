import deques
import macros
import math
import options
import sets
import streams
import strutils
import tables

import css/cssparser
import css/sheet
import css/values
import data/charset
import encoding/decoderstream
import html/event
import html/tags
import img/bitmap
import img/painter
import img/path
import img/png
import io/loader
import io/request
import io/window
import js/exception
import js/javascript
import js/timeout
import types/blob
import types/color
import types/matrix
import types/mime
import types/referer
import types/url
import types/vector
import utils/twtstr

type
  FormMethod* = enum
    FORM_METHOD_GET, FORM_METHOD_POST, FORM_METHOD_DIALOG

  FormEncodingType* = enum
    FORM_ENCODING_TYPE_URLENCODED = "application/x-www-form-urlencoded",
    FORM_ENCODING_TYPE_MULTIPART = "multipart/form-data",
    FORM_ENCODING_TYPE_TEXT_PLAIN = "text/plain"

  QuirksMode* = enum
    NO_QUIRKS, QUIRKS, LIMITED_QUIRKS

  Namespace* = enum
    NO_NAMESPACE = "",
    HTML = "http://www.w3.org/1999/xhtml",
    MATHML = "http://www.w3.org/1998/Math/MathML",
    SVG = "http://www.w3.org/2000/svg",
    XLINK = "http://www.w3.org/1999/xlink",
    XML = "http://www.w3.org/XML/1998/namespace",
    XMLNS = "http://www.w3.org/2000/xmlns/"

  ScriptType = enum
    NO_SCRIPTTYPE, CLASSIC, MODULE, IMPORTMAP

  ParserMetadata = enum
    PARSER_INSERTED, NOT_PARSER_INSERTED

  ScriptResultType = enum
    RESULT_NULL, RESULT_UNINITIALIZED, RESULT_SCRIPT, RESULT_IMPORT_MAP_PARSE

type
  Script = object
    #TODO setings
    baseURL: URL
    options: ScriptOptions
    mutedErrors: bool
    #TODO parse error/error to rethrow
    record: string #TODO should be a record...

  ScriptOptions = object
    nonce: string
    integrity: string
    parserMetadata: ParserMetadata
    credentialsMode: CredentialsMode
    referrerPolicy: Option[ReferrerPolicy]
    renderBlocking: bool

  ScriptResult = object
    case t: ScriptResultType
    of RESULT_NULL, RESULT_UNINITIALIZED:
      discard
    of RESULT_SCRIPT:
      script: Script
    of RESULT_IMPORT_MAP_PARSE:
      discard #TODO

type
  Location = ref object
    window: Window

  Window* = ref object
    attrs*: WindowAttributes
    console* {.jsget.}: console
    navigator* {.jsget.}: Navigator
    settings*: EnvironmentSettings
    loader*: Option[FileLoader]
    location* {.jsget.}: Location
    jsrt*: JSRuntime
    jsctx*: JSContext
    document* {.jsget.}: Document
    timeouts*: TimeoutState[int]
    navigate*: proc(url: URL)

  # Navigator stuff
  Navigator* = ref object
    plugins: PluginArray

  PluginArray* = ref object

  MimeTypeArray* = ref object

  # "For historical reasons, console is lowercased."
  # Also, for a more practical reason: so the javascript macros don't confuse
  # this and the Client console.
  # TODO: merge those two
  console* = ref object
    err*: Stream

  NamedNodeMap = ref object
    element: Element
    attrlist: seq[Attr]

  EnvironmentSettings* = object
    scripting*: bool

  Collection = ref CollectionObj
  CollectionObj = object of RootObj
    islive: bool
    childonly: bool
    root: Node
    match: proc(node: Node): bool {.noSideEffect.}
    snapshot: seq[Node]
    livelen: int
    id: int

  NodeList = ref object of Collection

  HTMLCollection = ref object of Collection

  DOMTokenList = ref object
    toks*: seq[string]
    element: Element
    localName: string

  Node* = ref object of EventTarget
    nodeType*: NodeType
    childList*: seq[Node]
    parentNode* {.jsget.}: Node
    parentElement* {.jsget.}: Element
    root: Node
    document*: Document
    index*: int # Index in parents children. -1 for nodes without a parent.
    # Live collection cache: ids of live collections are saved in all
    # nodes they refer to. These are removed when the collection is destroyed,
    # and invalidated when the owner node's children or attributes change.
    # (We can't just store pointers, because those may be invalidated by
    # the JavaScript finalizers.)
    liveCollections: HashSet[int]
    children_cached: HTMLCollection
    childNodes_cached: NodeList

  Attr* = ref object of Node
    namespaceURI* {.jsget.}: string
    prefix* {.jsget.}: string
    localName* {.jsget.}: string
    value* {.jsget.}: string
    ownerElement* {.jsget.}: Element

  DOMImplementation = ref object
    document: Document

  Document* = ref object of Node
    charset*: Charset
    window*: Window
    url* {.jsget: "URL".}: URL
    mode*: QuirksMode
    currentScript: HTMLScriptElement
    isxml*: bool
    implementation {.jsget.}: DOMImplementation
    origin: Origin

    scriptsToExecSoon*: seq[HTMLScriptElement]
    scriptsToExecInOrder*: Deque[HTMLScriptElement]
    scriptsToExecOnLoad*: Deque[HTMLScriptElement]
    parserBlockingScript*: HTMLScriptElement

    parser_cannot_change_the_mode_flag*: bool
    is_iframe_srcdoc*: bool
    focus*: Element
    contentType* {.jsget.}: string

    renderBlockingElements: seq[Element]

    invalidCollections: HashSet[int] # collection ids
    colln: int

    cachedSheets: seq[CSSStylesheet]
    cachedSheetsInvalid: bool

  CharacterData* = ref object of Node
    data* {.jsget.}: string

  Text* = ref object of CharacterData

  Comment* = ref object of CharacterData

  CDATASection = ref object of CharacterData

  ProcessingInstruction = ref object of CharacterData
    target {.jsget.}: string

  DocumentFragment* = ref object of Node
    host*: Element

  DocumentType* = ref object of Node
    name*: string
    publicId*: string
    systemId*: string

  Element* = ref object of Node
    namespace*: Namespace
    namespacePrefix*: Option[string]
    prefix*: string
    localName*: string
    tagType*: TagType

    id* {.jsget.}: string
    classList* {.jsget.}: DOMTokenList
    attrs*: Table[string, string]
    attributes* {.jsget.}: NamedNodeMap
    hover*: bool
    invalid*: bool

  HTMLElement* = ref object of Element

  FormAssociatedElement* = ref object of HTMLElement
    parserInserted*: bool

  HTMLInputElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    inputType*: InputType
    value* {.jsget.}: string
    checked*: bool
    xcoord*: int
    ycoord*: int
    file*: Option[Url]

  HTMLAnchorElement* = ref object of HTMLElement

  HTMLSelectElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement

  HTMLSpanElement* = ref object of HTMLElement

  HTMLOptGroupElement* = ref object of HTMLElement

  HTMLOptionElement* = ref object of HTMLElement
    selected*: bool
  
  HTMLHeadingElement* = ref object of HTMLElement
    rank*: uint16

  HTMLBRElement* = ref object of HTMLElement

  HTMLMenuElement* = ref object of HTMLElement

  HTMLUListElement* = ref object of HTMLElement

  HTMLOListElement* = ref object of HTMLElement
    start*: Option[int]

  HTMLLIElement* = ref object of HTMLElement
    value* {.jsget.}: Option[int]

  HTMLStyleElement* = ref object of HTMLElement
    sheet*: CSSStylesheet

  HTMLLinkElement* = ref object of HTMLElement
    sheet*: CSSStylesheet

  HTMLFormElement* = ref object of HTMLElement
    name*: string
    smethod*: string
    enctype*: string
    novalidate*: bool
    constructingentrylist*: bool
    controls*: seq[FormAssociatedElement]

  HTMLTemplateElement* = ref object of HTMLElement
    content*: DocumentFragment

  HTMLUnknownElement* = ref object of HTMLElement

  HTMLScriptElement* = ref object of HTMLElement
    parserDocument*: Document
    preparationTimeDocument*: Document
    forceAsync*: bool
    fromAnExternalFile*: bool
    readyForParserExec*: bool
    alreadyStarted*: bool
    delayingTheLoadEvent: bool
    ctype: ScriptType
    internalNonce: string
    scriptResult*: ScriptResult
    onReady: (proc())

  HTMLBaseElement* = ref object of HTMLElement

  HTMLAreaElement* = ref object of HTMLElement

  HTMLButtonElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    ctype*: ButtonType
    value* {.jsget, jsset.}: string

  HTMLTextAreaElement* = ref object of FormAssociatedElement
    form* {.jsget.}: HTMLFormElement
    value* {.jsget.}: string

  HTMLLabelElement* = ref object of HTMLElement

  HTMLCanvasElement* = ref object of HTMLElement
    ctx2d: CanvasRenderingContext2D
    bitmap: Bitmap

  DrawingState = object
    # CanvasTransform
    transformMatrix: Matrix
    # CanvasFillStrokeStyles
    fillStyle: RGBAColor
    strokeStyle: RGBAColor
    # CanvasPathDrawingStyles
    lineWidth: float64
    # CanvasTextDrawingStyles
    textAlign: CSSTextAlign
    # CanvasPath
    path: Path

  RenderingContext = ref object of RootObj

  CanvasRenderingContext2D = ref object of RenderingContext
    canvas {.jsget.}: HTMLCanvasElement
    bitmap: Bitmap
    state: DrawingState
    stateStack: seq[DrawingState]

  TextMetrics = ref object
    # x-direction
    width {.jsget.}: float64
    actualBoundingBoxLeft {.jsget.}: float64
    actualBoundingBoxRight {.jsget.}: float64
    # y-direction
    fontBoundingBoxAscent {.jsget.}: float64
    fontBoundingBoxDescent {.jsget.}: float64
    actualBoundingBoxAscent {.jsget.}: float64
    actualBoundingBoxDescent {.jsget.}: float64
    emHeightAscent {.jsget.}: float64
    emHeightDescent {.jsget.}: float64
    hangingBaseline {.jsget.}: float64
    alphabeticBaseline {.jsget.}: float64
    ideographicBaseline {.jsget.}: float64

  HTMLImageElement* = ref object of HTMLElement
    bitmap*: Bitmap

jsDestructor(Navigator)
jsDestructor(PluginArray)
jsDestructor(MimeTypeArray)
jsDestructor(Window)

jsDestructor(console)
jsDestructor(Element)
jsDestructor(HTMLElement)
jsDestructor(HTMLInputElement)
jsDestructor(HTMLAnchorElement)
jsDestructor(HTMLSelectElement)
jsDestructor(HTMLSpanElement)
jsDestructor(HTMLOptGroupElement)
jsDestructor(HTMLOptionElement)
jsDestructor(HTMLHeadingElement)
jsDestructor(HTMLBRElement)
jsDestructor(HTMLMenuElement)
jsDestructor(HTMLUListElement)
jsDestructor(HTMLOListElement)
jsDestructor(HTMLLIElement)
jsDestructor(HTMLStyleElement)
jsDestructor(HTMLLinkElement)
jsDestructor(HTMLFormElement)
jsDestructor(HTMLTemplateElement)
jsDestructor(HTMLUnknownElement)
jsDestructor(HTMLScriptElement)
jsDestructor(HTMLBaseElement)
jsDestructor(HTMLAreaElement)
jsDestructor(HTMLButtonElement)
jsDestructor(HTMLTextAreaElement)
jsDestructor(HTMLLabelElement)
jsDestructor(HTMLCanvasElement)
jsDestructor(HTMLImageElement)
jsDestructor(Node)
jsDestructor(NodeList)
jsDestructor(HTMLCollection)
jsDestructor(Location)
jsDestructor(Document)
jsDestructor(DOMImplementation)
jsDestructor(DOMTokenList)
jsDestructor(Comment)
jsDestructor(CDATASection)
jsDestructor(DocumentFragment)
jsDestructor(ProcessingInstruction)
jsDestructor(CharacterData)
jsDestructor(Text)
jsDestructor(DocumentType)
jsDestructor(Attr)
jsDestructor(NamedNodeMap)
jsDestructor(CanvasRenderingContext2D)
jsDestructor(TextMetrics)

proc parseColor(element: Element, s: string): RGBAColor

proc resetTransform(state: var DrawingState) =
  state.transformMatrix = newIdentityMatrix(3)

proc resetState(state: var DrawingState) =
  state.resetTransform()
  state.fillStyle = rgba(0, 0, 0, 255)
  state.strokeStyle = rgba(0, 0, 0, 255)
  state.path = newPath()

proc create2DContext*(jctx: JSContext, target: HTMLCanvasElement,
    options: Option[JSValue]):
    CanvasRenderingContext2D =
  let ctx = CanvasRenderingContext2D(
    bitmap: target.bitmap,
    canvas: target
  )
  ctx.state.resetState()
  return ctx

# CanvasState
proc save(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  ctx.stateStack.add(ctx.state)

proc restore(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  if ctx.stateStack.len > 0:
    ctx.state = ctx.stateStack.pop()

proc reset(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  ctx.bitmap.clear()
  #TODO empty list of subpaths
  ctx.stateStack.setLen(0)
  ctx.state.resetState()

# CanvasTransform
#TODO scale
proc rotate(ctx: CanvasRenderingContext2D, angle: float64) {.jsfunc.} =
  if classify(angle) in {fcInf, fcNegInf, fcNan}:
    return
  ctx.state.transformMatrix *= newMatrix(
    me = @[
      cos(angle), -sin(angle), 0,
      sin(angle), cos(angle), 0,
      0, 0, 1
    ],
    w = 3,
    h = 3
  )

proc translate(ctx: CanvasRenderingContext2D, x, y: float64) {.jsfunc.} =
  for v in [x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  ctx.state.transformMatrix *= newMatrix(
    me = @[
      1f64, 0, x,
      0, 1, y,
      0, 0, 1
    ],
    w = 3,
    h = 3
  )

proc transform(ctx: CanvasRenderingContext2D, a, b, c, d, e, f: float64)
    {.jsfunc.} =
  for v in [a, b, c, d, e, f]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  ctx.state.transformMatrix *= newMatrix(
    me = @[
      a, c, e,
      b, d, f,
      0, 0, 1
    ],
    w = 3,
    h = 3
  )

#TODO getTransform, setTransform with DOMMatrix (i.e. we're missing DOMMatrix)
proc setTransform(ctx: CanvasRenderingContext2D, a, b, c, d, e, f: float64)
    {.jsfunc.} =
  for v in [a, b, c, d, e, f]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  ctx.state.resetTransform()
  ctx.transform(a, b, c, d, e, f)

proc resetTransform(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  ctx.state.resetTransform()

func transform(ctx: CanvasRenderingContext2D, v: Vector2D): Vector2D =
  let mul = ctx.state.transformMatrix * newMatrix(@[v.x, v.y, 1], 1, 3)
  return Vector2D(x: mul.me[0], y: mul.me[1])

# CanvasFillStrokeStyles
proc fillStyle(ctx: CanvasRenderingContext2D): string {.jsfget.} =
  return ctx.state.fillStyle.serialize()

proc fillStyle(ctx: CanvasRenderingContext2D, s: string) {.jsfset.} =
  #TODO gradient, pattern
  ctx.state.fillStyle = ctx.canvas.parseColor(s)

proc strokeStyle(ctx: CanvasRenderingContext2D): string {.jsfget.} =
  return ctx.state.strokeStyle.serialize()

proc strokeStyle(ctx: CanvasRenderingContext2D, s: string) {.jsfset.} =
  #TODO gradient, pattern
  ctx.state.strokeStyle = ctx.canvas.parseColor(s)

# CanvasRect
proc clearRect(ctx: CanvasRenderingContext2D, x, y, w, h: float64) {.jsfunc.} =
  for v in [x, y, w, h]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  #TODO clipping regions (right now we just clip to default)
  let bw = float64(ctx.bitmap.width)
  let bh = float64(ctx.bitmap.height)
  let x0 = uint64(min(max(x, 0), bw))
  let x1 = uint64(min(max(x + w, 0), bw))
  let y0 = uint64(min(max(y, 0), bh))
  let y1 = uint64(min(max(y + h, 0), bh))
  ctx.bitmap.clearRect(x0, x1, y0, y1)

proc fillRect(ctx: CanvasRenderingContext2D, x, y, w, h: float64) {.jsfunc.} =
  for v in [x, y, w, h]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  #TODO do we have to clip here?
  if w == 0 or h == 0:
    return
  let bw = float64(ctx.bitmap.width)
  let bh = float64(ctx.bitmap.height)
  let x0 = uint64(min(max(x, 0), bw))
  let x1 = uint64(min(max(x + w, 0), bw))
  let y0 = uint64(min(max(y, 0), bh))
  let y1 = uint64(min(max(y + h, 0), bh))
  ctx.bitmap.fillRect(x0, x1, y0, y1, ctx.state.fillStyle)

proc strokeRect(ctx: CanvasRenderingContext2D, x, y, w, h: float64) {.jsfunc.} =
  for v in [x, y, w, h]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  #TODO do we have to clip here?
  if w == 0 or h == 0:
    return
  let bw = float64(ctx.bitmap.width)
  let bh = float64(ctx.bitmap.height)
  let x0 = uint64(min(max(x, 0), bw))
  let x1 = uint64(min(max(x + w, 0), bw))
  let y0 = uint64(min(max(y, 0), bh))
  let y1 = uint64(min(max(y + h, 0), bh))
  ctx.bitmap.strokeRect(x0, x1, y0, y1, ctx.state.strokeStyle)

# CanvasDrawPath
proc beginPath(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  ctx.state.path.beginPath()

proc fill(ctx: CanvasRenderingContext2D,
    fillRule = CanvasFillRule.NON_ZERO) {.jsfunc.} = #TODO path
  ctx.state.path.tempClosePath()
  ctx.bitmap.fillPath(ctx.state.path, ctx.state.fillStyle, fillRule)
  ctx.state.path.tempOpenPath()

proc stroke(ctx: CanvasRenderingContext2D) {.jsfunc.} = #TODO path
  ctx.bitmap.strokePath(ctx.state.path, ctx.state.strokeStyle)

proc clip(ctx: CanvasRenderingContext2D,
    fillRule = CanvasFillRule.NON_ZERO) {.jsfunc.} = #TODO path
  #TODO implement
  discard

#TODO clip, ...

# CanvasUserInterface

# CanvasText
#TODO maxwidth
proc fillText(ctx: CanvasRenderingContext2D, text: string, x, y: float64) {.jsfunc.} =
  for v in [x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  let vec = ctx.transform(Vector2D(x: x, y: y))
  ctx.bitmap.fillText(text, vec.x, vec.y, ctx.state.fillStyle, ctx.state.textAlign)

#TODO maxwidth
proc strokeText(ctx: CanvasRenderingContext2D, text: string, x, y: float64) {.jsfunc.} =
  for v in [x, y]:
    if classify(v) in {fcInf, fcNegInf, fcNan}:
      return
  let vec = ctx.transform(Vector2D(x: x, y: y))
  ctx.bitmap.strokeText(text, vec.x, vec.y, ctx.state.strokeStyle, ctx.state.textAlign)

proc measureText(ctx: CanvasRenderingContext2D, text: string): TextMetrics
    {.jsfunc.} =
  let tw = text.width()
  return TextMetrics(
    width: 8 * float64(tw),
    actualBoundingBoxLeft: 0,
    actualBoundingBoxRight: 8 * float64(tw),
    #TODO and the rest...
  )

# CanvasDrawImage

# CanvasImageData

# CanvasPathDrawingStyles
proc lineWidth(ctx: CanvasRenderingContext2D): float64 {.jsfget.} =
  return ctx.state.lineWidth

proc lineWidth(ctx: CanvasRenderingContext2D, f: float64) {.jsfset.} =
  if classify(f) in {fcZero, fcNegZero, fcInf, fcNegInf, fcNan}:
    return
  ctx.state.lineWidth = f

proc setLineDash(ctx: CanvasRenderingContext2D, segments: seq[float64])
    {.jsfunc.} =
  discard #TODO implement

proc getLineDash(ctx: CanvasRenderingContext2D): seq[float64] {.jsfunc.} =
  discard #TODO implement

# CanvasTextDrawingStyles
proc textAlign(ctx: CanvasRenderingContext2D): string {.jsfget.} =
  case ctx.state.textAlign
  of TEXT_ALIGN_START: return "start"
  of TEXT_ALIGN_END: return "end"
  of TEXT_ALIGN_LEFT: return "left"
  of TEXT_ALIGN_RIGHT: return "right"
  of TEXT_ALIGN_CENTER: return "center"
  else: doAssert false

proc textAlign(ctx: CanvasRenderingContext2D, s: string) {.jsfset.} =
  ctx.state.textAlign = case s
  of "start": TEXT_ALIGN_START
  of "end": TEXT_ALIGN_END
  of "left": TEXT_ALIGN_LEFT
  of "right": TEXT_ALIGN_RIGHT
  of "center": TEXT_ALIGN_CENTER
  else: ctx.state.textAlign

# CanvasPath
proc closePath(ctx: CanvasRenderingContext2D) {.jsfunc.} =
  ctx.state.path.closePath()

proc moveTo(ctx: CanvasRenderingContext2D, x, y: float64) {.jsfunc.} =
  ctx.state.path.moveTo(x, y)

proc lineTo(ctx: CanvasRenderingContext2D, x, y: float64) {.jsfunc.} =
  ctx.state.path.lineTo(x, y)

proc quadraticCurveTo(ctx: CanvasRenderingContext2D, cpx, cpy, x,
    y: float64) {.jsfunc.} =
  ctx.state.path.quadraticCurveTo(cpx, cpy, x, y)

proc arcTo(ctx: CanvasRenderingContext2D, x1, y1, x2, y2, radius: float64):
    Err[DOMException] {.jsfunc.} =
  return ctx.state.path.arcTo(x1, y1, x2, y2, radius)

proc arc(ctx: CanvasRenderingContext2D, x, y, radius, startAngle,
    endAngle: float64, counterclockwise = false): Err[DOMException]
    {.jsfunc.} =
  return ctx.state.path.arc(x, y, radius, startAngle, endAngle,
    counterclockwise)

proc ellipse(ctx: CanvasRenderingContext2D, x, y, radiusX, radiusY, rotation,
    startAngle, endAngle: float64, counterclockwise = false): Err[DOMException]
    {.jsfunc.} =
  return ctx.state.path.ellipse(x, y, radiusX, radiusY, rotation, startAngle,
    endAngle, counterclockwise)

proc rect(ctx: CanvasRenderingContext2D, x, y, w, h: float64) {.jsfunc.} =
  ctx.state.path.rect(x, y, w, h)

proc roundRect(ctx: CanvasRenderingContext2D, x, y, w, h, radii: float64) {.jsfunc.} =
  ctx.state.path.roundRect(x, y, w, h, radii)

# Reflected attributes.
type
  ReflectType = enum
    REFLECT_STR, REFLECT_BOOL, REFLECT_LONG, REFLECT_ULONG_GZ, REFLECT_ULONG

  ReflectEntry = object
    attrname: string
    funcname: string
    tags: set[TagType]
    case t: ReflectType
    of REFLECT_LONG:
      i: int32
    of REFLECT_ULONG, REFLECT_ULONG_GZ:
      u: uint32
    else: discard

template toset(ts: openarray[TagType]): set[TagType] =
  var tags: system.set[TagType]
  for tag in ts:
    tags.incl(tag)
  tags

func makes(name: string, ts: set[TagType]): ReflectEntry =
  ReflectEntry(
    attrname: name,
    funcname: name,
    t: REFLECT_STR,
    tags: ts
  )

func makes(attrname: string, funcname: string, ts: set[TagType]):
    ReflectEntry =
  ReflectEntry(
    attrname: attrname,
    funcname: funcname,
    t: REFLECT_STR,
    tags: ts
  )

func makes(name: string, ts: varargs[TagType]): ReflectEntry =
  makes(name, toset(ts))

func makes(attrname, funcname: string, ts: varargs[TagType]): ReflectEntry =
  makes(attrname, funcname, toset(ts))

func makeb(attrname, funcname: string, ts: varargs[TagType]):
    ReflectEntry =
  ReflectEntry(
    attrname: attrname,
    funcname: funcname,
    t: REFLECT_BOOL,
    tags: toset(ts)
  )

func makeb(name: string, ts: varargs[TagType]): ReflectEntry =
  makeb(name, name, ts)

template makeul(name: string, ts: varargs[TagType], default = 0u32): ReflectEntry =
  ReflectEntry(
    attrname: name,
    funcname: name,
    t: REFLECT_ULONG,
    tags: toset(ts),
    u: default
  )

template makeulgz(name: string, ts: varargs[TagType], default = 0u32): ReflectEntry =
  ReflectEntry(
    attrname: name,
    funcname: name,
    t: REFLECT_ULONG_GZ,
    tags: toset(ts),
    u: default
  )

const ReflectTable0 = [
  # non-global attributes
  makes("target", TAG_A, TAG_AREA, TAG_LABEL, TAG_LINK),
  makes("href", TAG_LINK),
  makeb("required", TAG_INPUT, TAG_SELECT, TAG_TEXTAREA),
  makes("rel", "relList", TAG_A, TAG_LINK, TAG_LABEL),
  makes("for", "htmlFor", TAG_LABEL),
  makeul("cols", TAG_TEXTAREA, 20u32),
  makeul("rows", TAG_TEXTAREA, 1u32),
# <SELECT>:
#> For historical reasons, the default value of the size IDL attribute does
#> not return the actual size used, which, in the absence of the size content
#> attribute, is either 1 or 4 depending on the presence of the multiple
#> attribute.
  makeulgz("size", TAG_SELECT, 0u32),
  makeulgz("size", TAG_INPUT, 20u32),
  makeul("width", TAG_CANVAS, 300u32),
  makeul("height", TAG_CANVAS, 150u32),
  makes("alt", TAG_IMG),
  makes("src", TAG_IMG, TAG_SCRIPT),
  makes("srcset", TAG_IMG),
  makes("sizes", TAG_IMG),
  #TODO can we add crossOrigin here?
  makes("usemap", "useMap", TAG_IMG),
  makeb("ismap", "isMap", TAG_IMG),
  # "super-global" attributes
  makes("slot", AllTagTypes),
  makes("class", "className", AllTagTypes)
]

# Forward declarations
func attrb*(element: Element, s: string): bool
proc attr*(element: Element, name, value: string)

proc tostr(ftype: enum): string =
  return ($ftype).split('_')[1..^1].join("-").tolower()

func escapeText(s: string, attribute_mode = false): string =
  var nbsp_mode = false
  var nbsp_prev: char
  for c in s:
    if nbsp_mode:
      if c == char(0xA0):
        result &= "&nbsp;"
      else:
        result &= nbsp_prev & c
      nbsp_mode = false
    elif c == '&':
      result &= "&amp;"
    elif c == char(0xC2):
      nbsp_mode = true
      nbsp_prev = c
    elif attribute_mode and c == '"':
      result &= "&quot;"
    elif not attribute_mode and c == '<':
      result &= "&lt;"
    elif not attribute_mode and c == '>':
      result &= "&gt;"
    else:
      result &= c

func `$`*(node: Node): string =
  if node == nil: return "null" #TODO this isn't standard compliant but helps debugging
  case node.nodeType
  of ELEMENT_NODE:
    let element = Element(node)
    result = "<" & $element.tagType.tostr()
    for k, v in element.attrs:
      result &= ' ' & k & "=\"" & v.escapeText(true) & "\""
    result &= ">\n"
    for node in element.childList:
      for line in ($node).split('\n'):
        result &= "\t" & line & "\n"
    result &= "</" & $element.tagType.tostr() & ">"
  of TEXT_NODE:
    let text = Text(node)
    result = text.data.escapeText()
  of COMMENT_NODE:
    result = "<!-- " & Comment(node).data & "-->"
  of PROCESSING_INSTRUCTION_NODE:
    result = "" #TODO
  of DOCUMENT_TYPE_NODE:
    result = "<!DOCTYPE" & ' ' & DocumentType(node).name & ">"
  else:
    result = "Node of " & $node.nodeType

iterator elementList*(node: Node): Element {.inline.} =
  for child in node.childList:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator elementList_rev*(node: Node): Element {.inline.} =
  for i in countdown(node.childList.high, 0):
    let child = node.childList[i]
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

# Returns the node's ancestors
iterator ancestors*(node: Node): Element {.inline.} =
  var element = node.parentElement
  while element != nil:
    yield element
    element = element.parentElement

# Returns the node itself and its ancestors
iterator branch*(node: Node): Node {.inline.} =
  var node = node
  while node != nil:
    yield node
    node = node.parentNode

# Returns the node's descendants
iterator descendants*(node: Node): Node {.inline.} =
  var stack: seq[Node]
  stack.add(node)
  while stack.len > 0:
    let node = stack.pop()
    for i in countdown(node.childList.high, 0):
      yield node.childList[i]
      stack.add(node.childList[i])

iterator elements*(node: Node): Element {.inline.} =
  for child in node.descendants:
    if child.nodeType == ELEMENT_NODE:
      yield Element(child)

iterator elements*(node: Node, tag: TagType): Element {.inline.} =
  for desc in node.elements:
    if desc.tagType == tag:
      yield desc

iterator elements*(node: Node, tag: set[TagType]): Element {.inline.} =
  for desc in node.elements:
    if desc.tagType in tag:
      yield desc

iterator inputs(form: HTMLFormElement): HTMLInputElement {.inline.} =
  for control in form.controls:
    if control.tagType == TAG_INPUT:
      yield HTMLInputElement(control)

iterator radiogroup(form: HTMLFormElement): HTMLInputElement {.inline.} =
  for input in form.inputs:
    if input.inputType == INPUT_RADIO:
      yield input

iterator radiogroup(document: Document): HTMLInputElement {.inline.} =
  for input in document.elements(TAG_INPUT):
    let input = HTMLInputElement(input)
    if input.form == nil and input.inputType == INPUT_RADIO:
      yield input

iterator radiogroup*(input: HTMLInputElement): HTMLInputElement {.inline.} =
  if input.form != nil:
    for input in input.form.radiogroup:
      yield input
  else:
    for input in input.document.radiogroup:
      yield input

iterator textNodes*(node: Node): Text {.inline.} =
  for node in node.childList:
    if node.nodeType == TEXT_NODE:
      yield Text(node)
  
iterator options*(select: HTMLSelectElement): HTMLOptionElement {.inline.} =
  for child in select.elementList:
    if child.tagType == TAG_OPTION:
      yield HTMLOptionElement(child)
    elif child.tagType == TAG_OPTGROUP:
      for opt in child.elementList:
        if opt.tagType == TAG_OPTION:
          yield HTMLOptionElement(opt)

proc populateCollection(collection: Collection) =
  if collection.childonly:
    for child in collection.root.childList:
      if collection.match == nil or collection.match(child):
        collection.snapshot.add(child)
  else:
    for desc in collection.root.descendants:
      if collection.match == nil or collection.match(desc):
        collection.snapshot.add(desc)
  if collection.islive:
    for child in collection.snapshot:
      child.liveCollections.incl(collection.id)

proc refreshCollection(collection: Collection) =
  let document = collection.root.document
  if collection.id in document.invalidCollections:
    for child in collection.snapshot:
      assert collection.id in child.liveCollections
      child.liveCollections.excl(collection.id)
    collection.snapshot.setLen(0)
    collection.populateCollection()
    document.invalidCollections.excl(collection.id)

proc finalize0(collection: Collection) =
  if collection.islive:
    for child in collection.snapshot:
      assert collection.id in child.liveCollections
      child.liveCollections.excl(collection.id)
    collection.root.document.invalidCollections.excl(collection.id)

proc finalize(collection: HTMLCollection) {.jsfin.} =
  collection.finalize0()

proc finalize(collection: NodeList) {.jsfin.} =
  collection.finalize0()

func ownerDocument(node: Node): Document {.jsfget.} =
  if node.nodeType == DOCUMENT_NODE:
    return nil
  return node.document

func hasChildNodes(node: Node): bool {.jsfget.} =
  return node.childList.len > 0

func len(collection: Collection): int =
  collection.refreshCollection()
  return collection.snapshot.len

type CollectionMatchFun = proc(node: Node): bool {.noSideEffect.}

func newCollection[T: Collection](root: Node, match: CollectionMatchFun,
    islive, childonly: bool): T =
  result = T(
    islive: islive,
    childonly: childonly,
    match: match,
    root: root,
    id: root.document.colln
  )
  inc root.document.colln
  result.populateCollection()

func nodeType(node: Node): uint16 {.jsfget.} =
  return uint16(node.nodeType)

func isElement(node: Node): bool =
  return node.nodeType == ELEMENT_NODE

func children(node: Node): HTMLCollection {.jsfget.} =
  if node.children_cached == nil:
    node.children_cached = newCollection[HTMLCollection](
      root = node,
      match = isElement,
      islive = true,
      childonly = true
    )
  return node.children_cached

func childNodes(node: Node): NodeList {.jsfget.} =
  if node.childNodes_cached == nil:
    node.childNodes_cached = newCollection[NodeList](
      root = node,
      match = nil,
      islive = true,
      childonly = true
    )
  return node.childNodes_cached

# DOMTokenList
func length(tokenList: DOMTokenList): int {.jsfget.} =
  return tokenList.toks.len

func item(tokenList: DOMTokenList, i: int): Option[string] {.jsfunc.} =
  if i < tokenList.toks.len:
    return some(tokenList.toks[i])

func contains*(tokenList: DOMTokenList, s: string): bool {.jsfunc.} =
  return s in tokenList.toks

proc update(tokenList: DOMTokenList) =
  if not tokenList.element.attrb(tokenList.localName) and tokenList.toks.len == 0:
    return
  tokenList.element.attr(tokenList.localName, tokenList.toks.join(' '))

func validateDOMToken(tok: string): Err[DOMException] =
  if tok == "":
    return err(newDOMException("Got an empty string", "SyntaxError"))
  if AsciiWhitespace in tok:
    return err(newDOMException("Got a string containing whitespace",
      "InvalidCharacterError"))

proc add(tokenList: DOMTokenList, tokens: varargs[string]): Err[DOMException]
    {.jsfunc.} =
  for tok in tokens:
    ?validateDOMToken(tok)
  for tok in tokens:
    tokenList.toks.add(tok)
  tokenList.update()
  return ok()

proc remove(tokenList: DOMTokenList, tokens: varargs[string]):
    Err[DOMException] {.jsfunc.} =
  for tok in tokens:
    ?validateDOMToken(tok)
  for tok in tokens:
    let i = tokenList.toks.find(tok)
    if i != -1:
      tokenList.toks.delete(i)
  tokenList.update()
  return ok()

proc toggle(tokenList: DOMTokenList, token: string, force = none(bool)):
    Result[bool, DOMException] {.jsfunc.} =
  ?validateDOMToken(token)
  let i = tokenList.toks.find(token)
  if i != -1:
    if not force.get(false):
      tokenList.toks.delete(i)
      tokenList.update()
      return ok(false)
    return ok(true)
  if force.get(true):
    tokenList.toks.add(token)
    tokenList.update()
    return ok(true)
  return ok(false)

proc replace(tokenList: DOMTokenList, token, newToken: string):
    Result[bool, DOMException] {.jsfunc.} =
  ?validateDOMToken(token)
  ?validateDOMToken(newToken)
  let i = tokenList.toks.find(token)
  if i == -1:
    return ok(false)
  tokenList.toks[i] = newToken
  tokenList.update()
  return ok(true)

const SupportedTokensMap = {
  "abcd": @["adsf"] #TODO
}.toTable()

func supports(tokenList: DOMTokenList, token: string):
    Result[bool, JSError] {.jsfunc.} =
  if tokenList.localName in SupportedTokensMap:
    let lowercase = token.toLowerAscii()
    return ok(lowercase in SupportedTokensMap[tokenList.localName])
  return err(newTypeError("No supported tokens defined for attribute " &
    tokenList.localName))

func `$`(tokenList: DOMTokenList): string {.jsfunc.} =
  return tokenList.toks.join(' ')

func value(tokenList: DOMTokenList): string {.jsfget.} =
  return $tokenList

func getter(tokenList: DOMTokenList, i: int): Option[string] {.jsgetprop.} =
  return tokenList.item(i)

# NodeList
func length(nodeList: NodeList): int {.jsfget.} =
  return nodeList.len

func hasprop(nodeList: NodeList, i: int): bool {.jshasprop.} =
  return i < nodeList.len

func item(nodeList: NodeList, i: int): Node {.jsfunc.} =
  if i < nodeList.len:
    return nodeList.snapshot[i]

func getter(nodeList: NodeList, i: int): Option[Node] {.jsgetprop.} =
  return option(nodeList.item(i))

# HTMLCollection
proc length(collection: HTMLCollection): int {.jsfget.} =
  return collection.len

func hasprop(collection: HTMLCollection, i: int): bool {.jshasprop.} =
  return i < collection.len

func item(collection: HTMLCollection, i: int): Element {.jsfunc.} =
  if i < collection.len:
    return Element(collection.snapshot[i])

func getter(collection: HTMLCollection, i: int): Option[Element] {.jsgetprop.} =
  return option(collection.item(i))

proc newLocation*(window: Window): Location =
  let location = Location(window: window)
  let ctx = window.jsctx
  if ctx != nil:
    let val = toJS(ctx, location)
    let valueOf = ctx.getOpaque().Object_prototype_valueOf
    defineProperty(ctx, val, "valueOf", valueOf)
    defineProperty(ctx, val, "toPrimitive", JS_UNDEFINED)
    #TODO [[DefaultProperties]]
    JS_FreeValue(ctx, val)
  return location

func location(document: Document): Location {.jsfget.} =
  return document.window.location

func document(location: Location): Document =
  return location.window.document

func url(location: Location): URL =
  let document = location.document
  if document != nil:
    return document.url
  return newURL("about:blank").get

proc setLocation*(document: Document, s: string): Err[DOMException]
    {.jsfset: "location".} =
  let url = parseURL(s)
  if url.isNone:
    return err(newDOMException("Invalid URL", "SyntaxError"))
  document.window.navigate(url.get)
  return ok()

# Note: we do not implement security checks (as documents are in separate
# windows anyway).
func href(location: Location): string {.jsfget.} =
  return location.url.serialize()

proc setHref(location: Location, s: string): Err[DOMException]
    {.jsfset: "href".} =
  if location.document == nil:
    return ok()
  return location.document.setLocation(s)

proc assign(location: Location, s: string): Err[DOMException] {.jsfunc.} =
  location.setHref(s)

proc replace(location: Location, s: string): Err[DOMException] {.jsfunc.} =
  location.setHref(s)

proc reload(location: Location) {.jsfunc.} =
  if location.document == nil:
    return
  location.document.window.navigate(location.url)

func origin(location: Location): string {.jsfget.} =
  return location.url.origin

func protocol(location: Location): string {.jsfget.} =
  return location.url.protocol

proc protocol(location: Location, s: string): Err[DOMException] {.jsfset.} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setProtocol(s)
  if copyURL.scheme != "http" and copyURL.scheme != "https":
    return err(newDOMException("Invalid URL", "SyntaxError"))
  document.window.navigate(copyURL)
  return ok()

func host(location: Location): string {.jsfget.} =
  return location.url.host

proc setHost(location: Location, s: string) {.jsfset: "host".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setHost(s)
  document.window.navigate(copyURL)

proc hostname(location: Location): string {.jsfget.} =
  return location.url.hostname

proc setHostname(location: Location, s: string) {.jsfset: "hostname".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setHostname(s)
  document.window.navigate(copyURL)

proc port(location: Location): string {.jsfget.} =
  return location.url.port

proc setPort(location: Location, s: string) {.jsfset: "port".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setPort(s)
  document.window.navigate(copyURL)

proc pathname(location: Location): string {.jsfget.} =
  return location.url.pathname

proc setPathname(location: Location, s: string) {.jsfset: "pathname".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setPathname(s)
  document.window.navigate(copyURL)

proc search(location: Location): string {.jsfget.} =
  return location.url.search

proc setSearch(location: Location, s: string) {.jsfset: "search".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setSearch(s)
  document.window.navigate(copyURL)

proc hash(location: Location): string {.jsfget.} =
  return location.url.hash

proc setHash(location: Location, s: string) {.jsfset: "hash".} =
  let document = location.document
  if document == nil:
    return
  let copyURL = newURL(location.url)
  copyURL.setHash(s)
  document.window.navigate(copyURL)

func newAttr(parent: Element, localName, value: string, prefix = "", namespaceURI = ""): Attr =
  return Attr(
    nodeType: ATTRIBUTE_NODE,
    document: parent.document,
    namespaceURI: namespaceURI,
    ownerElement: parent,
    localName: localName,
    prefix: prefix,
    value: value,
    index: -1
  )

func name(attr: Attr): string {.jsfget.} =
  if attr.prefix == "":
    return attr.localName
  return attr.prefix & ':' & attr.localName

func findAttr(map: NamedNodeMap, name: string): int =
  for i in 0 ..< map.attrlist.len:
    if map.attrlist[i].name == name:
      return i
  return -1

func findAttrNS(map: NamedNodeMap, namespace, localName: string): int =
  for i in 0 ..< map.attrlist.len:
    if map.attrlist[i].namespaceURI == namespace and map.attrlist[i].localName == localName:
      return i
  return -1

func hasAttribute(element: Element, qualifiedName: string): bool {.jsfunc.} =
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  if qualifiedName in element.attrs:
    return true

func hasAttributeNS(element: Element, namespace, localName: string): bool {.jsfunc.} =
  return element.attributes.findAttrNS(namespace, localName) != -1

func getAttribute(element: Element, qualifiedName: string): Option[string] {.jsfunc.} =
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  element.attrs.withValue(qualifiedName, val):
    return some(val[])

func getAttributeNS(element: Element, namespace, localName: string): Option[string] {.jsfunc.} =
  let i = element.attributes.findAttrNS(namespace, localName)
  if i != -1:
    return some(element.attributes.attrlist[i].value)

func getNamedItem(map: NamedNodeMap, qualifiedName: string): Option[Attr] {.jsfunc.} =
  if map.element.hasAttribute(qualifiedName):
    let i = map.findAttr(qualifiedName)
    if i != -1:
      return some(map.attrlist[i])

func getNamedItemNS(map: NamedNodeMap, namespace, localName: string): Option[Attr] {.jsfunc.} =
  let i = map.findAttrNS(namespace, localName)
  if i != -1:
    return some(map.attrlist[i])

func length(map: NamedNodeMap): int {.jsfget.} =
  return map.element.attrs.len

func item(map: NamedNodeMap, i: int): Option[Attr] {.jsfunc.} =
  if i < map.attrlist.len:
    return some(map.attrlist[i])

func hasprop[T: int|string](map: NamedNodeMap, i: T): bool {.jshasprop.} =
  when T is int:
    return i < map.attrlist.len
  else:
    return map.getNamedItem(i).isSome

func getter[T: int|string](map: NamedNodeMap, i: T): Option[Attr] {.jsgetprop.} =
  when T is int:
    return map.item(i)
  else:
    return map.getNamedItem(i)

func length(characterData: CharacterData): int {.jsfget.} =
  return characterData.data.utf16Len

func scriptingEnabled*(element: Element): bool =
  if element.document == nil:
    return false
  if element.document.window == nil:
    return false
  return element.document.window.settings.scripting

func form*(element: FormAssociatedElement): HTMLFormElement =
  case element.tagType
  of TAG_INPUT: return HTMLInputElement(element).form
  of TAG_SELECT: return HTMLSelectElement(element).form
  of TAG_BUTTON: return HTMLButtonElement(element).form
  of TAG_TEXTAREA: return HTMLTextAreaElement(element).form
  else: assert false

func `form=`*(element: FormAssociatedElement, form: HTMLFormElement) =
  case element.tagType
  of TAG_INPUT: HTMLInputElement(element).form = form
  of TAG_SELECT:  HTMLSelectElement(element).form = form
  of TAG_BUTTON: HTMLButtonElement(element).form = form
  of TAG_TEXTAREA: HTMLTextAreaElement(element).form = form
  else: assert false

func canSubmitImplicitly*(form: HTMLFormElement): bool =
  const BlocksImplicitSubmission = {
    INPUT_TEXT, INPUT_SEARCH, INPUT_URL, INPUT_TEL, INPUT_EMAIL, INPUT_PASSWORD,
    INPUT_DATE, INPUT_MONTH, INPUT_WEEK, INPUT_TIME, INPUT_DATETIME_LOCAL,
    INPUT_NUMBER
  }
  var found = false
  for control in form.controls:
    if control.tagType == TAG_INPUT:
      let input = HTMLInputElement(control)
      if input.inputType in BlocksImplicitSubmission:
        if found:
          return false
        else:
          found = true
  return true

func qualifiedName*(element: Element): string =
  if element.namespacePrefix.issome: element.namespacePrefix.get & ':' & element.localName
  else: element.localName

func html*(document: Document): HTMLElement =
  for element in document.elements(TAG_HTML):
    return HTMLElement(element)

func head*(document: Document): HTMLElement =
  let html = document.html
  if html != nil:
    for element in html.elements(TAG_HEAD):
      return HTMLElement(element)

func body*(document: Document): HTMLElement =
  let html = document.html
  if html != nil:
    for element in html.elements(TAG_BODY):
      return HTMLElement(element)

func select*(option: HTMLOptionElement): HTMLSelectElement =
  for anc in option.ancestors:
    if anc.tagType == TAG_SELECT:
      return HTMLSelectElement(anc)
  return nil

func countChildren(node: Node, nodeType: NodeType): int =
  for child in node.childList:
    if child.nodeType == nodeType:
      inc result

func hasChild(node: Node, nodeType: NodeType): bool =
  for child in node.childList:
    if child.nodeType == nodeType:
      return false

func previousSibling*(node: Node): Node {.jsfget.} =
  let i = node.index - 1
  if node.parentNode == nil or i < 0:
    return nil
  return node.parentNode.childList[i]

func nextSibling*(node: Node): Node {.jsfget.} =
  let i = node.index + 1
  if node.parentNode == nil or i >= node.parentNode.childList.len:
    return nil
  return node.parentNode.childList[i]

func hasNextSibling(node: Node, nodeType: NodeType): bool =
  var node = node.nextSibling
  while node != nil:
    if node.nodeType == nodeType: return true
    node = node.nextSibling
  return false

func hasPreviousSibling(node: Node, nodeType: NodeType): bool =
  var node = node.previousSibling
  while node != nil:
    if node.nodeType == nodeType: return true
    node = node.previousSibling
  return false

func nodeValue(node: Node): Option[string] {.jsfget.} =
  case node.nodeType
  of CharacterDataNodes:
    return some(CharacterData(node).data)
  of ATTRIBUTE_NODE:
    return some(Attr(node).value)
  else: discard

func textContent*(node: Node): string {.jsfget.} =
  case node.nodeType
  of DOCUMENT_NODE, DOCUMENT_TYPE_NODE:
    return "" #TODO null
  of CharacterDataNodes:
    return CharacterData(node).data
  else:
    for child in node.childList:
      if child.nodeType != COMMENT_NODE:
        result &= child.textContent

func childTextContent*(node: Node): string =
  for child in node.childList:
    if child.nodeType == TEXT_NODE:
      result &= Text(child).data

func rootNode*(node: Node): Node =
  if node.root == nil: return node
  return node.root

func isConnected*(node: Node): bool {.jsfget.} =
  return node.rootNode.nodeType == DOCUMENT_NODE #TODO shadow root

func inSameTree*(a, b: Node): bool =
  a.rootNode == b.rootNode

# a == b or b in a's ancestors
func contains*(a, b: Node): bool =
  for node in a.branch:
    if node == b: return true
  return false

func firstChild*(node: Node): Node {.jsfget.} =
  if node.childList.len == 0:
    return nil
  return node.childList[0]

func lastChild*(node: Node): Node {.jsfget.} =
  if node.childList.len == 0:
    return nil
  return node.childList[^1]

func firstElementChild*(node: Node): Element {.jsfget.} =
  for child in node.elementList:
    return child
  return nil

func lastElementChild*(node: Node): Element {.jsfget.} =
  for child in node.elementList:
    return child
  return nil

func findAncestor*(node: Node, tagTypes: set[TagType]): Element =
  for element in node.ancestors:
    if element.tagType in tagTypes:
      return element
  return nil

func getElementById*(node: Node, id: string): Element {.jsfunc.} =
  if id.len == 0:
    return nil
  for child in node.elements:
    if child.id == id:
      return child

func getElementsByTag*(node: Node, tag: TagType): seq[Element] =
  for element in node.elements(tag):
    result.add(element)

func getElementsByTagName0(root: Node, tagName: string): HTMLCollection =
  if tagName == "*":
    return newCollection[HTMLCollection](root, func(node: Node): bool = node.isElement, true, false)
  let t = tagType(tagName)
  if t != TAG_UNKNOWN:
    return newCollection[HTMLCollection](root, func(node: Node): bool = node.isElement and Element(node).tagType == t, true, false)

func getElementsByTagName(document: Document, tagName: string): HTMLCollection {.jsfunc.} =
  return document.getElementsByTagName0(tagName)

func getElementsByTagName(element: Element, tagName: string): HTMLCollection {.jsfunc.} =
  return element.getElementsByTagName0(tagName)

func getElementsByClassName0(node: Node, classNames: string): HTMLCollection =
  var classes = classNames.split(AsciiWhitespace)
  let isquirks = node.document.mode == QUIRKS
  if isquirks:
    for i in 0 .. classes.high:
      classes[i].mtoLowerAscii()
  return newCollection[HTMLCollection](node,
    func(node: Node): bool =
      if node.nodeType == ELEMENT_NODE:
        if isquirks:
          var cl = Element(node).classList
          for i in 0 .. cl.toks.high:
            cl.toks[i].mtoLowerAscii()
          for class in classes:
            if class notin cl:
              return false
        else:
          for class in classes:
            if class notin Element(node).classList:
              return false
        return true, true, false)

func getElementsByClassName(document: Document, classNames: string): HTMLCollection {.jsfunc.} =
  return document.getElementsByClassName0(classNames)

func getElementsByClassName(element: Element, classNames: string): HTMLCollection {.jsfunc.} =
  return element.getElementsByClassName0(classNames)

func previousElementSibling*(elem: Element): Element {.jsfget.} =
  if elem.parentNode == nil: return nil
  var i = elem.index - 1
  while i >= 0:
    if elem.parentNode.childList[i].nodeType == ELEMENT_NODE:
      return elem
    dec i
  return nil

func nextElementSibling*(elem: Element): Element {.jsfget.} =
  if elem.parentNode == nil: return nil
  var i = elem.index + 1
  while i < elem.parentNode.childList.len:
    if elem.parentNode.childList[i].nodeType == ELEMENT_NODE:
      return elem
    inc i
  return nil

func documentElement(document: Document): Element {.jsfget.} =
  document.firstElementChild()

func attr*(element: Element, s: string): string {.inline.} =
  return element.attrs.getOrDefault(s, "")

func attrl*(element: Element, s: string): Option[int32] =
  return parseInt32(element.attr(s))

func attrulgz*(element: Element, s: string): Option[uint32] =
  let x = parseUInt32(element.attr(s))
  if x.isSome and x.get > 0:
    return x

func attrul*(element: Element, s: string): Option[uint32] =
  let x = parseUInt32(element.attr(s))
  if x.isSome and x.get >= 0:
    return x

func attrb*(element: Element, s: string): bool =
  if s in element.attrs:
    return true
  return false

# Element attribute reflection (getters)
func innerHTML*(element: Element): string {.jsfget.} =
  for child in element.childList:
    result &= $child

func outerHTML*(element: Element): string {.jsfget.} =
  return $element

func crossOrigin0(element: HTMLElement): CORSAttribute =
  if not element.attrb("crossorigin"):
    return NO_CORS
  case element.attr("crossorigin")
  of "anonymous", "":
    return ANONYMOUS
  of "use-credentials":
    return USE_CREDENTIALS
  return ANONYMOUS

func crossOrigin(element: HTMLScriptElement): CORSAttribute {.jsfget.} =
  return element.crossOrigin0

func crossOrigin(element: HTMLImageElement): CORSAttribute {.jsfget.} =
  return element.crossOrigin0

func referrerpolicy(element: HTMLScriptElement): Option[ReferrerPolicy] =
  getReferrerPolicy(element.attr("referrerpolicy"))

proc sheets*(document: Document): seq[CSSStylesheet] =
  if document.cachedSheetsInvalid:
    document.cachedSheets.setLen(0)
    for elem in document.html.elements({TAG_STYLE, TAG_LINK}):
      case elem.tagType
      of TAG_STYLE:
        let style = HTMLStyleElement(elem)
        style.sheet = parseStylesheet(newStringStream(style.textContent))
        if style.sheet != nil:
          document.cachedSheets.add(style.sheet)
      of TAG_LINK:
        let link = HTMLLinkElement(elem)
        if link.sheet != nil:
          document.cachedSheets.add(link.sheet)
      else: discard
    document.cachedSheetsInvalid = false
  return document.cachedSheets

func inputString*(input: HTMLInputElement): string =
  case input.inputType
  of INPUT_CHECKBOX, INPUT_RADIO:
    if input.checked: "*"
    else: " "
  of INPUT_SEARCH, INPUT_TEXT:
    input.value.padToWidth(int(input.attrulgz("size").get(20)))
  of INPUT_PASSWORD:
    '*'.repeat(input.value.len).padToWidth(int(input.attrulgz("size").get(20)))
  of INPUT_RESET:
    if input.value != "": input.value
    else: "RESET"
  of INPUT_SUBMIT, INPUT_BUTTON:
    if input.value != "": input.value
    else: "SUBMIT"
  of INPUT_FILE:
    if input.file.isnone:
      "".padToWidth(int(input.attrulgz("size").get(20)))
    else:
      input.file.get.path.serialize_unicode().padToWidth(int(input.attrulgz("size").get(20)))
  else: input.value

func textAreaString*(textarea: HTMLTextAreaElement): string =
  let split = textarea.value.split('\n')
  let rows = int(textarea.attrul("rows").get(1))
  for i in 0 ..< rows:
    let cols = int(textarea.attrul("cols").get(20))
    if cols > 2:
      if i < split.len:
        result &= '[' & split[i].padToWidth(cols - 2) & "]\n"
      else:
        result &= '[' & ' '.repeat(cols - 2) & "]\n"
    else:
      result &= "[]\n"

func isButton*(element: Element): bool =
  if element.tagType == TAG_BUTTON:
    return true
  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    return element.inputType in {INPUT_SUBMIT, INPUT_BUTTON, INPUT_RESET, INPUT_IMAGE}
  return false

func isSubmitButton*(element: Element): bool =
  if element.tagType == TAG_BUTTON:
    return element.attr("type") == "submit"
  elif element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    return element.inputType in {INPUT_SUBMIT, INPUT_IMAGE}
  return false

func action*(element: Element): string =
  if element.isSubmitButton():
    if element.attrb("formaction"):
      return element.attr("formaction")
  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    if element.form != nil:
      if element.form.attrb("action"):
        return element.form.attr("action")
  if element.tagType == TAG_FORM:
    return element.attr("action")
  return ""

func enctype*(element: Element): FormEncodingType =
  if element.isSubmitButton():
    if element.attrb("formenctype"):
      return case element.attr("formenctype").tolower()
      of "application/x-www-form-urlencoded": FORM_ENCODING_TYPE_URLENCODED
      of "multipart/form-data": FORM_ENCODING_TYPE_MULTIPART
      of "text/plain": FORM_ENCODING_TYPE_TEXT_PLAIN
      else: FORM_ENCODING_TYPE_URLENCODED

  if element.tagType == TAG_INPUT:
    let element = HTMLInputElement(element)
    if element.form != nil:
      if element.form.attrb("enctype"):
        return case element.attr("enctype").tolower()
        of "application/x-www-form-urlencoded": FORM_ENCODING_TYPE_URLENCODED
        of "multipart/form-data": FORM_ENCODING_TYPE_MULTIPART
        of "text/plain": FORM_ENCODING_TYPE_TEXT_PLAIN
        else: FORM_ENCODING_TYPE_URLENCODED

  return FORM_ENCODING_TYPE_URLENCODED

func formmethod*(element: Element): FormMethod =
  if element.isSubmitButton():
    if element.attrb("formmethod"):
      return case element.attr("formmethod").tolower()
      of "get": FORM_METHOD_GET
      of "post": FORM_METHOD_POST
      of "dialog": FORM_METHOD_DIALOG
      else: FORM_METHOD_GET

  if element.tagType in SupportedFormAssociatedElements:
    let element = FormAssociatedElement(element)
    if element.form != nil:
      if element.form.attrb("method"):
        return case element.form.attr("method").tolower()
        of "get": FORM_METHOD_GET
        of "post": FORM_METHOD_POST
        of "dialog": FORM_METHOD_DIALOG
        else: FORM_METHOD_GET

  return FORM_METHOD_GET

proc parseColor(element: Element, s: string): RGBAColor =
  let cval = parseComponentValue(newStringStream(s))
  #TODO TODO TODO return element style
  # For now we just use white.
  let ec = rgb(255, 255, 255)
  if cval.isErr:
    return ec
  return cssColor(cval.get).get(ec)

#TODO ??
func target0*(element: Element): string =
  if element.attrb("target"):
    return element.attr("target")
  for base in element.document.elements(TAG_BASE):
    if base.attrb("target"):
      return base.attr("target")
  return ""

# HTMLHyperlinkElementUtils (for <a> and <area>)
func href0[T: HTMLAnchorElement|HTMLAreaElement](element: T): string =
  if element.attrb("href"):
    let url = parseUrl(element.attr("href"), some(element.document.url))
    if url.issome:
      return $url.get

# <base>
func href(base: HTMLBaseElement): string {.jsfget.} =
  if base.attrb("href"):
    #TODO with fallback base url
    let url = parseUrl(base.attr("href"))
    if url.isSome:
      return $url.get

# <a>
func href*(anchor: HTMLAnchorElement): string {.jsfget.} =
  anchor.href0

proc href(anchor: HTMLAnchorElement, href: string) {.jsfset.} =
  anchor.attr("href", href)

func `$`(anchor: HTMLAnchorElement): string {.jsfunc.} =
  anchor.href

# <area>
func href(area: HTMLAreaElement): string {.jsfget.} =
  area.href0

proc href(area: HTMLAreaElement, href: string) {.jsfset.} =
  area.attr("href", href)

func `$`(area: HTMLAreaElement): string {.jsfunc.} =
  area.href

# <label>
func control*(label: HTMLLabelElement): FormAssociatedElement {.jsfget.} =
  let f = label.attr("for")
  if f != "":
    let elem = label.document.getElementById(f)
    #TODO the supported check shouldn't be needed, just labelable
    if elem.tagType in SupportedFormAssociatedElements and elem.tagType in LabelableElements:
      return FormAssociatedElement(elem)
    return nil
  for elem in label.elements(LabelableElements):
    if elem.tagType in SupportedFormAssociatedElements: #TODO remove this
      return FormAssociatedElement(elem)
    return nil

func form(label: HTMLLabelElement): HTMLFormElement {.jsfget.} =
  let control = label.control
  if control != nil:
    return control.form

func newText(document: Document, data: string): Text =
  return Text(
    nodeType: TEXT_NODE,
    document: document,
    data: data,
    index: -1
  )

func newText(ctx: JSContext, data = ""): Text {.jsctor.} =
  let window = ctx.getGlobalOpaque(Window).get
  return window.document.newText(data)

func newCDATASection(document: Document, data: string): CDATASection =
  return CDATASection(
    nodeType: CDATA_SECTION_NODE,
    document: document,
    data: data,
    index: -1
  )

func newProcessingInstruction(document: Document, target, data: string): ProcessingInstruction =
  return ProcessingInstruction(
    nodeType: PROCESSING_INSTRUCTION_NODE,
    document: document,
    target: target,
    data: data,
    index: -1
  )

func newDocumentFragment(document: Document): DocumentFragment =
  return DocumentFragment(
    nodeType: DOCUMENT_FRAGMENT_NODE,
    document: document,
    index: -1
  )

func newDocumentFragment(ctx: JSContext): DocumentFragment {.jsctor.} =
  let window = ctx.getGlobalOpaque(Window).get
  return window.document.newDocumentFragment()

func newComment(document: Document, data: string): Comment =
  return Comment(
    nodeType: COMMENT_NODE,
    document: document,
    data: data,
    index: -1
  )

func newComment(ctx: JSContext, data: string = ""): Comment {.jsctor.} =
  let window = ctx.getGlobalOpaque(Window).get
  return window.document.newComment(data)

#TODO custom elements
func newHTMLElement*(document: Document, tagType: TagType,
    namespace = Namespace.HTML, prefix = none[string](),
    attrs = Table[string, string]()): HTMLElement =
  case tagType
  of TAG_INPUT:
    result = new(HTMLInputElement)
  of TAG_A:
    result = new(HTMLAnchorElement)
  of TAG_SELECT:
    result = new(HTMLSelectElement)
  of TAG_OPTGROUP:
    result = new(HTMLOptGroupElement)
  of TAG_OPTION:
    result = new(HTMLOptionElement)
  of TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6:
    result = new(HTMLHeadingElement)
  of TAG_BR:
    result = new(HTMLBRElement)
  of TAG_SPAN:
    result = new(HTMLSpanElement)
  of TAG_OL:
    result = new(HTMLOListElement)
  of TAG_UL:
    result = new(HTMLUListElement)
  of TAG_MENU:
    result = new(HTMLMenuElement)
  of TAG_LI:
    result = new(HTMLLIElement)
  of TAG_STYLE:
    result = new(HTMLStyleElement)
  of TAG_LINK:
    result = new(HTMLLinkElement)
  of TAG_FORM:
    result = new(HTMLFormElement)
  of TAG_TEMPLATE:
    result = new(HTMLTemplateElement)
    HTMLTemplateElement(result).content = DocumentFragment(document: document, host: result)
  of TAG_UNKNOWN:
    result = new(HTMLUnknownElement)
  of TAG_SCRIPT:
    result = new(HTMLScriptElement)
    HTMLScriptElement(result).forceAsync = true
  of TAG_BASE:
    result = new(HTMLBaseElement)
  of TAG_BUTTON:
    result = new(HTMLButtonElement)
  of TAG_TEXTAREA:
    result = new(HTMLTextAreaElement)
  of TAG_LABEL:
    result = new(HTMLLabelElement)
  of TAG_CANVAS:
    result = new(HTMLCanvasElement)
  of TAG_IMG:
    result = new(HTMLImageElement)
  else:
    result = new(HTMLElement)
  result.nodeType = ELEMENT_NODE
  result.tagType = tagType
  result.namespace = namespace
  result.namespacePrefix = prefix
  result.document = document
  result.attributes = NamedNodeMap(element: result)
  result.classList = DOMTokenList(localName: "classList")
  result.index = -1
  {.cast(noSideEffect).}:
    for k, v in attrs:
      result.attr(k, v)
  case tagType
  of TAG_SCRIPT:
    HTMLScriptElement(result).internalNonce = result.attr("nonce")
  of TAG_CANVAS:
    HTMLCanvasElement(result).bitmap = newBitmap(
      width = result.attrul("width").get(300),
      height = result.attrul("height").get(150)
    )
  else: discard

func newHTMLElement*(document: Document, localName: string,
    namespace = Namespace.HTML, prefix = none[string](),
    tagType = tagType(localName), attrs = Table[string, string]()): Element =
  result = document.newHTMLElement(tagType, namespace, prefix, attrs)
  if tagType == TAG_UNKNOWN:
    result.localName = localName

func newDocument*(): Document {.jsctor.} =
  result = Document(
    nodeType: DOCUMENT_NODE,
    url: newURL("about:blank").get,
    index: -1
  )
  result.document = result
  result.implementation = DOMImplementation(document: result)
  result.contentType = "application/xml"

func newDocumentType*(document: Document, name: string, publicId = "", systemId = ""): DocumentType =
  return DocumentType(
    nodeType: DOCUMENT_TYPE_NODE,
    document: document,
    name: name,
    publicId: publicId,
    systemId: systemId,
    index: -1
  )

func inHTMLNamespace*(element: Element): bool = element.namespace == Namespace.HTML
func inMathMLNamespace*(element: Element): bool = element.namespace == Namespace.MATHML
func inSVGNamespace*(element: Element): bool = element.namespace == Namespace.SVG
func inXLinkNamespace*(element: Element): bool = element.namespace == Namespace.XLINK
func inXMLNamespace*(element: Element): bool = element.namespace == Namespace.XML
func inXMLNSNamespace*(element: Element): bool = element.namespace == Namespace.XMLNS

func isResettable*(element: Element): bool =
  return element.tagType in {TAG_INPUT, TAG_OUTPUT, TAG_SELECT, TAG_TEXTAREA}

func isHostIncludingInclusiveAncestor*(a, b: Node): bool =
  for parent in b.branch:
    if parent == a:
      return true
  if b.rootNode.nodeType == DOCUMENT_FRAGMENT_NODE and DocumentFragment(b.rootNode).host != nil:
    for parent in b.rootNode.branch:
      if parent == a:
        return true
  return false

func baseURL*(document: Document): Url =
  #TODO frozen base url...
  var href = ""
  for base in document.elements(TAG_BASE):
    if base.attrb("href"):
      href = base.attr("href")
  if href == "":
    return document.url
  if document.url == nil:
    return newURL("about:blank").get #TODO ???
  let url = parseURL(href, some(document.url))
  if url.isNone:
    return document.url
  return url.get

func parseURL*(document: Document, s: string): Option[URL] =
  #TODO encodings
  return parseURL(s, some(document.baseURL))

func rel*[T: HTMLAnchorElement|HTMLLinkElement|HTMLAreaElement](element: T): string =
  return element.attr("rel")

func media*[T: HTMLLinkElement|HTMLStyleElement](element: T): string =
  return element.attr("media")

func title*(document: Document): string =
  for title in document.elements(TAG_TITLE):
    return title.childTextContent.stripAndCollapse()
  return ""

func disabled*(option: HTMLOptionElement): bool =
  if option.parentElement.tagType == TAG_OPTGROUP and option.parentElement.attrb("disabled"):
    return true
  return option.attrb("disabled")

func text*(option: HTMLOptionElement): string =
  for child in option.descendants:
    if child.nodeType == TEXT_NODE:
      let child = Text(child)
      if child.parentElement.tagType != TAG_SCRIPT: #TODO svg
        result &= child.data.stripAndCollapse()

func value*(option: HTMLOptionElement): string {.jsfget.} =
  if option.attrb("value"):
    return option.attr("value")
  return option.childTextContent.stripAndCollapse()

proc invalidateCollections(node: Node) =
  for id in node.liveCollections:
    node.document.invalidCollections.incl(id)

proc delAttr(element: Element, i: int) =
  if i != -1:
    let attr = element.attributes.attrlist[i]
    element.attrs.del(attr.name)
    element.attributes.attrlist.delete(i)
    element.invalidateCollections()
    element.invalid = true

proc delAttr(element: Element, name: string) =
  let i = element.attributes.findAttr(name)
  if i != -1:
    element.delAttr(i)

proc reflectAttrs(element: Element, name, value: string) =
  template reflect_str(element: Element, n: static string, val: untyped) =
    if name == n:
      element.val = value
      return
  template reflect_str(element: Element, n: static string, val, fun: untyped) =
    if name == n:
      element.val = fun(value)
  template reflect_bool(element: Element, name: static string, val: untyped) =
    if name in element.attrs:
      element.val = true
  element.reflect_str "id", id
  if name == "class":
    element.classList.toks.setLen(0)
    for x in value.split(AsciiWhitespace):
      if x != "" and x notin element.classList:
        element.classList.toks.add(x)
    return
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    input.reflect_str "value", value
    input.reflect_str "type", inputType, inputType
    input.reflect_bool "checked", checked
  of TAG_OPTION:
    let option = HTMLOptionElement(element)
    option.reflect_bool "selected", selected
  of TAG_BUTTON:
    let button = HTMLButtonElement(element)
    button.reflect_str "type", ctype, (func(s: string): ButtonType =
      case s
      of "submit": return BUTTON_SUBMIT
      of "reset": return BUTTON_RESET
      of "button": return BUTTON_BUTTON)
  else: discard

proc attr0(element: Element, name, value: string) =
  element.attrs.withValue(name, val):
    val[] = value
    element.invalidateCollections()
    element.invalid = true
  do: # else
    element.attrs[name] = value
  element.reflectAttrs(name, value)

proc attr*(element: Element, name, value: string) =
  let i = element.attributes.findAttr(name)
  if i != -1:
    element.attributes.attrlist[i].value = value
  else:
    element.attributes.attrlist.add(element.newAttr(name, value))
  element.attr0(name, value)

proc attrl(element: Element, name: string, value: int32) =
  element.attr(name, $value)

proc attrul(element: Element, name: string, value: uint32) =
  element.attr(name, $value)

proc attrulgz(element: Element, name: string, value: uint32) =
  if value > 0:
    element.attrul(name, value)

func validateAttributeName(name: string, isq: static bool = false):
    Err[DOMException] =
  when isq:
    if name.matchNameProduction():
      return ok()
  else:
    if name.matchQNameProduction():
      return ok()
  return err(newDOMException("Invalid character in attribute name",
    "InvalidCharacterError"))

proc setAttribute(element: Element, qualifiedName, value: string):
    Err[DOMException] {.jsfunc.} =
  ?validateAttributeName(qualifiedName)
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  element.attr(qualifiedName, value)
  return ok()

proc setAttributeNS(element: Element, namespace, qualifiedName,
    value: string): Err[DOMException] {.jsfunc.} =
  ?validateAttributeName(qualifiedName, isq = true)
  let ps = qualifiedName.until(':')
  let prefix = if ps.len < qualifiedName.len: ps else: ""
  let localName = qualifiedName.substr(prefix.len)
  if prefix != "" and namespace == "" or
      prefix == "xml" and namespace != $Namespace.XML or
      (qualifiedName == "xmlns" or prefix == "xmlns") and namespace != $Namespace.XMLNS or
      namespace == $Namespace.XMLNS and qualifiedName != "xmlns" and prefix != "xmlns":
    return err(newDOMException("Unexpected namespace", "NamespaceError"))
  element.attr0(qualifiedName, value)
  let i = element.attributes.findAttrNS(namespace, localName)
  if i != -1:
    element.attributes.attrlist[i].value = value
  else:
    element.attributes.attrlist.add(element.newAttr(localName, value, prefix, namespace))
  return ok()

proc removeAttribute(element: Element, qualifiedName: string) {.jsfunc.} =
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  element.delAttr(qualifiedName)

proc removeAttributeNS(element: Element, namespace, localName: string) {.jsfunc.} =
  let i = element.attributes.findAttrNS(namespace, localName)
  if i != -1:
    element.delAttr(i)

proc toggleAttribute(element: Element, qualifiedName: string,
    force = none(bool)): Result[bool, DOMException] {.jsfunc.} =
  ?validateAttributeName(qualifiedName)
  let qualifiedName = if element.namespace == Namespace.HTML and not element.document.isxml:
    qualifiedName.toLowerAscii2()
  else:
    qualifiedName
  if not element.attrb(qualifiedName):
    if force.get(true):
      element.attr(qualifiedName, "")
      return ok(true)
    return ok(false)
  if not force.get(false):
    element.delAttr(qualifiedName)
    return ok(false)
  return ok(true)

proc value(attr: Attr, s: string) {.jsfset.} =
  attr.value = s
  if attr.ownerElement != nil:
    attr.ownerElement.attr0(attr.name, s)

proc setNamedItem(map: NamedNodeMap, attr: Attr): Result[Attr, DOMException]
    {.jsfunc.} =
  if attr.ownerElement != nil and attr.ownerElement != map.element:
    return err(newDOMException("Attribute is currently in use",
      "InUseAttributeError"))
  if attr.name in map.element.attrs:
    return ok(attr)
  let i = map.findAttr(attr.name)
  if i != -1:
    result = ok(map.attrlist[i])
    map.attrlist.delete(i)
  else:
    result = ok(nil)
  map.element.attrs[attr.name] = attr.value
  map.attrlist.add(attr)

proc setNamedItemNS(map: NamedNodeMap, attr: Attr): Result[Attr, DOMException]
    {.jsfunc.} =
  return map.setNamedItem(attr)

proc removeNamedItem(map: NamedNodeMap, qualifiedName: string):
    Result[Attr, DOMException] {.jsfunc.} =
  let i = map.findAttr(qualifiedName)
  if i != -1:
    let attr = map.attrlist[i]
    map.element.delAttr(i)
    return ok(attr)
  return err(newDOMException("Item not found", "NotFoundError"))

proc removeNamedItemNS(map: NamedNodeMap, namespace, localName: string):
    Result[Attr, DOMException] {.jsfunc.} =
  let i = map.findAttrNS(namespace, localName)
  if i != -1:
    let attr = map.attrlist[i]
    map.element.delAttr(i)
    return ok(attr)
  return err(newDOMException("Item not found", "NotFoundError"))

proc id(element: Element, id: string) {.jsfset.} =
  element.id = id
  element.attr("id", id)

# Pass an index to avoid searching for the node in parent's child list.
proc remove*(node: Node, suppressObservers: bool) =
  let parent = node.parentNode
  assert parent != nil
  assert node.index != -1
  #TODO live ranges
  #TODO NodeIterator
  for i in node.index ..< parent.childList.len - 1:
    parent.childList[i] = parent.childList[i + 1]
    parent.childList[i].index = i
  parent.childList.setLen(parent.childList.len - 1)
  node.parentNode.invalidateCollections()
  node.parentNode = nil
  node.parentElement = nil
  node.root = nil
  node.index = -1
  if node.nodeType == ELEMENT_NODE:
    if Element(node).tagType in {TAG_STYLE, TAG_LINK} and node.document != nil:
      node.document.cachedSheetsInvalid = true

  #TODO assigned, shadow root, shadow root again, custom nodes, registered observers
  #TODO not suppress observers => queue tree mutation record

proc remove*(node: Node) {.jsfunc.} =
  node.remove(suppressObservers = false)

proc adopt(document: Document, node: Node) =
  let oldDocument = node.document
  if node.parentNode != nil:
    remove(node)
  if oldDocument != document:
    #TODO shadow root
    for desc in node.descendants:
      desc.document = document
      if desc.nodeType == ELEMENT_NODE:
        for attr in Element(desc).attributes.attrlist:
          attr.document = document
    #TODO custom elements
    #..adopting steps

proc resetElement*(element: Element) = 
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputELement(element)
    case input.inputType
    of INPUT_SEARCH, INPUT_TEXT, INPUT_PASSWORD:
      input.value = input.attr("value")
    of INPUT_CHECKBOX, INPUT_RADIO:
      input.checked = input.attrb("checked")
    of INPUT_FILE:
      input.file = none(Url)
    else: discard
    input.invalid = true
  of TAG_SELECT:
    let select = HTMLSelectElement(element)
    if not select.attrb("multiple"):
      if select.attrul("size").get(1) == 1:
        var i = 0
        var firstOption: HTMLOptionElement
        for option in select.options:
          if firstOption == nil:
            firstOption = option
          if option.selected:
            inc i
        if i == 0 and firstOption != nil:
          firstOption.selected = true
        elif i > 2:
          # Set the selectedness of all but the last selected option element to
          # false.
          var j = 0
          for option in select.options:
            if j == i: break
            if option.selected:
              option.selected = false
              inc j
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    textarea.value = textarea.childTextContent()
    textarea.invalid = true
  else: discard

proc setForm*(element: FormAssociatedElement, form: HTMLFormElement) =
  case element.tagType
  of TAG_INPUT:
    let input = HTMLInputElement(element)
    input.form = form
    form.controls.add(input)
  of TAG_SELECT:
    let select = HTMLSelectElement(element)
    select.form = form
    form.controls.add(select)
  of TAG_BUTTON:
    let button = HTMLButtonElement(element)
    button.form = form
    form.controls.add(button)
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    textarea.form = form
    form.controls.add(textarea)
  of TAG_FIELDSET, TAG_OBJECT, TAG_OUTPUT, TAG_IMG:
    discard #TODO
  else: assert false

proc resetFormOwner(element: FormAssociatedElement) =
  element.parserInserted = false
  if element.form != nil and
      element.tagType notin ListedElements or not element.attrb("form") and
      element.findAncestor({TAG_FORM}) == element.form:
    return
  element.form = nil
  if element.tagType in ListedElements and element.attrb("form") and element.isConnected:
    let form = element.attr("form")
    for desc in element.elements(TAG_FORM):
      if desc.id == form:
        element.setForm(HTMLFormElement(desc))

proc insertionSteps(insertedNode: Node) =
  if insertedNode.nodeType == ELEMENT_NODE:
    let element = Element(insertedNode)
    let tagType = element.tagType
    case tagType
    of TAG_OPTION:
      if element.parentElement != nil:
        let parent = element.parentElement
        var select: HTMLSelectElement
        if parent.tagType == TAG_SELECT:
          select = HTMLSelectElement(parent)
        elif parent.tagType == TAG_OPTGROUP and parent.parentElement != nil and parent.parentElement.tagType == TAG_SELECT:
          select = HTMLSelectElement(parent.parentElement)
        if select != nil:
          select.resetElement()
    else: discard
    if tagType in SupportedFormAssociatedElements:
      let element = FormAssociatedElement(element)
      if element.parserInserted:
        return
      element.resetFormOwner()

# WARNING the ordering of the arguments in the standard is whack so this doesn't match that
func preInsertionValidity*(parent, node, before: Node): Err[DOMException] =
  if parent.nodeType notin {DOCUMENT_NODE, DOCUMENT_FRAGMENT_NODE, ELEMENT_NODE}:
    return err(newDOMException("Parent must be a document, document fragment, " &
      "or element", "HierarchyRequestError"))
  if node.isHostIncludingInclusiveAncestor(parent):
    return err(newDOMException("Parent must be an ancestor", "HierarchyRequestError"))
  if before != nil and before.parentNode != parent:
    return err(newDOMException("Reference node is not a child of parent",
      "NotFoundError"))
  if node.nodeType notin {DOCUMENT_FRAGMENT_NODE, DOCUMENT_TYPE_NODE,
      ELEMENT_NODE} + CharacterDataNodes:
    return err(newDOMException("Cannot insert node type",
      "HierarchyRequestError"))
  if node.nodeType == TEXT_NODE and parent.nodeType == DOCUMENT_NODE:
    return err(newDOMException("Cannot insert text into document",
      "HierarchyRequestError"))
  if node.nodeType == DOCUMENT_TYPE_NODE and parent.nodeType != DOCUMENT_NODE:
    return err(newDOMException("Document type can only be inserted into " &
      "document", "HierarchyRequestError"))
  if parent.nodeType == DOCUMENT_NODE:
    case node.nodeType
    of DOCUMENT_FRAGMENT_NODE:
      let elems = node.countChildren(ELEMENT_NODE)
      if elems > 1 or node.hasChild(TEXT_NODE):
        return err(newDOMException("Document fragment has invalid children",
          "HierarchyRequestError"))
      elif elems == 1 and (parent.hasChild(ELEMENT_NODE) or
          before != nil and (before.nodeType == DOCUMENT_TYPE_NODE or
          before.hasNextSibling(DOCUMENT_TYPE_NODE))):
        return err(newDOMException("Document fragment has invalid children",
          "HierarchyRequestError"))
    of ELEMENT_NODE:
      if parent.hasChild(ELEMENT_NODE):
        return err(newDOMException("Document already has an element child",
          "HierarchyRequestError"))
      elif before != nil and (before.nodeType == DOCUMENT_TYPE_NODE or
            before.hasNextSibling(DOCUMENT_TYPE_NODE)):
        return err(newDOMException("Cannot insert element before document " &
          "type", "HierarchyRequestError"))
    of DOCUMENT_TYPE_NODE:
      if parent.hasChild(DOCUMENT_TYPE_NODE) or
          before != nil and before.hasPreviousSibling(ELEMENT_NODE) or
          before == nil and parent.hasChild(ELEMENT_NODE):
        return err(newDOMException("Cannot insert document type before " &
          "an element node", "HierarchyRequestError"))
    else: discard
  return ok() # no exception reached

proc insertNode(parent, node, before: Node) =
  parent.document.adopt(node)
  parent.childList.setLen(parent.childList.len + 1)
  if before == nil:
    node.index = parent.childList.high
  else:
    node.index = before.index
    for i in before.index ..< parent.childList.len - 1:
      parent.childList[i + 1] = parent.childList[i]
      parent.childList[i + 1].index = i + 1
  parent.childList[node.index] = node
  node.root = parent.rootNode
  node.parentNode = parent
  if parent.nodeType == ELEMENT_NODE:
    node.parentElement = Element(parent)
  node.invalidateCollections()
  if node.nodeType == ELEMENT_NODE:
    if Element(node).tagType in {TAG_STYLE, TAG_LINK} and node.document != nil:
      node.document.cachedSheetsInvalid = true
  if node.nodeType == ELEMENT_NODE:
    #TODO shadow root
    insertionSteps(node)

# WARNING ditto
proc insert*(parent, node, before: Node) =
  let nodes = if node.nodeType == DOCUMENT_FRAGMENT_NODE: node.childList
  else: @[node]
  let count = nodes.len
  if count == 0:
    return
  if node.nodeType == DOCUMENT_FRAGMENT_NODE:
    for i in countdown(node.childList.high, 0):
      node.childList[i].remove(true)
    #TODO tree mutation record
  if before != nil:
    #TODO live ranges
    discard
  if parent.nodeType == ELEMENT_NODE:
    Element(parent).invalid = true
  for node in nodes:
    insertNode(parent, node, before)

proc insertBefore(parent, node, before: Node): Result[Node, DOMException]
    {.jsfunc.} =
  ?parent.preInsertionValidity(node, before)
  let referenceChild = if before == node:
    node.nextSibling
  else:
    before
  parent.insert(node, referenceChild)
  return ok(node)

proc appendChild(parent, node: Node): Result[Node, DOMException] {.jsfunc.} =
  return parent.insertBefore(node, nil)

proc append*(parent, node: Node) =
  discard parent.appendChild(node)

#TODO replaceChild

proc removeChild(parent, node: Node): Result[Node, DOMException] {.jsfunc.} =
  if node.parentNode != parent:
    return err(newDOMException("Node is not a child of parent",
      "NotFoundError"))
  node.remove()
  return ok(node)

proc replaceAll(parent, node: Node) =
  for i in countdown(parent.childList.high, 0):
    parent.childList[i].remove(true)
  if node != nil:
    if node.nodeType == DOCUMENT_FRAGMENT_NODE:
      for child in node.childList:
        parent.append(child)
    else:
      parent.append(node)
  #TODO tree mutation record

proc createTextNode*(document: Document, data: string): Text {.jsfunc.} =
  return newText(document, data)

proc textContent*(node: Node, data: Option[string]) {.jsfset.} =
  case node.nodeType
  of DOCUMENT_FRAGMENT_NODE, ELEMENT_NODE:
    let x = if data.isSome:
      node.document.createTextNode(data.get)
    else:
      nil
    node.replaceAll(x)
  of ATTRIBUTE_NODE:
    value(Attr(node), data.get(""))
  of TEXT_NODE, COMMENT_NODE:
    CharacterData(node).data = data.get("")
  else: discard

proc reset*(form: HTMLFormElement) =
  for control in form.controls:
    control.resetElement()
    control.invalid = true

proc renderBlocking*(element: Element): bool =
  if "render" in element.attr("blocking").split(AsciiWhitespace):
    return true
  if element.tagType == TAG_SCRIPT:
    let element = HTMLScriptElement(element)
    if element.ctype == CLASSIC and element.parserDocument != nil and
        not element.attrb("async") and not element.attrb("defer"):
      return true
  return false

proc blockRendering*(element: Element) =
  let document = element.document
  if document != nil and document.contentType == "text/html" and document.body == nil:
    element.document.renderBlockingElements.add(element)

proc markAsReady(element: HTMLScriptElement, res: ScriptResult) =
  element.scriptResult = res
  if element.onReady != nil:
    element.onReady()
    element.onReady = nil
  element.delayingTheLoadEvent = false

proc createClassicScript(source: string, baseURL: URL, options: ScriptOptions, mutedErrors = false): Script =
  return Script(
    record: source,
    baseURL: baseURL,
    options: options,
    mutedErrors: mutedErrors
  )

#TODO settings object
proc fetchClassicScript(element: HTMLScriptElement, url: URL,
    options: ScriptOptions, cors: CORSAttribute,
    cs: Charset, onComplete: (proc(element: HTMLScriptElement,
                                   res: ScriptResult))) =
  if not element.scriptingEnabled:
      element.onComplete(ScriptResult(t: RESULT_NULL))
  else:
    let loader = element.document.window.loader
    if loader.isSome:
      let loader = loader.get
      let request = createPotentialCORSRequest(url, RequestDestination.SCRIPT, cors)
      let response = loader.doRequest(request)
      if response.res != 0:
        element.onComplete(ScriptResult(t: RESULT_NULL))
        return
      let cs = if cs == CHARSET_UNKNOWN:
        CHARSET_UTF_8
      else:
        cs
      let decoder = newDecoderStream(response.body, cs = cs)
      let source = decoder.readAll()
      let script = createClassicScript(source, url, options, false)
      element.markAsReady(ScriptResult(t: RESULT_SCRIPT, script: script))

proc log*(console: console, ss: varargs[string]) {.jsfunc.} =
  var s = ""
  for i in 0..<ss.len:
    s &= ss[i]
    console.err.write(ss[i])
    if i != ss.high:
      s &= ' '
      console.err.write(' ')
  console.err.write('\n')
  console.err.flush()

proc clear*(console: console) {.jsfunc.} =
  # Do nothing. By design, we do not allow buffers to clear the console.
  discard

# For now, these are the same as log().
proc debug*(console: console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc error*(console: console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc info*(console: console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc warn*(console: console, ss: varargs[string]) {.jsfunc.} =
  console.log(ss)

proc execute*(element: HTMLScriptElement) =
  let document = element.document
  if document != element.preparationTimeDocument:
    return
  let i = document.renderBlockingElements.find(element)
  if i != -1:
    document.renderBlockingElements.delete(i)
  if element.scriptResult.t == RESULT_NULL:
    #TODO fire error event
    return
  case element.ctype
  of CLASSIC:
    let oldCurrentScript = document.currentScript
    #TODO not if shadow root
    document.currentScript = element
    if document.window != nil and document.window.jsctx != nil:
      let script = element.scriptResult.script
      let ret = document.window.jsctx.eval(script.record, $script.baseURL, JS_EVAL_TYPE_GLOBAL)
      if JS_IsException(ret):
        let ss = newStringStream()
        document.window.jsctx.writeException(ss)
        ss.setPosition(0)
        document.window.console.log("Exception in document", $document.url, ss.readAll())
    document.currentScript = oldCurrentScript
  else: discard #TODO

# https://html.spec.whatwg.org/multipage/scripting.html#prepare-the-script-element
proc prepare*(element: HTMLScriptElement) =
  if element.alreadyStarted:
    return
  let parserDocument = element.parserDocument
  element.parserDocument = nil
  if parserDocument != nil and not element.attrb("async"):
    element.forceAsync = true
  let sourceText = element.childTextContent
  if not element.attrb("src") and sourceText == "":
    return
  if not element.isConnected:
    return
  let typeString = if element.attr("type") != "":
    element.attr("type").strip(chars = AsciiWhitespace).toLowerAscii()
  elif element.attr("language") != "":
    "text/" & element.attr("language").toLowerAscii()
  else:
    "text/javascript"
  if typeString.isJavaScriptType():
    element.ctype = CLASSIC
  elif typeString == "module":
    element.ctype = MODULE
  elif typeString == "importmap":
    element.ctype = IMPORTMAP
  else:
    return
  if parserDocument != nil:
    element.parserDocument = parserDocument
    element.forceAsync = false
  element.alreadyStarted = true
  element.preparationTimeDocument = element.document
  if parserDocument != nil and parserDocument != element.preparationTimeDocument:
    return
  if not element.scriptingEnabled:
    return
  if element.attrb("nomodule") and element.ctype == CLASSIC:
    return
  #TODO content security policy
  if element.ctype == CLASSIC and element.attrb("event") and element.attrb("for"):
    let f = element.attr("for").strip(chars = AsciiWhitespace)
    let event = element.attr("event").strip(chars = AsciiWhitespace)
    if not f.equalsIgnoreCase("window"):
      return
    if not event.equalsIgnoreCase("onload") and not event.equalsIgnoreCase("onload()"):
      return
  let cs = getCharset(element.attr("charset"))
  let encoding = if cs != CHARSET_UNKNOWN: cs else: element.document.charset
  let classicCORS = element.crossorigin
  var options = ScriptOptions(
    nonce: element.internalNonce,
    integrity: element.attr("integrity"),
    parserMetadata: if element.parserDocument != nil: PARSER_INSERTED else: NOT_PARSER_INSERTED,
    referrerpolicy: element.referrerpolicy
  )
  #TODO settings object
  if element.attrb("src"):
    if element.ctype == IMPORTMAP:
      #TODO fire error event
      return
    let src = element.attr("src")
    if src == "":
      #TODO fire error event
      return
    element.fromAnExternalFile = true
    let url = element.document.parseURL(src)
    if url.isNone:
      #TODO fire error event
      return
    if element.renderBlocking:
      element.blockRendering()
    element.delayingTheLoadEvent = true
    if element in element.document.renderBlockingElements:
      options.renderBlocking = true
    if element.ctype == CLASSIC:
      element.fetchClassicScript(url.get, options, classicCORS, encoding, markAsReady)
    else:
      #TODO MODULE
      element.markAsReady(ScriptResult(t: RESULT_NULL))
  else:
    let baseURL = element.document.baseURL
    if element.ctype == CLASSIC:
      let script = createClassicScript(sourceText, baseURL, options)
      element.markAsReady(ScriptResult(t: RESULT_SCRIPT, script: script))
    else:
      #TODO MODULE, IMPORTMAP
      element.markAsReady(ScriptResult(t: RESULT_NULL))
  if element.ctype == CLASSIC and element.attrb("src") or element.ctype == MODULE:
    let prepdoc = element.preparationTimeDocument 
    if element.attrb("async"):
      prepdoc.scriptsToExecSoon.add(element)
      element.onReady = (proc() =
        element.execute()
        let i = prepdoc.scriptsToExecSoon.find(element)
        element.preparationTimeDocument.scriptsToExecSoon.delete(i)
      )
    elif element.parserDocument == nil:
      prepdoc.scriptsToExecInOrder.addFirst(element)
      element.onReady = (proc() =
        if prepdoc.scriptsToExecInOrder.len > 0 and prepdoc.scriptsToExecInOrder[0] != element:
          while prepdoc.scriptsToExecInOrder.len > 0:
            let script = prepdoc.scriptsToExecInOrder[0]
            if script.scriptResult.t == RESULT_UNINITIALIZED:
              break
            script.execute()
            prepdoc.scriptsToExecInOrder.shrink(1)
      )
    elif element.ctype == MODULE or element.attrb("defer"):
      element.parserDocument.scriptsToExecOnLoad.addFirst(element)
      element.onReady = (proc() =
        element.readyForParserExec = true
      )
    else:
      element.parserDocument.parserBlockingScript = element
      element.blockRendering()
      element.onReady = (proc() =
        element.readyForParserExec = true
      )
  else:
    #TODO if CLASSIC, parserDocument != nil, parserDocument has a style sheet
    # that is blocking scripts, either the parser is an XML parser or a HTML
    # parser with a script level <= 1
    element.execute()

#TODO options/custom elements
proc createElement(document: Document, localName: string):
    Result[Element, DOMException] {.jsfunc.} =
  if not localName.matchNameProduction():
    return err(newDOMException("Invalid character in element name",
      "InvalidCharacterError"))
  let localName = if not document.isxml:
    localName.toLowerAscii2()
  else:
    localName
  let namespace = if not document.isxml: #TODO or content type is application/xhtml+xml
    Namespace.HTML
  else:
    NO_NAMESPACE
  return ok(document.newHTMLElement(localName, namespace))

#TODO createElementNS

proc createDocumentFragment(document: Document): DocumentFragment {.jsfunc.} =
  return newDocumentFragment(document)

proc createDocumentType(implementation: DOMImplementation, qualifiedName,
    publicId, systemId: string): Result[DocumentType, DOMException] {.jsfunc.} =
  if not qualifiedName.matchQNameProduction():
    return err(newDOMException("Invalid character in document type name",
      "InvalidCharacterError"))
  return ok(implementation.document.newDocumentType(qualifiedName, publicId,
    systemId))

proc createHTMLDocument(implementation: DOMImplementation, title =
    none(string)): Document {.jsfunc.} =
  let doc = newDocument()
  doc.contentType = "text/html"
  doc.append(doc.newDocumentType("html"))
  let html = doc.newHTMLElement(TAG_HTML, Namespace.HTML)
  doc.append(html)
  let head = doc.newHTMLElement(TAG_HEAD, Namespace.HTML)
  html.append(head)
  if title.isSome:
    let titleElement = doc.newHTMLElement(TAG_TITLE, Namespace.HTML)
    titleElement.append(doc.newText(title.get))
    head.append(titleElement)
  html.append(doc.newHTMLElement(TAG_BODY, Namespace.HTML))
  #TODO set origin
  return doc

proc createCDATASection(document: Document, data: string): Result[CDATASection, DOMException] {.jsfunc.} =
  if not document.isxml:
    return err(newDOMException("CDATA sections are not supported in HTML",
      "NotSupportedError"))
  if "]]>" in data:
    return err(newDOMException("CDATA sections may not contain the string ]]>",
      "InvalidCharacterError"))
  return ok(newCDATASection(document, data))

proc createComment*(document: Document, data: string): Comment {.jsfunc.} =
  return newComment(document, data)

proc createProcessingInstruction(document: Document, target, data: string):
    Result[ProcessingInstruction, DOMException] {.jsfunc.} =
  if not target.matchNameProduction() or "?>" in data:
    return err(newDOMException("Invalid data for processing instruction",
      "InvalidCharacterError"))
  return ok(newProcessingInstruction(document, target, data))

# Forward definition hack (these are set in selectors.nim)
var doqsa*: proc (node: Node, q: string): seq[Element]
var doqs*: proc (node: Node, q: string): Element

proc querySelectorAll*(node: Node, q: string): seq[Element] {.jsfunc.} =
  return doqsa(node, q)

proc querySelector*(node: Node, q: string): Element {.jsfunc.} =
  return doqs(node, q)

const (ReflectTable, TagReflectMap, ReflectAllStartIndex) = (func(): (
    seq[ReflectEntry],
    Table[TagType, seq[uint16]],
    uint16) =
  var i: uint16 = 0
  while i < ReflectTable0.len:
    let x = ReflectTable0[i]
    result[0].add(x)
    if x.tags == AllTagTypes:
      break
    for tag in result[0][i].tags:
      if tag notin result[1]:
        result[1][tag] = newSeq[uint16]()
      result[1][tag].add(i)
    assert result[0][i].tags.len != 0
    inc i
  result[2] = i
  while i < ReflectTable0.len:
    let x = ReflectTable0[i]
    assert x.tags == AllTagTypes
    result[0].add(x)
    inc i
)()

proc jsReflectGet(ctx: JSContext, this: JSValue, magic: cint): JSValue {.cdecl.} =
  let entry = ReflectTable[uint16(magic)]
  let op = getOpaque0(this)
  if unlikely(not ctx.isInstanceOf(this, "Element") or op == nil):
    return JS_ThrowTypeError(ctx, "Reflected getter called on a value that is not an element")
  let element = cast[Element](op)
  if element.tagType notin entry.tags:
    return JS_ThrowTypeError(ctx, "Invalid tag type %s", element.tagType)
  case entry.t
  of REFLECT_STR:
    let x = toJS(ctx, element.attr(entry.attrname))
    return x
  of REFLECT_BOOl:
    return toJS(ctx, element.attrb(entry.attrname))
  of REFLECT_LONG:
    return toJS(ctx, element.attrl(entry.attrname).get(entry.i))
  of REFLECT_ULONG:
    return toJS(ctx, element.attrul(entry.attrname).get(entry.u))
  of REFLECT_ULONG_GZ:
    return toJS(ctx, element.attrulgz(entry.attrname).get(entry.u))

proc jsReflectSet(ctx: JSContext, this, val: JSValue, magic: cint): JSValue {.cdecl.} =
  if unlikely(not ctx.isInstanceOf(this, "Element")):
    return JS_ThrowTypeError(ctx, "Reflected getter called on a value that is not an element")
  let entry = ReflectTable[uint16(magic)]
  let op = getOpaque0(this)
  assert op != nil
  let element = cast[Element](op)
  if element.tagType notin entry.tags:
    return JS_ThrowTypeError(ctx, "Invalid tag type %s", element.tagType)
  case entry.t
  of REFLECT_STR:
    let x = toString(ctx, val)
    if x.isSome:
      element.attr(entry.attrname, x.get)
  of REFLECT_BOOL:
    let x = fromJS[bool](ctx, val)
    if x.isSome:
      if x.get:
        element.attr(entry.attrname, "")
      else:
        element.delAttr(entry.attrname)
  of REFLECT_LONG:
    let x = fromJS[int32](ctx, val)
    if x.isSome:
      element.attrl(entry.attrname, x.get)
  of REFLECT_ULONG:
    let x = fromJS[uint32](ctx, val)
    if x.isSome:
      element.attrul(entry.attrname, x.get)
  of REFLECT_ULONG_GZ:
    let x = fromJS[uint32](ctx, val)
    if x.isSome:
      element.attrulgz(entry.attrname, x.get)
  return JS_DupValue(ctx, val)

proc addconsoleModule*(ctx: JSContext) =
  #TODO console should not have a prototype
  ctx.registerType(console, nointerface = true)

func getReflectFunctions(tags: set[TagType]): seq[TabGetSet] =
  for tag in tags:
    if tag in TagReflectMap:
      for i in TagReflectMap[tag]:
        result.add(TabGetSet(
          name: ReflectTable[i].funcname,
          get: jsReflectGet,
          set: jsReflectSet,
          magic: i
        ))
  return result

func getElementReflectFunctions(): seq[TabGetSet] =
  var i: uint16 = ReflectAllStartIndex
  while i < uint16(ReflectTable.len):
    let entry = ReflectTable[i]
    assert entry.tags == AllTagTypes
    result.add(TabGetSet(name: ReflectTable[i].funcname, get: jsReflectGet, set: jsReflectSet, magic: i))
    inc i

proc getContext*(jctx: JSContext, this: HTMLCanvasElement, contextId: string,
    options = none(JSValue)): RenderingContext {.jsfunc.} =
  if contextId == "2d":
    if this.ctx2d != nil:
      return this.ctx2d
    return create2DContext(jctx, this, options)
  return nil

#TODO quality should be `any'
proc toBlob(ctx: JSContext, this: HTMLCanvasElement, callback: JSValue,
    s = "image/png", quality: float64 = 1): JSValue {.jsfunc.} =
  var outlen: int
  let buf = this.bitmap.toPNG(outlen)
  let blob = newBlob(buf, outlen, "image/png", dealloc)
  var jsBlob = toJS(ctx, blob)
  let res = JS_Call(ctx, callback, JS_UNDEFINED, 1, addr jsBlob)
  # Hack. TODO: implement JSValue to callback
  if res == JS_EXCEPTION:
    return JS_EXCEPTION
  JS_FreeValue(ctx, res)
  return JS_UNDEFINED

proc registerElements(ctx: JSContext, nodeCID: JSClassID) =
  let elementCID = ctx.registerType(Element, parent = nodeCID)
  const extra_getset = getElementReflectFunctions()
  let htmlElementCID = ctx.registerType(HTMLElement, parent = elementCID,
    has_extra_getset = true, extra_getset = extra_getset)
  template register(t: typed, tags: set[TagType]) =
    const extra_getset = getReflectFunctions(tags)
    ctx.registerType(t, parent = htmlElementCID,
      has_extra_getset = true, extra_getset = extra_getset)
  template register(t: typed, tag: TagType) =
    register(t, {tag})
  register(HTMLInputElement, TAG_INPUT)
  register(HTMLAnchorElement, TAG_A)
  register(HTMLSelectElement, TAG_SELECT)
  register(HTMLSpanElement, TAG_SPAN)
  register(HTMLOptGroupElement, TAG_OPTGROUP)
  register(HTMLOptionElement, TAG_OPTION)
  register(HTMLHeadingElement, {TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6})
  register(HTMLBRElement, TAG_BR)
  register(HTMLMenuElement, TAG_MENU)
  register(HTMLUListElement, TAG_UL)
  register(HTMLOListElement, TAG_OL)
  register(HTMLLIElement, TAG_LI)
  register(HTMLStyleElement, TAG_STYLE)
  register(HTMLLinkElement, TAG_LINK)
  register(HTMLFormElement, TAG_FORM)
  register(HTMLTemplateElement, TAG_TEMPLATE)
  register(HTMLUnknownElement, TAG_UNKNOWN)
  register(HTMLScriptElement, TAG_SCRIPT)
  register(HTMLBaseElement, TAG_BASE)
  register(HTMLAreaElement, TAG_AREA)
  register(HTMLButtonElement, TAG_BUTTON)
  register(HTMLTextAreaElement, TAG_TEXTAREA)
  register(HTMLLabelElement, TAG_LABEL)
  register(HTMLCanvasElement, TAG_CANVAS)
  register(HTMLImageElement, TAG_IMG)

proc addDOMModule*(ctx: JSContext) =
  let eventTargetCID = ctx.getClass("EventTarget")
  let nodeCID = ctx.registerType(Node, parent = eventTargetCID)
  ctx.registerType(NodeList)
  ctx.registerType(HTMLCollection)
  ctx.registerType(Location)
  ctx.registerType(Document, parent = nodeCID)
  ctx.registerType(DOMImplementation)
  ctx.registerType(DOMTokenList)
  let characterDataCID = ctx.registerType(CharacterData, parent = nodeCID)
  ctx.registerType(Comment, parent = characterDataCID)
  ctx.registerType(CDATASection, parent = characterDataCID)
  ctx.registerType(DocumentFragment, parent = nodeCID)
  ctx.registerType(ProcessingInstruction, parent = characterDataCID)
  ctx.registerType(Text, parent = characterDataCID)
  ctx.registerType(DocumentType, parent = nodeCID)
  ctx.registerType(Attr, parent = nodeCID)
  ctx.registerType(NamedNodeMap)
  ctx.registerType(CanvasRenderingContext2D)
  ctx.registerType(TextMetrics)
  ctx.registerElements(nodeCID)
