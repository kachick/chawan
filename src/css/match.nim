import options
import strutils
import tables

import css/cssparser
import css/selectorparser
import css/stylednode
import html/dom
import html/tags

func attrSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.rel
  of ' ': return sel.attr in elem.attributes
  of '=': return elem.attr(sel.attr) == sel.value
  of '~': return sel.value in elem.attr(sel.attr).split(Whitespace)
  of '|':
    let val = elem.attr(sel.attr)
    return val == sel.value or sel.value.startsWith(val & '-')
  of '^': return elem.attr(sel.attr).startsWith(sel.value)
  of '$': return elem.attr(sel.attr).endsWith(sel.value)
  of '*': return elem.attr(sel.attr).contains(sel.value)
  else: return false

func selectorsMatch*[T: Element|StyledNode](elem: T, selectors: ComplexSelector, felem: T = nil): bool

func selectorsMatch*[T: Element|StyledNode](elem: T, selectors: SelectorList, felem: T = nil): bool =
  for slist in selectors:
    if elem.selectorsMatch(slist, felem):
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
    if sel.pseudo.ofsels.issome and not selem.selectorsMatch(sel.pseudo.ofsels.get, felem):
      return false
    let A = sel.pseudo.anb.A # step
    let B = sel.pseudo.anb.B # start
    var i = 1
    let parent = when selem is StyledNode: selem.parent
    else: selem.parentNode
    if parent == nil: return false
    for child in parent.children:
      when selem is StyledNode:
        if not child.isDomElement: continue
      if child == selem:
        if A == 0:
          return i == B
        if A < 0:
          return (i - B) <= 0 and (i - B) mod A == 0
        return (i - B) >= 0 and (i - B) mod A == 0
      if sel.pseudo.ofsels.isnone or child.selectorsMatch(sel.pseudo.ofsels.get, felem):
        inc i
    return false
  of PSEUDO_NTH_LAST_CHILD:
    if sel.pseudo.ofsels.issome and not selem.selectorsMatch(sel.pseudo.ofsels.get, felem):
      return false
    let A = sel.pseudo.anb.A # step
    let B = sel.pseudo.anb.B # start
    var i = 1
    let parent = when selem is StyledNode: selem.parent
    else: selem.parentNode
    if parent == nil: return false
    for child in parent.children_rev:
      when selem is StyledNode:
        if not child.isDomElement: continue
      if child == selem:
        if A == 0:
          return i == B
        if A < 0:
          return (i - B) <= 0 and (i - B) mod A == 0
        return (i - B) >= 0 and (i - B) mod A == 0
      if sel.pseudo.ofsels.isnone or child.selectorsMatch(sel.pseudo.ofsels.get, felem):
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

func combinatorSelectorMatches[T: Element|StyledNode](elem: T, sel: Selector, felem: T): bool =
  let selem = elem
  #combinator without at least two members makes no sense
  assert sel.csels.len > 1
  if selem.selectorsMatch(sel.csels[^1], felem):
    var i = sel.csels.len - 2
    case sel.ct
    of DESCENDANT_COMBINATOR:
      when selem is StyledNode:
        var e = elem.parent
      else:
        var e = elem.parentElement
      while e != nil and i >= 0:
        if e.selectorsMatch(sel.csels[i], felem):
          dec i
        when elem is StyledNode:
          e = e.parent
        else:
          e = e.parentElement
    of CHILD_COMBINATOR:
      when elem is StyledNode:
        var e = elem.parent
      else:
        var e = elem.parentElement
      while e != nil and i >= 0:
        if not e.selectorsMatch(sel.csels[i], felem):
          return false
        dec i
        when elem is StyledNode:
          e = e.parent
        else:
          e = e.parentElement
    of NEXT_SIBLING_COMBINATOR:
      var found = false
      when elem is StyledNode:
        var parent = elem.parent
      else:
        var parent = elem.parentElement
      for child in parent.children_rev:
        when elem is StyledNode:
          if child.t != STYLED_ELEMENT or child.node == nil: continue
        if found:
          if not child.selectorsMatch(sel.csels[i], felem):
            return false
          dec i
          if i < 0:
            return true
        if child == elem:
          found = true
    of SUBSEQ_SIBLING_COMBINATOR:
      var found = false
      when selem is StyledNode:
        var parent = selem.parent
      else:
        var parent = elem.parentElement
      for child in parent.children_rev:
        when selem is StyledNode:
          if child.t != STYLED_ELEMENT or child.node == nil: continue
        if found:
          if child.selectorsMatch(sel.csels[i], felem):
            dec i
          if i < 0:
            return true
        if child == selem:
          found = true
    return i == -1
  return false

