import algorithm
import options
import streams
import strutils
import sugar

import css/cssparser
import css/match
import css/mediaquery
import css/selectorparser
import css/sheet
import css/stylednode
import css/values
import html/dom
import html/tags
import types/color

type
  DeclarationList* = array[PseudoElem, seq[CSSDeclaration]]

func applies(feature: MediaFeature, window: Window): bool =
  case feature.t
  of FEATURE_COLOR:
    return 8 in feature.range
  of FEATURE_GRID:
    return feature.b
  of FEATURE_HOVER:
    return feature.b
  of FEATURE_PREFERS_COLOR_SCHEME:
    return feature.b
  of FEATURE_WIDTH:
    let a = px(feature.lengthrange.a, window.attrs, 0)
    let b = px(feature.lengthrange.b, window.attrs, 0)
    return window.attrs.ppc * window.attrs.width in a .. b
  of FEATURE_HEIGHT:
    let a = px(feature.lengthrange.a, window.attrs, 0)
    let b = px(feature.lengthrange.b, window.attrs, 0)
    return window.attrs.ppl * window.attrs.height in a .. b

func applies(mq: MediaQuery, window: Window): bool =
  case mq.t
  of CONDITION_MEDIA:
    case mq.media
    of MEDIA_TYPE_ALL: return true
    of MEDIA_TYPE_PRINT: return false
    of MEDIA_TYPE_SCREEN: return true
    of MEDIA_TYPE_SPEECH: return false
    of MEDIA_TYPE_TTY: return true
    of MEDIA_TYPE_UNKNOWN: return false
  of CONDITION_NOT:
    return not mq.n.applies(window)
  of CONDITION_AND:
    return mq.anda.applies(window) and mq.andb.applies(window)
  of CONDITION_OR:
    return mq.ora.applies(window) or mq.orb.applies(window)
  of CONDITION_FEATURE:
    return mq.feature.applies(window)

func applies*(mqlist: MediaQueryList, window: Window): bool =
  for mq in mqlist:
    if mq.applies(window):
      return true
  return false

type ToSorts = array[PseudoElem, seq[(int, seq[CSSDeclaration])]]

proc calcRule(tosorts: var ToSorts, styledNode: StyledNode, rule: CSSRuleDef) =
  for sel in rule.sels:
    #TODO we shouldn't need backtracking for this...
    if styledNode.selectorsMatch(sel):
      let spec = getSpecificity(sel)
      tosorts[sel.pseudo].add((spec,rule.decls))

func calcRules(styledNode: StyledNode, sheet: CSSStylesheet): DeclarationList =
  var tosorts: ToSorts
  let elem = Element(styledNode.node)
  for rule in sheet.gen_rules(elem.tagType, elem.id, elem.classList.toks):
    tosorts.calcRule(styledNode, rule)

  for i in PseudoElem:
    tosorts[i].sort((x, y) => cmp(x[0], y[0]))
    result[i] = collect(newSeq):
      for item in tosorts[i]:
        for dl in item[1]:
          dl

