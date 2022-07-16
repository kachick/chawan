import css/values
import html/dom

# Container to hold a style and a node.
# Pseudo elements are implemented using StyledNode objects without nodes.
type
  StyledType* = enum
    STYLED_ELEMENT, STYLED_TEXT

  StyledNode* = ref object
    case t*: StyledType
    of STYLED_ELEMENT:
      pseudo*: PseudoElem
      computed*: CSSComputedValues
    of STYLED_TEXT:
      text*: string
    node*: Node
    children*: seq[StyledNode]