func selectorMatches[T: Element|StyledNode](elem: T, sel: Selector, felem: T): bool =
  let selem = elem
  when elem is StyledNode:
    let elem = Element(selem.node)
  case sel.t
  of TYPE_SELECTOR:
    return elem.tagType == sel.tag
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
  of COMBINATOR_SELECTOR:
    return combinatorSelectorMatches(selem, sel, felem)

# WARNING for StyledNode, this has the side effect of modifying depends.
#TODO make that an explicit flag or something, also get rid of the Element case
func selectorsMatch*[T: Element|StyledNode](elem: T, selectors: ComplexSelector, felem: T = nil): bool =
  let felem = if felem != nil:
    felem
  else:
    elem

  for sel in selectors:
    if not selectorMatches(elem, sel, felem):
      return false
  return true

#TODO idk, it's not like we have JS anyways
#func selectElems[T: Element|StyledNode](element: T, sel: Selector, felem: T): seq[T] =
#  case sel.t
#  of TYPE_SELECTOR:
#    return element.filterDescendants((elem) => elem.tagType == sel.tag)
#  of ID_SELECTOR:
#    return element.filterDescendants((elem) => elem.id == sel.id)
#  of CLASS_SELECTOR:
#    return element.filterDescendants((elem) => sel.class in elem.classList)
#  of UNIVERSAL_SELECTOR:
#    return element.all_descendants
#  of ATTR_SELECTOR:
#    return element.filterDescendants((elem) => attrSelectorMatches(elem, sel))
#  of PSEUDO_SELECTOR:
#    return element.filterDescendants((elem) => pseudoSelectorMatches(elem, sel, felem))
#  of PSELEM_SELECTOR:
#    return element.all_descendants
#  of FUNC_SELECTOR:
#    return element.filterDescendants((elem) => selectorMatches(elem, sel))
#  of COMBINATOR_SELECTOR:
#    return element.filterDescendants((elem) => selectorMatches(elem, sel))
#
#func selectElems(element: Element, selectors: SelectorList): seq[Element] =
#  assert(selectors.len > 0)
#  let sellist = optimizeSelectorList(selectors)
#  result = element.selectElems(selectors[0], element)
#  var i = 1
#
#  while i < sellist.len:
#    result = result.filter((elem) => selectorMatches(elem, sellist[i], elem))
#    inc i
#
#proc querySelectorAll*(document: Document, q: string): seq[Element] =
#  let ss = newStringStream(q)
#  let cvals = parseListOfComponentValues(ss)
#  let selectors = parseSelectors(cvals)
#
#  if document.html != nil:
#    for sel in selectors:
#      result.add(document.html.selectElems(sel))
#
#proc querySelector*(document: Document, q: string): Element =
#  let elems = document.querySelectorAll(q)
#  if elems.len > 0:
#    return elems[0]
#  return nil
#
#proc querySelectorAll*(element: Element, q: string): seq[Element] =
#  let ss = newStringStream(q)
#  let cvals = parseListOfComponentValues(ss)
#  let selectors = parseSelectors(cvals)
#
#  for sel in selectors:
#    result.add(element.selectElems(sel))
#
#proc querySelector*(element: Element, q: string): Element =
#  let elems = element.querySelectorAll(q)
#  if elems.len > 0:
#    return elems[0]
#  return nil
