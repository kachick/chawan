import unicode
import tables
import strutils
import sequtils
import sugar
import streams

import css/selectorparser
import css/cssparser
import html/dom

func attrSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.rel
  of ' ': return sel.attr in elem.attributes
  of '=': return elem.attr(sel.attr) == sel.value
  of '~': return sel.value in unicode.split(elem.attr(sel.attr))
  of '|':
    let val = elem.attr(sel.attr)
    return val == sel.value or sel.value.startsWith(val & '-')
  of '^': return elem.attr(sel.attr).startsWith(sel.value)
  of '$': return elem.attr(sel.attr).endsWith(sel.value)
  of '*': return elem.attr(sel.attr).contains(sel.value)
  else: return false

func pseudoSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.pseudo
  of PSEUDO_FIRST_CHILD: return elem.parentNode.firstElementChild == elem
  of PSEUDO_LAST_CHILD: return elem.parentNode.lastElementChild == elem
  of PSEUDO_ONLY_CHILD: return elem.parentNode.firstElementChild == elem and elem.parentNode.lastElementChild == elem
  of PSEUDO_HOVER: return elem.hover
  of PSEUDO_ROOT: return elem == elem.ownerDocument.root
  of PSEUDO_NTH_CHILD: return int64(sel.pseudonum - 1) in elem.parentNode.children.low..elem.parentNode.children.high and elem.parentNode.children[int64(sel.pseudonum - 1)] == elem

func selectorsMatch*(elem: Element, selectors: SelectorList): bool

func funcSelectorMatches(elem: Element, sel: Selector): bool =
  case sel.name
  of "not":
    for slist in sel.fsels:
      if elem.selectorsMatch(slist):
        return false
    return true
  of "is", "where":
    for slist in sel.fsels:
      if elem.selectorsMatch(slist):
        return true
    return false
  else: discard

func combinatorSelectorMatches(elem: Element, sel: Selector): bool =
  #combinator without at least two members makes no sense
  assert sel.csels.len > 1
  if elem.selectorsMatch(sel.csels[^1]):
    var i = sel.csels.len - 2
    case sel.ct
    of DESCENDANT_COMBINATOR:
      var e = elem.parentElement
      while e != nil and i >= 0:
        if e.selectorsMatch(sel.csels[i]):
          dec i
        e = e.parentElement
    of CHILD_COMBINATOR:
      var e = elem.parentElement
      while e != nil and i >= 0:
        if not e.selectorsMatch(sel.csels[i]):
          return false
        dec i
        e = e.parentElement
    of NEXT_SIBLING_COMBINATOR:
      var e = elem.previousElementSibling
      while e != nil and i >= 0:
        if not e.selectorsMatch(sel.csels[i]):
          return false
        dec i
        e = e.previousElementSibling
    of SUBSEQ_SIBLING_COMBINATOR:
      var e = elem.previousElementSibling
      while e != nil and i >= 0:
        if e.selectorsMatch(sel.csels[i]):
          dec i
        e = e.previousElementSibling
    return i == -1
  return false

func selectorMatches(elem: Element, sel: Selector): bool =
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
    return pseudoSelectorMatches(elem, sel)
  of PSELEM_SELECTOR:
    return true
  of UNIVERSAL_SELECTOR:
    return true
  of FUNC_SELECTOR:
    return funcSelectorMatches(elem, sel)
  of COMBINATOR_SELECTOR:
    return combinatorSelectorMatches(elem, sel)

func selectorsMatch*(elem: Element, selectors: SelectorList): bool =
  for sel in selectors.sels:
    if not selectorMatches(elem, sel):
      return false
  return true

func selectElems(document: Document, sel: Selector): seq[Element] =
  case sel.t
  of TYPE_SELECTOR:
    return document.type_elements[sel.tag]
  of ID_SELECTOR:
    return document.id_elements.getOrDefault(sel.id, newSeq[Element]())
  of CLASS_SELECTOR:
    return document.class_elements.getOrDefault(sel.class, newSeq[Element]())
  of UNIVERSAL_SELECTOR:
    return document.all_elements
  of ATTR_SELECTOR:
    return document.all_elements.filter((elem) => attrSelectorMatches(elem, sel))
  of PSEUDO_SELECTOR:
    return document.all_elements.filter((elem) => pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return document.all_elements
  of FUNC_SELECTOR:
    return document.all_elements.filter((elem) => selectorMatches(elem, sel))
  of COMBINATOR_SELECTOR:
    return document.all_elements.filter((elem) => selectorMatches(elem, sel))

func selectElems(document: Document, selectors: SelectorList): seq[Element] =
  assert(selectors.len > 0)
  let sellist = optimizeSelectorList(selectors)
  result = document.selectElems(selectors[0])
  var i = 1

  while i < sellist.len:
    result = result.filter((elem) => selectorMatches(elem, sellist[i]))
    inc i

func selectElems(element: Element, sel: Selector): seq[Element] =
  case sel.t
  of TYPE_SELECTOR:
    return element.filterDescendants((elem) => elem.tagType == sel.tag)
  of ID_SELECTOR:
    return element.filterDescendants((elem) => elem.id == sel.id)
  of CLASS_SELECTOR:
    return element.filterDescendants((elem) => sel.class in elem.classList)
  of UNIVERSAL_SELECTOR:
    return element.all_descendants
  of ATTR_SELECTOR:
    return element.filterDescendants((elem) => attrSelectorMatches(elem, sel))
  of PSEUDO_SELECTOR:
    return element.filterDescendants((elem) => pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return element.all_descendants
  of FUNC_SELECTOR:
    return element.filterDescendants((elem) => selectorMatches(elem, sel))
  of COMBINATOR_SELECTOR:
    return element.filterDescendants((elem) => selectorMatches(elem, sel))

func selectElems(element: Element, selectors: SelectorList): seq[Element] =
  assert(selectors.len > 0)
  let sellist = optimizeSelectorList(selectors)
  result = element.selectElems(selectors[0])
  var i = 1

  while i < sellist.len:
    result = result.filter((elem) => selectorMatches(elem, sellist[i]))
    inc i

proc querySelectorAll*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))

proc querySelector*(document: Document, q: string): Element =
  let elems = document.querySelectorAll(q)
  if elems.len > 0:
    return elems[0]
  return nil

proc querySelectorAll*(element: Element, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(element.selectElems(sel))

proc querySelector*(element: Element, q: string): Element =
  let elems = element.querySelectorAll(q)
  if elems.len > 0:
    return elems[0]
  return nil
