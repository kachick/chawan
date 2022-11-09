import options
import os
import terminal
import unicode

import config/config
import io/buffer
import io/cell
import io/lineedit
import io/loader
import io/request
import io/term
import js/javascript
import js/regex
import types/url
import utils/twtstr

type
  Container = ref object
    buffer*: Buffer
    children: seq[Container]
    pos: CursorPosition
    parent: Container
    sourcepair: Container
    needsauth*: bool #TODO move to buffer?
    redirecturl: Option[URL]

  Pager* = ref object
    attrs: TermAttributes
    commandMode*: bool
    container*: Container
    config: Config
    loader: FileLoader
    regex: Option[Regex]
    reverseSearch: bool
    status*: seq[string]
    switched*: bool
    tty: File

proc setContainer*(pager: Pager, c: Container) =
  pager.container = c
  pager.switched = true

proc cursorLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLeft()
proc cursorDown(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorDown()
proc cursorUp(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorUp()
proc cursorRight(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorRight()
proc cursorLineBegin(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLineBegin()
proc cursorLineEnd(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLineEnd()
proc cursorNextWord(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorNextWord()
proc cursorPrevWord(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorPrevWord()
proc cursorNextLink(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorNextLink()
proc cursorPrevLink(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorPrevLink()
proc pageDown(pager: Pager) {.jsfunc.} = pager.container.buffer.pageDown()
proc pageUp(pager: Pager) {.jsfunc.} = pager.container.buffer.pageUp()
proc pageRight(pager: Pager) {.jsfunc.} = pager.container.buffer.pageRight()
proc pageLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.pageLeft()
proc halfPageDown(pager: Pager) {.jsfunc.} = pager.container.buffer.halfPageDown()
proc halfPageUp(pager: Pager) {.jsfunc.} = pager.container.buffer.halfPageUp()
proc cursorFirstLine(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorFirstLine()
proc cursorLastLine(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLastLine()
proc cursorTop(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorTop()
proc cursorMiddle(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorMiddle()
proc cursorBottom(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorBottom()
proc cursorLeftEdge(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorLeftEdge()
proc cursorVertMiddle(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorVertMiddle()
proc cursorRightEdge(pager: Pager) {.jsfunc.} = pager.container.buffer.cursorRightEdge()
proc centerLine(pager: Pager) {.jsfunc.} = pager.container.buffer.centerLine()
proc scrollDown(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollDown()
proc scrollUp(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollUp()
proc scrollLeft(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollLeft()
proc scrollRight(pager: Pager) {.jsfunc.} = pager.container.buffer.scrollRight()
proc lineInfo(pager: Pager) {.jsfunc.} = pager.container.buffer.lineInfo()
proc reshape(pager: Pager) {.jsfunc.} = pager.container.buffer.reshape = true
proc redraw(pager: Pager) {.jsfunc.} = pager.container.buffer.redraw = true

proc searchNext(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      discard pager.container.buffer.cursorNextMatch(pager.regex.get)
    else:
      discard pager.container.buffer.cursorPrevMatch(pager.regex.get)

proc searchPrev(pager: Pager) {.jsfunc.} =
  if pager.regex.issome:
    if not pager.reverseSearch:
      discard pager.container.buffer.cursorPrevMatch(pager.regex.get)
    else:
      discard pager.container.buffer.cursorNextMatch(pager.regex.get)

proc statusMode(pager: Pager) =
  print(HVP(pager.attrs.height + 1, 1))
  print(EL())

proc search(pager: Pager) {.jsfunc.} =
  pager.statusMode()
  var iput: string
  let status = readLine("/", iput, pager.attrs.width, config = pager.config, tty = pager.tty)
  if status:
    if iput.len != 0:
      pager.regex = compileSearchRegex(iput)
    pager.reverseSearch = false
    pager.searchNext()

proc searchBack(pager: Pager) {.jsfunc.} =
  pager.statusMode()
  var iput: string
  let status = readLine("?", iput, pager.attrs.width, config = pager.config, tty = pager.tty)
  if status:
    if iput.len != 0:
      pager.regex = compileSearchRegex(iput)
    pager.reverseSearch = true
    pager.searchNext()

proc displayPage*(pager: Pager) =
  let buffer = pager.container.buffer
  if pager.switched or buffer.refreshBuffer():
    pager.switched = false
    stdout.hideCursor()
    print(buffer.generateFullOutput())
    stdout.showCursor()

proc isearch(pager: Pager) {.jsfunc.} =
  pager.statusMode()
  var iput: string
  let cpos = pager.container.buffer.cpos
  var mark: Mark
  template del_mark() =
    if mark != nil:
      pager.container.buffer.removeMark(mark)

  let status = readLine("/", iput, pager.attrs.width, {}, false, pager.config, pager.tty, (proc(state: var LineState): bool =
    del_mark
    let regex = compileSearchRegex($state.news)
    pager.container.buffer.cpos = cpos
    if regex.issome:
      let match = pager.container.buffer.cursorNextMatch(regex.get)
      if match.success:
        mark = pager.container.buffer.addMark(match.x, match.y, match.str.width())
        pager.container.buffer.redraw = true
        pager.container.buffer.refreshBuffer(true)
        pager.displayPage()
        print(HVP(pager.attrs.height + 1, 2))
        print(SGR())
      else:
        del_mark
        pager.container.buffer.redraw = true
        pager.container.buffer.refreshBuffer(true)
        pager.displayPage()
        print(HVP(pager.attrs.height + 1, 2))
        print(SGR())
      return true
    false
  ))

  del_mark
  pager.container.buffer.redraw = true
  pager.container.buffer.refreshBuffer(true)
  if status:
    pager.regex = compileSearchRegex(iput)
  else:
    pager.container.buffer.cpos = cpos

proc isearchBack(pager: Pager) {.jsfunc.} =
  pager.statusMode()
  var iput: string
  let cpos = pager.container.buffer.cpos
  var mark: Mark
  template del_mark() =
    if mark != nil:
      pager.container.buffer.removeMark(mark)
  let status = readLine("?", iput, pager.container.buffer.width, {}, false, pager.config, pager.tty, (proc(state: var LineState): bool =
    del_mark
    let regex = compileSearchRegex($state.news)
    pager.container.buffer.cpos = cpos
    if regex.issome:
      let match = pager.container.buffer.cursorPrevMatch(regex.get)
      if match.success:
        mark = pager.container.buffer.addMark(match.x, match.y, match.str.width())
        pager.container.buffer.redraw = true
        pager.container.buffer.refreshBuffer(true)
        pager.displayPage()
        print(HVP(pager.attrs.height + 1, 2))
        print(SGR())
      else:
        del_mark
        pager.container.buffer.redraw = true
        pager.container.buffer.refreshBuffer(true)
        pager.displayPage()
        print(HVP(pager.attrs.height + 1, 2))
        print(SGR())
      return true
    false
  ))
  del_mark
  pager.container.buffer.redraw = true
  if status:
    pager.regex = compileSearchRegex(iput)
  else:
    pager.container.buffer.cpos = cpos

proc newContainer(buffer: Buffer, parent: Container): Container =
  new(result)
  result.buffer = buffer
  result.parent = parent

proc newPager*(config: Config, attrs: TermAttributes, loader: FileLoader, tty: File): Pager =
  new(result)
  result.config = config
  result.attrs = attrs
  result.loader = loader
  result.tty = tty

proc addBuffer*(pager: Pager, buffer: Buffer) =
  var ncontainer = newContainer(buffer, pager.container)
  if pager.container != nil:
    pager.container.children.add(ncontainer)
  pager.setContainer(ncontainer)

proc dupeBuffer*(pager: Pager, location = none(URL)) {.jsfunc.} =
  var clone: Buffer
  clone = pager.container.buffer.dupeBuffer(location)
  pager.addBuffer(clone)

# The prevBuffer and nextBuffer procedures emulate w3m's PREV and NEXT
# commands by traversing the container tree in a depth-first order.
proc prevBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  for i in 0..pager.container.parent.children.high:
    let child = pager.container.parent.children[i]
    if child == pager.container:
      if i > 0:
        pager.setContainer(pager.container.parent.children[i - 1])
      else:
        pager.setContainer(pager.container.parent)
      return true
  assert false, "Container not a child of its parent"

proc nextBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.children.len > 0:
    pager.setContainer(pager.container.children[0])
    return true
  if pager.container.parent == nil:
    return false
  for i in countdown(pager.container.parent.children.high, 0):
    let child = pager.container.parent.children[i]
    if child == pager.container:
      if i < pager.container.parent.children.high:
        pager.setContainer(pager.container.parent.children[i + 1])
        return true
      return false
  assert false, "Container not a child of its parent"

#TODO we should have a separate status message stack for all buffers AND the
# pager.
proc setStatusMessage(pager: Pager, msg: string) =
  if pager.container != nil:
    pager.container.buffer.setStatusMessage(msg)
  else:
    pager.status.add(msg)

proc discardBuffer*(pager: Pager) {.jsfunc.} =
  if pager.container.parent == nil and pager.container.children.len == 0:
    pager.setStatusMessage("Cannot discard last buffer!")
  else:
    if pager.container.parent != nil:
      let parent = pager.container.parent
      let n = parent.children.find(pager.container)
      assert n != -1, "Container not a child of its parent"
      for i in countdown(pager.container.children.high, 0):
        let child = pager.container.children[i]
        child.parent = pager.container.parent
        parent.children.insert(child, n + 1)
      parent.children.delete(n)
      pager.setContainer(parent)
    else:
      pager.setContainer(pager.container.children[0])
      pager.container.parent = nil

proc drawBuffer*(pager: Pager) {.jsfunc.} =
  pager.container.buffer.drawBuffer() #TODO move this to pager

proc toggleSource*(pager: Pager) {.jsfunc.} =
  if pager.container.sourcepair != nil:
    pager.setContainer(pager.container.sourcepair)
  else:
    let buffer = newBuffer(pager.config, pager.loader, pager.tty)
    buffer.source = pager.container.buffer.source
    buffer.streamclosed = true
    buffer.location = pager.container.buffer.location
    buffer.ispipe = pager.container.buffer.ispipe
    if pager.container.buffer.contenttype == "text/plain":
      buffer.contenttype = "text/html"
    else:
      buffer.contenttype = "text/plain"
    buffer.setupBuffer()
    let container = newContainer(buffer, pager.container)
    container.sourcepair = pager.container
    pager.container.sourcepair = container
    pager.container.children.add(container)

# Load request in a new buffer.
proc gotoURL*(pager: Pager, request: Request, prevurl = none(URL), force = false, ctype = "", replace = false): bool {.discardable.} =
  if force or prevurl.isnone or not prevurl.get.equals(request.url, true) or
      request.url.hash == "" or request.httpmethod != HTTP_GET:
    # Basically, we want to reload the page *only* when
    # a) force == true
    # b) or the new URL isn't just the old URL + an anchor
    # I think this makes navigation pretty natural, or at least very close to
    # what other browsers do. Still, it would be nice if we got some visual
    # feedback on what is actually going to happen when typing a URL; TODO.
    let response = pager.loader.doRequest(request)
    if response.body != nil:
      let buffer = newBuffer(pager.config, pager.loader, pager.tty)
      buffer.contenttype = if ctype != "": ctype else: response.contenttype
      buffer.istream = response.body
      buffer.location = request.url
      buffer.setupBuffer()
      if replace:
        pager.discardBuffer()
      pager.addBuffer(buffer)
      pager.container.needsauth = response.status == 401 # Unauthorized
      pager.container.redirecturl = response.redirect
    else:
      pager.setStatusMessage("Couldn't load " & $request.url & " (" & $response.res & ")")
      return false
  else:
    if pager.container.buffer.hasAnchor(request.url.anchor):
      pager.dupeBuffer(request.url.some)
    else:
      pager.setStatusMessage("Couldn't find anchor " & request.url.anchor)
      return false
  return true

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
# (TODO: make this optional)
proc loadURL*(pager: Pager, url: string, force = false, ctype = "") =
  let firstparse = parseURL(url)
  if firstparse.issome:
    let prev = if pager.container != nil:
      some(pager.container.buffer.location)
    else:
      none(URL)
    pager.gotoURL(newRequest(firstparse.get), prev, force, ctype)
    return
  let cdir = parseURL("file://" & getCurrentDir() & DirSep)
  let newurl = parseURL(url, cdir)
  if newurl.isSome:
    # attempt to load local file
    if pager.gotoURL(newRequest(newurl.get), force = force, ctype = ctype):
      return
  block:
    let purl = percentEncode(url, LocalPathPercentEncodeSet)
    if purl != url:
      let newurl = parseURL(purl, cdir)
      if newurl.isSome:
        if pager.gotoURL(newRequest(newurl.get), force = force, ctype = ctype):
          pager.status.setLen(0)
          return
  block:
    let newurl = parseURL("https://" & url)
    if newurl.isSome:
      # attempt to load remote page
      if pager.gotoURL(newRequest(newurl.get), force = force, ctype = ctype):
        pager.status.setLen(0)
        return
  pager.setStatusMessage("Invalid URL " & url)

# Open a URL prompt and visit the specified URL.
proc changeLocation(pager: Pager) {.jsfunc.} =
  var url = pager.container.buffer.location.serialize()
  pager.statusMode()
  let status = readLine("URL: ", url, pager.attrs.width, config = pager.config, tty = pager.tty)
  if status:
    pager.loadURL(url)

# Reload the page in a new buffer, then kill the previous buffer.
proc reloadPage(pager: Pager) {.jsfunc.} =
  pager.gotoURL(newRequest(pager.container.buffer.location), none(URL), true, pager.container.buffer.contenttype, true)

proc click(pager: Pager) {.jsfunc.} =
  #TODO this conflicts with the planned event loop
  let req = pager.container.buffer.click()
  if req.issome:
    pager.gotoURL(req.get, pager.container.buffer.location.some)

proc followRedirect*(pager: Pager)

proc checkAuth*(pager: Pager) =
  if pager.container != nil and pager.container.needsauth:
    pager.container.buffer.refreshBuffer()
    pager.statusMode()
    var username = ""
    let ustatus = readLine("Username: ", username, pager.attrs.width, config = pager.config, tty = pager.tty)
    if not ustatus:
      pager.container.needsauth = false
      return
    pager.statusMode()
    var password = ""
    let pstatus = readLine("Password: ", password, pager.attrs.width, hide = true, config = pager.config, tty = pager.tty)
    if not pstatus:
      pager.container.needsauth = false
      return
    var url = pager.container.buffer.location
    url.username = username
    url.password = password
    pager.gotoURL(newRequest(url), prevurl = some(pager.container.buffer.location), replace = true)
    pager.followRedirect()

proc followRedirect*(pager: Pager) =
  while pager.container != nil and pager.container.redirecturl.issome:
    pager.statusMode()
    print("Redirecting to ", $pager.container.redirecturl.get)
    stdout.flushFile()
    pager.container.buffer.refreshBuffer(true)
    let redirecturl = pager.container.redirecturl.get
    pager.container.redirecturl = none(URL)
    pager.gotoURL(newRequest(redirecturl), prevurl = some(pager.container.buffer.location), replace = true)
    if pager.container.needsauth:
      pager.checkAuth()

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
