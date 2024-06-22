import chame/tags
import css/cssvalues
import css/selectorparser
import html/dom

# Container to hold a style and a node.
# Pseudo-elements are implemented using StyledNode objects without nodes. Input
# elements are implemented as internal "pseudo-elements."
#
# To avoid having to invalidate the entire tree on pseudo-class changes, each
# node holds a list of nodes their CSS values depend on. (This list may include
# the node itself.) In addition, nodes also store each value valid for
# dependency d. These are then used for checking the validity of StyledNodes.
#
# In other words - say we have to apply the author stylesheets of the following
# document:
#
# <style>
# div:hover { color: red; }
# :not(input:checked) + p { display: none; }
# </style>
# <div>This div turns red on hover.</div>
# <input type=checkbox>
# <p>This paragraph is only shown when the checkbox above is checked.
#
# That produces the following dependency graph (simplified):
# div -> div (hover)
# p -> input (checked)
#
# Then, to check if a node has been invalidated, we just iterate over all
# recorded dependencies of each StyledNode, and check if their registered value
# of the pseudo-class still matches that of its associated element.
#
# So in our example, for div we check if div's :hover pseudo-class has changed,
# for p we check whether input's :checked pseudo-class has changed.

type
  StyledType* = enum
    stElement, stText, stReplacement

  DependencyInfo = array[DependencyType, seq[Element]]

  StyledNode* = ref object
    parent*: StyledNode
    node*: Node
    pseudo*: PseudoElem
    case t*: StyledType
    of stText:
      discard
    of stElement:
      computed*: CSSComputedValues
      children*: seq[StyledNode]
      # All elements we depend on, for each dependency type d.
      depends*: DependencyInfo
    of stReplacement:
      # replaced elements: quotes, or (TODO) markers, images
      content*: CSSContent

func textData*(styledNode: StyledNode): string =
  return Text(styledNode.node).data

# For debugging
func `$`*(node: StyledNode): string =
  if node == nil:
    return "nil"
  case node.t
  of stText:
    return "#text " & node.textData
  of stElement:
    if node.node != nil:
      return $node.node
    return $node.pseudo
  of stReplacement:
    return "#replacement"

iterator branch*(node: StyledNode): StyledNode {.inline.} =
  var node = node
  while node != nil:
    yield node
    node = node.parent

iterator elementList*(node: StyledNode): StyledNode {.inline.} =
  for child in node.children:
    yield child

iterator elementList_rev*(node: StyledNode): StyledNode {.inline.} =
  for i in countdown(node.children.high, 0):
    yield node.children[i]

func findElement*(root: StyledNode; elem: Element): StyledNode =
  var stack: seq[StyledNode]
  for child in root.elementList_rev:
    if child.t == stElement and child.pseudo == peNone:
      stack.add(child)
  let en = Node(elem)
  while stack.len > 0:
    let node = stack.pop()
    if node.node == en:
      return node
    for child in node.elementList_rev:
      if child.t == stElement and child.pseudo == peNone:
        stack.add(child)

func isDomElement*(styledNode: StyledNode): bool {.inline.} =
  styledNode.t == stElement and styledNode.pseudo == peNone

# DOM-style getters, for Element interoperability...
func parentElement*(node: StyledNode): StyledNode {.inline.} =
  node.parent

func checked(element: Element): bool =
  if element.tagType == TAG_INPUT:
    let input = HTMLInputElement(element)
    result = input.checked

func isValid*(styledNode: StyledNode): bool =
  if styledNode.t == stText:
    return true
  if styledNode.t == stReplacement:
    return true
  if styledNode.node != nil and Element(styledNode.node).invalid:
    return false
  for d in DependencyType:
    for elem in styledNode.depends[d]:
      case d
      of dtHover:
        if elem.prev[d] != elem.hover:
          return false
      of dtChecked:
        if elem.prev[d] != elem.checked:
          return false
      of dtFocus:
        let focus = elem.document.focus == elem
        if elem.prev[d] != focus:
          return false
  return true

proc applyDependValues*(styledNode: StyledNode) =
  let elem = Element(styledNode.node)
  elem.prev[dtHover] = elem.hover
  elem.prev[dtChecked] = elem.checked
  let focus = elem.document.focus == elem
  elem.prev[dtFocus] = focus
  elem.invalid = false

proc addDependency*(styledNode: StyledNode; dep: Element; t: DependencyType) =
  if dep notin styledNode.depends[t]:
    styledNode.depends[t].add(dep)

func newStyledElement*(parent: StyledNode; element: Element;
    computed: CSSComputedValues; reg: DependencyInfo): StyledNode =
  return StyledNode(
    t: stElement,
    computed: computed,
    node: element,
    parent: parent,
    depends: reg
  )

func newStyledElement*(parent: StyledNode; element: Element): StyledNode =
  return StyledNode(t: stElement, node: element, parent: parent)

# Root
func newStyledElement*(element: Element): StyledNode =
  return StyledNode(t: stElement, node: element)

func newStyledElement*(parent: StyledNode; pseudo: PseudoElem;
    computed: CSSComputedValues; reg: DependencyInfo): StyledNode =
  return StyledNode(
    t: stElement,
    computed: computed,
    pseudo: pseudo,
    parent: parent,
    depends: reg
  )

func newStyledElement*(parent: StyledNode; pseudo: PseudoElem;
    computed: CSSComputedValues): StyledNode =
  return StyledNode(
    t: stElement,
    computed: computed,
    pseudo: pseudo,
    parent: parent
  )

func newStyledText*(parent: StyledNode; text: Text): StyledNode =
  return StyledNode(t: stText, node: text, parent: parent)

func newStyledReplacement*(parent: StyledNode; content: CSSContent):
    StyledNode =
  return StyledNode(t: stReplacement, parent: parent, content: content)
