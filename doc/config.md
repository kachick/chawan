# Configuration

Chawan supports custom keybindings and user stylesheets, defined in a toml
configuration file.

Chawan will look for a config file in the ~/.config/chawan/ directory called
`config.toml`. See the default configuration in the res/ folder for the default
configuration.

A list of configurable options follows.

## External

External options must be placed in a section called `[external]`.

Following is a list of external options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>tmpdir</td>
<td>path</td>
<td>Directory used to save temporary files.</td>
</tr>

<tr>
<td>editor</td>
<td>shell command</td>
<td>External editor command. %s is substituted for the file name, %d for
the line number.</td>
</tr>

</table>

## Display

Display options must be placed in a section called `[display]`.

Following is a list of display options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>color-mode</td>
<td>"monochrome"/"ansi"/"8bit"/"24bit"/"auto"</td>
<td>Set the color mode. "auto" for automatic detection, "monochrome"</td>
for black on white, "ansi" for ansi colors, "24bit" for true colors. "8bit"
is currently unimplemented (and fallbacks to ansi).</td>
</tr>

<tr>
<td>format-mode</td>
<td>"auto"/["bold", "italic", "underline", "reverse", "strike", "overline",
"blink"]</td>
<td>Specifies output formatting modes. Accepts the string "auto" or an array
of specific attributes. An empty array (`[]`) disables formatting
completely.</td>
</tr>

<tr>
<td>no-format-mode
<td>["bold", "italic", "underline", "reverse", "strike", "overline", "blink"]
<td>Disable specified formatting modes.</td>
</tr>

<tr>
<td>emulate-overline</td>
<td>boolean</td>
<td>When set to true and the overline formatting attribute is not enabled,
overlines are substituted by underlines on the previous line.</td>
</tr>

<tr>
<td>alt-screen</td>
<td>"auto"/boolean</td>
<td>Enable/disable the alternative screen.</td>
</tr>

<tr>
<td>highlight-color</td>
<td>color</td>
<td>Set the highlight color. Both hex values and CSS color names are
accepted.</td>
</tr>

<tr>
<td>double-width-ambiguous</td>
<td>boolean</td>
<td>Assume the terminal displays characters in the East Asian Ambiguous
category as double-width characters. Useful when e.g. ○ occupies two
cells.</td>
</tr>

<tr>
<td>minimum-contrast</td>
<td>number</td>
<td>Specify the minimum number of euclidian distance of the background and
foreground colors on the RGB plane. -1 disables this function (i.e. allows
black letters on black background, etc).</td>
</tr>

<tr>
<td>force-clear</td>
<td>boolean</td>
<td>Force the screen to be completely cleared every time it is redrawn.</td>
</tr>

</table>

## Siteconf

Configuration options can be specified for individual sites. Each entry must
be in the table array `[[siteconf]]`.

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>url</td>
<td>regex</td>
<td>Regular expression used to match the URL.</td>
</tr>

<tr>
<td>substitute_url</td>
<td>JS function</td>
<td>A JavaScript function returning the substituted url.</td>
</tr>

</table>

## Stylesheets

User stylesheets must be placed in a section called `[css]`.

There are two ways to import user stylesheets:

1. Include a user stylesheet using the format `include = 'path-to-user.css'`.
   To include multiple stylesheets, use `include = ['first-stylesheet.css,
   second-stylesheet.css']`.  
   Relative paths are interpreted relative to the config directory.

2. Place your stylesheet directly in your configuration file using `inline =
   """your-style"""`.  

## Keybindings

Keybindings must be placed in these sections:

* for pager interaction: `[page]`
* for line editing: `[line]`

Keybindings are configured using the syntax

	'<keybinding>' = '<action>'

