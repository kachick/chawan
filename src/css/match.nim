import std/options
import std/streams
import std/strutils
import std/tables

import css/cssparser
import css/selectorparser
import css/stylednode
import html/catom
import html/dom
import html/enums
import utils/twtstr

import chame/tags

#TODO FLAG_NONE should match insensitively for certain properties
func attrSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.rel.t
  of RELATION_EXISTS: return elem.attrb(sel.attr)
  of RELATION_EQUALS:
    case sel.rel.flag
    of FLAG_NONE: return elem.attr(sel.attr) == sel.value
    of FLAG_I: return elem.attr(sel.attr).equalsIgnoreCase(sel.value)
    of FLAG_S: return elem.attr(sel.attr) == sel.value
  of RELATION_TOKEN:
    let val = elem.attr(sel.attr)
    case sel.rel.flag
    of FLAG_NONE: return sel.value in val.split(AsciiWhitespace)
    of FLAG_I:
      let val = val.toLowerAscii()
      let selval = sel.value.toLowerAscii()
      return selval in val.split(AsciiWhitespace)
    of FLAG_S: return sel.value in val.split(AsciiWhitespace)
  of RELATION_BEGIN_DASH:
    let val = elem.attr(sel.attr)
    case sel.rel.flag
    of FLAG_NONE: return val == sel.value or sel.value.startsWith(val & '-')
    of FLAG_I:
      return val.equalsIgnoreCase(sel.value) or
        sel.value.startsWithIgnoreCase(val & '-')
    of FLAG_S: return val == sel.value or sel.value.startsWith(val & '-')
  of RELATION_STARTS_WITH:
    let val = elem.attr(sel.attr)
    case sel.rel.flag
    of FLAG_NONE: return val.startsWith(sel.value)
    of FLAG_I: return val.startsWithIgnoreCase(sel.value)
    of FLAG_S: return val.startsWith(sel.value)
  of RELATION_ENDS_WITH:
    let val = elem.attr(sel.attr)
    case sel.rel.flag
    of FLAG_NONE: return val.endsWith(sel.value)
    of FLAG_I: return val.endsWithIgnoreCase(sel.value)
    of FLAG_S: return val.endsWith(sel.value)
  of RELATION_CONTAINS:
    let val = elem.attr(sel.attr)
    case sel.rel.flag
    of FLAG_NONE: return val.contains(sel.value)
    of FLAG_I:
      let val = val.toLowerAscii()
      let selval = sel.value.toLowerAscii()
      return val.contains(selval)
    of FLAG_S: return val.contains(sel.value)

func selectorsMatch*[T: Element|StyledNode](elem: T, cxsel: ComplexSelector, felem: T = nil): bool

func selectorsMatch*[T: Element|StyledNode](elem: T, slist: SelectorList, felem: T = nil): bool =
  for cxsel in slist:
    if elem.selectorsMatch(cxsel, felem):
      return true
  return false

func pseudoSelectorMatches[T: Element|StyledNode](elem: T, sel: Selector, felem: T): bool =
  let selem = elem
  when elem is StyledNode:
    let elem = Element(elem.node)
  case sel.pseudo.t
  of PSEUDO_FIRST_CHILD: return elem.parentNode.firstElementChild == elem
  of PSEUDO_LAST_CHILD: return elem.parentNode.lastElementChild == elem
  of PSEUDO_ONLY_CHILD: return elem.parentNode.firstElementChild == elem and elem.parentNode.lastElementChild == elem
  of PSEUDO_HOVER:
    when selem is StyledNode: felem.addDependency(selem, DEPEND_HOVER)
    return elem.hover
  of PSEUDO_ROOT: return elem == elem.document.html
  of PSEUDO_NTH_CHILD:
    if sel.pseudo.ofsels.len != 0 and not selem.selectorsMatch(sel.pseudo.ofsels, felem):
      return false
    let A = sel.pseudo.anb.A # step
    let B = sel.pseudo.anb.B # start
    var i = 1
    let parent = when selem is StyledNode: selem.parent
    else: selem.parentNode
    if parent == nil: return false
    for child in parent.elementList:
      when selem is StyledNode:
        if not child.isDomElement: continue
      if child == selem:
        if A == 0:
          return i == B
        if A < 0:
          return (i - B) <= 0 and (i - B) mod A == 0
        return (i - B) >= 0 and (i - B) mod A == 0
      if sel.pseudo.ofsels.len == 0 or child.selectorsMatch(sel.pseudo.ofsels, felem):
        inc i
    return false
  of PSEUDO_NTH_LAST_CHILD:
    if sel.pseudo.ofsels.len == 0 and not selem.selectorsMatch(sel.pseudo.ofsels, felem):
      return false
    let A = sel.pseudo.anb.A # step
    let B = sel.pseudo.anb.B # start
    var i = 1
    let parent = when selem is StyledNode: selem.parent
    else: selem.parentNode
    if parent == nil: return false
    for child in parent.elementList_rev:
      when selem is StyledNode:
        if not child.isDomElement: continue
      if child == selem:
        if A == 0:
          return i == B
        if A < 0:
          return (i - B) <= 0 and (i - B) mod A == 0
        return (i - B) >= 0 and (i - B) mod A == 0
      if sel.pseudo.ofsels.len != 0 or child.selectorsMatch(sel.pseudo.ofsels, felem):
        inc i
    return false
  of PSEUDO_CHECKED:
    when selem is StyledNode: felem.addDependency(selem, DEPEND_CHECKED)
    if elem.tagType == TAG_INPUT:
      return HTMLInputElement(elem).checked
    elif elem.tagType == TAG_OPTION:
      return HTMLOptionElement(elem).selected
    return false
  of PSEUDO_FOCUS:
    when selem is StyledNode: felem.addDependency(selem, DEPEND_FOCUS)
    return elem.document.focus == elem
  of PSEUDO_NOT:
    return not selem.selectorsMatch(sel.pseudo.fsels, felem)
  of PSEUDO_IS, PSEUDO_WHERE:
    return selem.selectorsMatch(sel.pseudo.fsels, felem)
  of PSEUDO_LANG:
    return sel.pseudo.s == "en" #TODO languages?
  of PSEUDO_LINK:
    return elem.tagType in {TAG_A, TAG_AREA} and elem.attrb(atHref)
  of PSEUDO_VISITED:
    return false