func calcPresentationalHints(element: Element): CSSComputedValues =
  template set_cv(a, b: untyped) =
    if result == nil:
      new(result)
    result{a} = b
  template map_width =
    let s = parseDimensionValues(element.attr("width"))
    if s.isSome:
      set_cv "width", s.get
  template map_height =
    let s = parseDimensionValues(element.attr("height"))
    if s.isSome:
      set_cv "height", s.get
  template map_width_nozero =
    let s = parseDimensionValues(element.attr("width"))
    if s.isSome and s.get.num != 0:
      set_cv "width", s.get
  template map_height_nozero =
    let s = parseDimensionValues(element.attr("height"))
    if s.isSome and s.get.num != 0:
      set_cv "height", s.get
  template map_bgcolor =
    let c = parseLegacyColor(element.attr("bgcolor"))
    if c.isSome:
      set_cv "background-color", c.get
  template map_valign =
    case element.attr("valign").toLowerAscii()
    of "top": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_TOP)
    of "middle": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_MIDDLE)
    of "bottom": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_BOTTOM)
    of "baseline": set_cv "vertical-align", CSSVerticalAlign(keyword: VERTICAL_ALIGN_BASELINE)
  template map_align =
    case element.attr("align").toLowerAscii()
    of "center", "middle": set_cv "text-align", TEXT_ALIGN_CHA_CENTER
    of "left": set_cv "text-align", TEXT_ALIGN_CHA_LEFT
    of "right": set_cv "text-align", TEXT_ALIGN_CHA_RIGHT
  template map_table_align =
    case element.attr("align").toLowerAscii()
    of "left":
     set_cv "margin-right", CSSLengthAuto #TODO should be float: left
    of "right":
      set_cv "margin-left", CSSLengthAuto #TODO should be float: right
    of "center":
      set_cv "margin-left", CSSLengthAuto #TODO should be inline-start
      set_cv "margin-right", CSSLengthAuto #TODO should be inline-end
  template map_text =
    let c = parseLegacyColor(element.attr("text"))
    if c.isSome:
      set_cv "color", c.get
  template map_color =
    let c = parseLegacyColor(element.attr("color"))
    if c.isSome:
      set_cv "color", c.get
  template map_colspan =
    let colspan = element.attrulgz("colspan")
    if colspan.isSome:
      let i = colspan.get
      if i <= 1000:
        set_cv "-cha-colspan", int(i)
  template map_rowspan =
    let rowspan = element.attrul("rowspan")
    if rowspan.isSome:
      let i = rowspan.get
      if i <= 65534:
        set_cv "-cha-rowspan", int(i)

  case element.tagType
  of TAG_DIV:
    map_align
  of TAG_TABLE:
    map_height_nozero
    map_width_nozero
    map_bgcolor
    map_table_align
  of TAG_TD, TAG_TH:
    map_height_nozero
    map_width_nozero
    map_bgcolor
    map_valign
    map_align
    map_colspan
    map_rowspan
  of TAG_THEAD, TAG_TBODY, TAG_TFOOT, TAG_TR:
    map_height
    map_bgcolor
    map_valign
    map_align
  of TAG_COL:
    map_width
  of TAG_IMG, TAG_CANVAS:
    map_width
    map_height
  of TAG_BODY:
    map_bgcolor
    map_text
  of TAG_TEXTAREA:
    let textarea = HTMLTextAreaElement(element)
    let cols = textarea.attrul("cols").get(20)
    let rows = textarea.attrul("rows").get(1)
    set_cv "width", CSSLength(unit: UNIT_CH, num: float64(cols))
    set_cv "height", CSSLength(unit: UNIT_EM, num: float64(rows))
  of TAG_FONT:
    map_color
  else: discard
 
proc applyDeclarations(styledNode: StyledNode, parent: CSSComputedValues, ua, user: DeclarationList, author: seq[DeclarationList]) =
  let pseudo = PSEUDO_NONE
  var builder = newComputedValueBuilder(parent)

  builder.addValues(ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(user[pseudo], ORIGIN_USER)
  for rule in author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)
  if styledNode.node != nil:
    let element = Element(styledNode.node)
    let style = element.attr("style")
    if style.len > 0:
      let inline_rules = newStringStream(style).parseListOfDeclarations2()
      builder.addValues(inline_rules, ORIGIN_AUTHOR)
    builder.preshints = element.calcPresentationalHints()

  styledNode.computed = builder.buildComputedValues()

# Either returns a new styled node or nil.
proc applyDeclarations(pseudo: PseudoElem, styledParent: StyledNode, ua,
                       user: DeclarationList, author: seq[DeclarationList]): StyledNode =
  var builder = newComputedValueBuilder(styledParent.computed)

  builder.addValues(ua[pseudo], ORIGIN_USER_AGENT)
  builder.addValues(user[pseudo], ORIGIN_USER)
  for rule in author:
    builder.addValues(rule[pseudo], ORIGIN_AUTHOR)

  if builder.hasValues():
    result = styledParent.newStyledElement(pseudo, builder.buildComputedValues())