Where `<keybinding>` is a combination of unicode characters with or without
modifiers. Modifiers are the prefixes `C-` and `M-`, which add control or
escape to the keybinding respectively (essentially making `M-` the same as
`C-[`). Modifiers can be escaped with the `\` sign.

```Examples:
'C-M-j' = 'pager.changeLocation()' # change URL when Control, Escape and j are pressed
'gg' = 'pager.cursorFirstLine()' # go to the first line of the page when g is pressed twice
```
An action is a JavaScript function called by chawan every time the keybinding
is typed in. A list of built-in pager functions can be found below.

### Pager actions

<table>
<tr><th>**Name**<th>**Function**
<tr><td>`pager.quit()`<td>Exit the browser
<tr><td>`pager.cursorUp()`<td>Move the cursor to the previous line
<tr><td>`pager.cursorDown()`<td>Move cursor to the next line
<tr><td>`pager.cursorLeft()`<td>Move cursor to the previous cell
<tr><td>`pager.cursorRight()`<td>Move cursor to the next cell
<tr><td>`pager.cursorLineBegin()`<td>Move cursor to the first cell of the line
<tr><td>`pager.cursorLineEnd()`<td>Move cursor to the last cell of the line
<tr><td>`pager.cursorNextWord()`<td>Move cursor to the beginning of the next word
<tr><td>`pager.cursorPrevWord()`<td>Move cursor to the end of the previous word
<tr><td>`pager.cursorNextLink()`<td>Move cursor to the beginning of the next clickable element
<tr><td>`pager.cursorPrevLink()`<td>Move cursor to the beginning of the previous clickable element
<tr><td>`pager.pageDown()`<td>Move screen down by one page
<tr><td>`pager.pageUp()`<td>Move screen up by one page
<tr><td>`pager.pageLeft()`<td>Move screen to the left by one page
<tr><td>`pager.pageRight()`<td>Move screen to the right by one page
<tr><td>`pager.halfPageDown()`<td>Move screen down by half a page
<tr><td>`pager.halfPageUp()`<td>Move screen up by half a page
<tr><td>`pager.scrollDown()`<td>Move screen down by one line
<tr><td>`pager.scrollUp()`<td>Move screen up by one line
<tr><td>`pager.scrollLeft()`<td>Move screen to the left by one line
<tr><td>`pager.scrollRight()`<td>Move screen to the right by one line
<tr><td>`pager.click()`<td>Click element currently under cursor
<tr><td>`pager.changeLocation()`<td>Go to URL
<tr><td>`pager.dupeBuffer()`<td>Duplicate the current buffer
<tr><td>`pager.reload()`<td>Reload page
<tr><td>`pager.reshape()`<td>Reshape buffer (=render page anew)
<tr><td>`pager.redraw()`<td>Redraw buffer (=redraw screen)
<tr><td>`pager.toggleSource()`<td>Source view
<tr><td>`pager.cursorFirstLine()`<td>Move cursor to the first line of the buffer
<tr><td>`pager.cursorLastLine()`<td>Move cursor to the last line of the buffer
<tr><td>`pager.cursorTop()`<td>Move cursor to the first line of the page
<tr><td>`pager.cursorMiddle()`<td>Move cursor to the middle of the page
<tr><td>`pager.cursorBottom()`<td>Move cursor to the last line of the page
<tr><td>`pager.centerLine()`<td>Center screen around line
<tr><td>`pager.lineInfo()`<td>Display information about line
<tr><td>`pager.searchForward()`<td>Search for a string in the current buffer
<tr><td>`pager.searchBackward()`<td>Search for a string, backwards
<tr><td>`pager.isearchForward()`<td>Search for a string and highlight the first result
<tr><td>`pager.isearchBackward()`<td>Search and highlight the first result, backwards
<tr><td>`pager.searchPrev()`<td>Jump to the next search result
<tr><td>`pager.searchNext()`<td>Jump to the previous search result
<tr><td>`pager.peek()`<td>Display an alert of the current URL
<tr><td>`pager.peekCursor()`<td>Display an alert of the URL under the cursor
</table>

### Line-editing actions

<table>
<tr><th>**Name**<th>**Function**
<tr><td>`line.submit()`<td>Submit line
<tr><td>`line.cancel()`<td>Cancel operation
<tr><td>`line.backspace()`<td>Delete character before cursor
<tr><td>`line.delete()`<td>Delete character after cursor
<tr><td>`line.clear()`<td>Clear text before cursor
<tr><td>`line.kill()`<td>Clear text after cursor
<tr><td>`line.clearWord(bounds)`<td>Delete word before cursor[^a]
<tr><td>`line.killWord(bounds)`<td>Delete word after cursor[^a]
<tr><td>`line.backward()`<td>Move cursor back by one character
<tr><td>`line.forward()`<td>Move cursor forward by one character
<tr><td>`line.prevWord(bounds)`<td>Move cursor to the previous word by one character[^a]
<tr><td>`line.nextWord(bounds)`<td>Move cursor to the previous word by one character[^a]
<tr><td>`line.begin()`<td>Move cursor to the previous word by one character
<tr><td>`line.end()`<td>Move cursor to the previous word by one character
<tr><td>`line.escape()`<td>Ignore keybindings for next character
<tr><td>`line.prevHist()`<td>Jump to the previous history entry
<tr><td>`line.nextHist()`<td>Jump to the next history entry
</table>

Some entries have an optional `bounds` parameter. If passed, this must be a
JavaScript function with one parameter (the current unicode character), and
must return true if the passed character should count as a word boundary.

```Examples:
# Control+A moves the cursor to the beginning of the line.
'C-a' = 'line.begin()'

# Escape+D deletes everything after the cursor until it reaches a word-breaking
# character.
'M-d' = 'line.killWord()'

# Control+W deletes everything before the cursor until it reaches a space. 
'C-w' = 'line.clearWord(x => x == " ")'
```