func selectorMatches[T: Element|StyledNode](elem: T, sel: Selector, felem: T = nil): bool =
  let selem = elem
  when elem is StyledNode:
    let elem = Element(selem.node)
  case sel.t
  of TYPE_SELECTOR:
    return elem.localName == sel.tag
  of CLASS_SELECTOR:
    return sel.class in elem.classList
  of ID_SELECTOR:
    return sel.id == elem.id
  of ATTR_SELECTOR:
    return elem.attrSelectorMatches(sel)
  of PSEUDO_SELECTOR:
    return pseudoSelectorMatches(selem, sel, felem)
  of PSELEM_SELECTOR:
    return true
  of UNIVERSAL_SELECTOR:
    return true

func selectorsMatch[T: Element|StyledNode](elem: T, sels: CompoundSelector, felem: T): bool =
  for sel in sels:
    if not selectorMatches(elem, sel, felem):
      return false
  return true

func complexSelectorMatches[T: Element|StyledNode](elem: T, cxsel: ComplexSelector, felem: T = nil): bool =
  var e = elem
  for i in countdown(cxsel.high, 0):
    let sels = cxsel[i]
    if e == nil:
      return false
    var match = false
    case sels.ct
    of NO_COMBINATOR:
      match = e.selectorsMatch(sels, felem)
    of DESCENDANT_COMBINATOR:
      e = e.parentElement
      while e != nil:
        if e.selectorsMatch(sels, felem):
          match = true
          break
        e = e.parentElement
    of CHILD_COMBINATOR:
      e = e.parentElement
      if e != nil:
        match = e.selectorsMatch(sels, felem)
    of NEXT_SIBLING_COMBINATOR:
      if e.parentElement == nil: return false
      var found = false
      for child in e.parentElement.elementList_rev:
        when elem is StyledNode:
          if not child.isDomElement: continue
        if e == child:
          found = true
          continue
        if found:
          e = child
          match = e.selectorsMatch(sels, felem)
          break
    of SUBSEQ_SIBLING_COMBINATOR:
      var found = false
      if e.parentElement == nil: return false
      for child in e.parentElement.elementList_rev:
        when elem is StyledNode:
          if not child.isDomElement: continue
        if child == elem:
          found = true
          continue
        if not found: continue
        if child.selectorsMatch(sels, felem):
          e = child
          match = true
          break
    if not match:
      return false
  return true

# WARNING for StyledNode, this has the side effect of modifying depends.
#TODO make that an explicit flag or something, also get rid of the Element case
func selectorsMatch*[T: Element|StyledNode](elem: T, cxsel: ComplexSelector, felem: T = nil): bool =
  var felem = if felem != nil:
    felem
  else:
    elem
  return elem.complexSelectorMatches(cxsel, felem)

proc querySelectorAll(node: Node, q: string): seq[Element] =
  let selectors = parseSelectors(newStringStream(q), node.document.factory)
  for element in node.elements:
    if element.selectorsMatch(selectors):
      result.add(element)
doqsa = (proc(node: Node, q: string): seq[Element] = querySelectorAll(node, q))

proc querySelector(node: Node, q: string): Element =
  let selectors = parseSelectors(newStringStream(q), node.document.factory)
  for element in node.elements:
    if element.selectorsMatch(selectors):
      return element
  return nil
doqs = (proc(node: Node, q: string): Element = querySelector(node, q))