func applyMediaQuery(ss: CSSStylesheet, window: Window): CSSStylesheet =
  if ss == nil: return nil
  result = ss
  for mq in ss.mq_list:
    if mq.query.applies(window):
      result.add(mq.children.applyMediaQuery(window))

func calcRules(styledNode: StyledNode, ua, user: CSSStylesheet, author: seq[CSSStylesheet]): tuple[uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]] =
  result.uadecls = calcRules(styledNode, ua)
  if user != nil:
    result.userdecls = calcRules(styledNode, user)
  for rule in author:
    result.authordecls.add(calcRules(styledNode, rule))

proc applyStyle(parent, styledNode: StyledNode, uadecls, userdecls: DeclarationList, authordecls: seq[DeclarationList]) =
  let parentComputed = if parent != nil:
    parent.computed
  else:
    rootProperties()

  styledNode.applyDeclarations(parentComputed, uadecls, userdecls, authordecls)

type CascadeLevel = tuple[
  styledParent: StyledNode,
  child: Node,
  pseudo: PseudoElem,
  cachedChild: StyledNode
]

# Builds a StyledNode tree, optionally based on a previously cached version.
proc applyRules(document: Document, ua, user: CSSStylesheet, cachedTree: StyledNode): StyledNode =
  if document.html == nil:
    return

  var author: seq[CSSStylesheet]
  for sheet in document.sheets():
    author.add(sheet.applyMediaQuery(document.window))

  var styledStack: seq[CascadeLevel]
  styledStack.add((nil, document.html, PSEUDO_NONE, cachedTree))

  while styledStack.len > 0:
    var (styledParent, child, pseudo, cachedChild) = styledStack.pop()

    var styledChild: StyledNode
    let valid = cachedChild != nil and cachedChild.isValid()
    if valid:
      if cachedChild.t == STYLED_ELEMENT:
        if cachedChild.pseudo == PSEUDO_NONE:
          # We can't just copy cachedChild.children from the previous pass, as
          # any child could be invalid.
          styledChild = styledParent.newStyledElement(Element(cachedChild.node), cachedChild.computed, cachedChild.depends)
        else:
          # Pseudo elements can't have invalid children.
          styledChild = cachedChild
          styledChild.parent = styledParent
      else:
        # Text
        styledChild = cachedChild
        styledChild.parent = styledParent
      if styledParent == nil:
        # Root element
        result = styledChild
      else:
        styledParent.children.add(styledChild)
    else:
      # From here on, computed values of this node's children are invalid
      # because of property inheritance.
      cachedChild = nil
      if pseudo != PSEUDO_NONE:
        let (ua, user, authordecls) = styledParent.calcRules(ua, user, author)
        case pseudo
        of PSEUDO_BEFORE, PSEUDO_AFTER:
          let styledPseudo = pseudo.applyDeclarations(styledParent, ua, user, authordecls)
          if styledPseudo != nil:
            styledParent.children.add(styledPseudo)
            let contents = styledPseudo.computed{"content"}
            for content in contents:
              styledPseudo.children.add(styledPseudo.newStyledReplacement(content))
        of PSEUDO_INPUT_TEXT:
          let content = HTMLInputElement(styledParent.node).inputString()
          if content.len > 0:
            let styledText = styledParent.newStyledText(content)
            # Note: some pseudo-elements (like input text) generate text nodes
            # directly, so we have to cache them like this.
            styledText.pseudo = pseudo
            styledParent.children.add(styledText)
        of PSEUDO_TEXTAREA_TEXT:
          let content = HTMLTextAreaElement(styledParent.node).textAreaString()
          if content.len > 0:
            let styledText = styledParent.newStyledText(content)
            styledText.pseudo = pseudo
            styledParent.children.add(styledText)
        of PSEUDO_IMAGE:
          let content = CSSContent(t: CONTENT_IMAGE, s: "[img]")
          let styledText = styledParent.newStyledReplacement(content)
          styledText.pseudo = pseudo
          styledParent.children.add(styledText)
        of PSEUDO_NEWLINE:
          let content = CSSContent(t: CONTENT_NEWLINE)
          let styledText = styledParent.newStyledReplacement(content)
          styledText.pseudo = pseudo
          styledParent.children.add(styledText)
        of PSEUDO_NONE: discard
      else:
        assert child != nil
        if styledParent != nil:
          if child.nodeType == ELEMENT_NODE:
            styledChild = styledParent.newStyledElement(Element(child))
            styledParent.children.add(styledChild)
            let (ua, user, authordecls) = styledChild.calcRules(ua, user, author)
            applyStyle(styledParent, styledChild, ua, user, authordecls)
          elif child.nodeType == TEXT_NODE:
            let text = Text(child)
            styledChild = styledParent.newStyledText(text)
            styledParent.children.add(styledChild)
        else:
          # Root element
          styledChild = newStyledElement(Element(child))
          let (ua, user, authordecls) = styledChild.calcRules(ua, user, author)
          applyStyle(styledParent, styledChild, ua, user, authordecls)
          result = styledChild

    if styledChild != nil and styledChild.t == STYLED_ELEMENT and styledChild.node != nil:
      styledChild.applyDependValues()
      # i points to the child currently being inspected.
      var i = if cachedChild != nil:
        cachedChild.children.len - 1
      else:
        -1
      template stack_append(styledParent: StyledNode, child: Node) =
        if cachedChild != nil:
          var cached: StyledNode
          while i >= 0:
            let it = cachedChild.children[i]
            dec i
            if it.node == child:
              cached = it
              break
          styledStack.add((styledParent, child, PSEUDO_NONE, cached))
        else:
          styledStack.add((styledParent, child, PSEUDO_NONE, nil))

      template stack_append(styledParent: StyledNode, ps: PseudoElem) =
        if cachedChild != nil:
          var cached: StyledNode
          let oldi = i
          while i >= 0:
            let it = cachedChild.children[i]
            dec i
            if it.pseudo == ps:
              cached = it
              break
          # When calculating pseudo-element rules, their dependencies are added
          # to their parent's dependency list; so invalidating a pseudo-element
          # invalidates its parent too, which in turn automatically rebuilds
          # the pseudo-element.
          # In other words, we can just do this:
          if cached != nil:
            styledStack.add((styledParent, nil, ps, cached))
          else:
            i = oldi # move pointer back to where we started
        else:
          styledStack.add((styledParent, nil, ps, nil))

      let elem = Element(styledChild.node)

      stack_append styledChild, PSEUDO_AFTER

      if elem.tagType == TAG_TEXTAREA:
        stack_append styledChild, PSEUDO_TEXTAREA_TEXT
      elif elem.tagType == TAG_IMG or elem.tagType == TAG_IMAGE:
        stack_append styledChild, PSEUDO_IMAGE
      elif elem.tagType == TAG_BR:
        stack_append styledChild, PSEUDO_NEWLINE
      else:
        for i in countdown(elem.childList.high, 0):
          if elem.childList[i].nodeType in {ELEMENT_NODE, TEXT_NODE}:
            stack_append styledChild, elem.childList[i]
        if elem.tagType == TAG_INPUT:
          stack_append styledChild, PSEUDO_INPUT_TEXT

      stack_append styledChild, PSEUDO_BEFORE

proc applyStylesheets*(document: Document, uass, userss: CSSStylesheet,
    previousStyled: StyledNode): StyledNode =
  let uass = uass.applyMediaQuery(document.window)
  let userss = userss.applyMediaQuery(document.window)
  return document.applyRules(uass, userss, previousStyled)
