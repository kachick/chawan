import unicode
import tables
import strutils
import sequtils
import sugar
import streams

import css/selparser
import css/parser
import html/dom

type SelectResult* = object
  success*: bool
  pseudo*: PseudoElem

func selectres(s: bool, p: PseudoElem = PSEUDO_NONE): SelectResult =
  return SelectResult(success: s, pseudo: p)

func psuccess(s: SelectResult): bool =
  return s.pseudo == PSEUDO_NONE and s.success

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
  of "first-child": return elem.parentNode.firstElementChild == elem
  of "last-child": return elem.parentNode.lastElementChild == elem
  of "only-child": return elem.parentNode.firstElementChild == elem and elem.parentNode.lastElementChild == elem
  of "hover": return elem.hover
  of "root": return elem == elem.ownerDocument.root
  else: return false

func pseudoElemSelectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.elem
  of "before": return selectres(true, PSEUDO_BEFORE)
  of "after": return selectres(true, PSEUDO_AFTER)
  else: return selectres(false)

func selectorsMatch*(elem: Element, selectors: SelectorList): SelectResult

func funcSelectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.name
  of "not":
    for slist in sel.fsels:
      let res = elem.selectorsMatch(slist)
      if res.success:
        return selectres(false)
    return selectres(true)
  of "is", "where":
    for slist in sel.fsels:
      let res = elem.selectorsMatch(slist)
      if res.success:
        return selectres(true)
    return selectres(false)
  else: discard

func selectorMatches(elem: Element, sel: Selector): SelectResult =
  case sel.t
  of TYPE_SELECTOR:
    return selectres(elem.tagType == sel.tag)
  of CLASS_SELECTOR:
    return selectres(sel.class in elem.classList)
  of ID_SELECTOR:
    return selectres(sel.id == elem.id)
  of ATTR_SELECTOR:
    return selectres(elem.attrSelectorMatches(sel))
  of PSEUDO_SELECTOR:
    return selectres(pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return pseudoElemSelectorMatches(elem, sel)
  of UNIVERSAL_SELECTOR:
    return selectres(true)
  of FUNC_SELECTOR:
    return funcSelectorMatches(elem, sel)
  of COMBINATOR_SELECTOR:
    #combinator without at least two members makes no sense
    assert sel.csels.len > 1
    let match = elem.selectorsMatch(sel.csels[^1])
    if match.success:
      var i = sel.csels.len - 2
      case sel.ct
      of DESCENDANT_COMBINATOR:
        var e = elem.parentElement
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if res.success:
            dec i
          e = e.parentElement
      of CHILD_COMBINATOR:
        var e = elem.parentElement
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if not res.success:
            return selectres(false)
          dec i
          e = e.parentElement
      of NEXT_SIBLING_COMBINATOR:
        var e = elem.previousElementSibling
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if not res.success:
            return selectres(false)
          dec i
          e = e.previousElementSibling
      of SUBSEQ_SIBLING_COMBINATOR:
        var e = elem.previousElementSibling
        while e != nil and i >= 0:
          let res = e.selectorsMatch(sel.csels[i])

          if res.pseudo != PSEUDO_NONE:
            return selectres(false)

          if res.success:
            dec i
          e = e.previousElementSibling
      return selectres(i == -1, match.pseudo)
    else:
      return selectres(false)

func selectorsMatch*(elem: Element, selectors: SelectorList): SelectResult =
  for sel in selectors.sels:
    let res = selectorMatches(elem, sel)
    if not res.success:
      return selectres(false)
    if res.pseudo != PSEUDO_NONE:
      if result.pseudo != PSEUDO_NONE:
        return selectres(false)
      result.pseudo = res.pseudo
  result.success = true

func selectElems(document: Document, sel: Selector): seq[Element] =
  case sel.t
  of TYPE_SELECTOR:
    return document.type_elements[sel.tag]
  of ID_SELECTOR:
    return document.id_elements[sel.id]
  of CLASS_SELECTOR:
    return document.class_elements[sel.class]
  of UNIVERSAL_SELECTOR:
    return document.all_elements
  of ATTR_SELECTOR:
    return document.all_elements.filter((elem) => attrSelectorMatches(elem, sel))
  of PSEUDO_SELECTOR:
    return document.all_elements.filter((elem) => pseudoSelectorMatches(elem, sel))
  of PSELEM_SELECTOR:
    return document.all_elements.filter((elem) => pseudoElemSelectorMatches(elem, sel))
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
    result = result.filter((elem) => selectorMatches(elem, sellist[i]).psuccess)
    inc i

proc querySelector*(document: Document, q: string): seq[Element] =
  let ss = newStringStream(q)
  let cvals = parseListOfComponentValues(ss)
  let selectors = parseSelectors(cvals)

  for sel in selectors:
    result.add(document.selectElems(sel))

