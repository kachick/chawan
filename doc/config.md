# Configuration

Chawan supports custom keybindings and user stylesheets, defined in a toml
configuration file.

Chawan will look for a config file in the ~/.config/chawan/ directory called
`config.toml`. See the default configuration in the res/ folder for the default
configuration.

A list of configurable options follows.

## General

General options must be placed in a section called `[general]`.

Following is a list of general options:

<table>
<tr><th>**Name**<th>**Value**<th>**Function**
<tr><td>double-width-ambiguous<td>boolean
<td>Assume the terminal displays characters in the East Asian Ambiguous
category as double-width characters. If you don't know what this means, you
probably won't need to enable it.
</table>

## Display

Display options must be placed in a section called `[display]`.

Following is a list of display options:

<table>
<tr><th>**Name**<th>**Value**<th>**Function**
<tr><td>mark-color<td>color<td>Set the marker's color. Valid options are
"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
"terminal".
</table>

## Stylesheets

User stylesheets must be placed in a section called `[css]`.

There are two ways to import user stylesheets:

1. Include a user stylesheet using the format `include = 'path-to-user.css'`.
   To include multiple stylesheets, use `include = ['first-stylesheet.css,
   second-stylesheet.css']`.  
   Relative paths are interpreted as relative to the config directory.

2. Place your stylesheet directly in your configuration file using `inline =
   """your-style"""`.  

## Keybindings

Keybindings must be placed in these sections:

* for page browsing: `[page]`
* for line editing: `[line]`

Keybindings are configured using the syntax

	'<keybinding>' = '<action>'

Where `<keybinding>` is a combination of unicode characters with or without
modifiers. Modifiers are the prefixes `C-` and `M-`, which add control or
escape to the keybinding respectively (essentially making `M-` the same as
`C-[`). Modifiers can be escaped with the `\` sign.

(Note: it is highly recommended to use single quotes here; escaping can get
quite ugly with double quotes.)

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
