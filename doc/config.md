# Configuration

Currently keybindings and a user stylesheet can be configured. The
configuration format for twt is toml.

twt will look for a config file in the ~/.config/twt/ directory called
`config.toml`. For an example see the default configuration in the res/ folder.

A list of configurable options follows.

## General

General options are to be placed in a section called [general].

Following are general options:

<table>
<tr><th>**Name**<th>**Value**<th>**Function**
<tr><td>double-width-ambiguous<td>boolean<td>assume the terminal displays characters in the East Asian Ambiguous category as double width
</table>

## Stylesheets

User stylesheets are to be placed in a section called [css].

There are two ways to import user stylesheets:

1. Include a user stylesheet using the format `include = 'path-to-user.css'`.
   To include multiple stylesheets, use `include = ['first-stylesheet.css,
   second-stylesheet.css']`.  
   Relative paths are interpreted as relative to the config directory.

2. Place your stylesheet directly in your configuration file using `inline =
   """your-style"""`.  

## Keybindings

Keybindings are to be placed in these sections:

* for page browsing: [page]
* for line editing: [line]

Keybindings are configured using the syntax

	'<keybinding>' = '<action>'

Where `<keybinding>` is a combination of unicode characters with or without
modifiers. Modifiers are the prefixes `C-` and `M-`, which add control or
escape to the keybinding respectively (essentially making `M-` the same as
`C-[`). Modifiers can be escaped with the `\` sign.

(Note: it is **highly recommended** to use single quotes here; escaping can get
quite ugly with double quotes.)

```Example:
'C-M-j' = 'CHANGE_LOCATION' # change URL when Control, Escape and j are pressed
'gg' = 'CURSOR_FIRST_LINE' # go to the first line of the page when g is pressed twice
```

`<action>` is a valid normal or line-edit mode action. A detailed
description of these follows.

### Normal mode actions

<table>
<tr><th>**Name**<th>**Function**
<tr><td>`NULL`<td>Do nothing (used for disabling default keybindings)
<tr><td>`QUIT`<td>Exit the browser
<tr><td>`CURSOR_UP`<td>Move the cursor to the previous line
<tr><td>`CURSOR_DOWN`<td>Move cursor to the next line
<tr><td>`CURSOR_LEFT`<td>Move cursor to the previous cell
<tr><td>`CURSOR_RIGHT`<td>Move cursor to the next cell
<tr><td>`CURSOR_LEFT`<td>Move cursor to the previous cell
<tr><td>`CURSOR_LINEBEGIN`<td>Move cursor to the first cell of the line
<tr><td>`CURSOR_LINEEND`<td>Move cursor to the last cell of the line
<tr><td>`CURSOR_NEXT_WORD`<td>Move cursor to the beginning of the next word
<tr><td>`CURSOR_PREV_WORD`<td>Move cursor to the end of the previous word
<tr><td>`CURSOR_NEXT_LINK`<td>Move cursor to the beginning of the next clickable element
<tr><td>`CURSOR_PREV_LINK`<td>Move cursor to the beginning of the previous clickable element
<tr><td>`PAGE_DOWN`<td>Move screen down by one page
<tr><td>`PAGE_UP`<td>Move screen up by one page
<tr><td>`PAGE_LEFT`<td>Move screen to the left by one page
<tr><td>`PAGE_RIGHT`<td>Move screen to the right by one page
<tr><td>`HALF_PAGE_DOWN`<td>Move screen down by half a page
<tr><td>`HALF_PAGE_UP`<td>Move screen up by half a page
<tr><td>`SCROLL_DOWN`<td>Move screen down by one line
<tr><td>`SCROLL_UP`<td>Move screen up by one line
<tr><td>`SCROLL_LEFT`<td>Move screen to the left by one line
<tr><td>`SCROLL_RIGHT`<td>Move screen to the right by one line
<tr><td>`CLICK`<td>Click element currently under cursor
<tr><td>`CHANGE_LOCATION`<td>Go to URL
<tr><td>`RELOAD`<td>Reload page
<tr><td>`RESHAPE`<td>Reshape buffer (=render page anew)
<tr><td>`REDRAW`<td>Redraw buffer (=redraw screen)
<tr><td>`TOGGLE_SOURCE`<td>Source view
<tr><td>`CURSOR_FIRST_LINE`<td>Move cursor to the first line of the buffer
<tr><td>`CURSOR_LAST_LINE`<td>Move cursor to the last line of the buffer
<tr><td>`CURSOR_TOP`<td>Move cursor to the first line of the page
<tr><td>`CURSOR_MIDDLE`<td>Move cursor to the middle of the page
<tr><td>`CURSOR_BOTTOM`<td>Move cursor to the last line of the page
<tr><td>`CENTER_LINE`<td>Center screen around line
<tr><td>`LINE_INFO`<td>Display information about line
</table>

### Line-editing actions

<table>
<tr><th>**Name**<th>**Function**
<tr><td>`NULL`<td>Do nothing
<tr><td>`SUBMIT`<td>Submit line
<tr><td>`CANCEL`<td>Cancel operation
<tr><td>`BACKSPACE`<td>Delete character before cursor
<tr><td>`DELETE`<td>Delete character after cursor
<tr><td>`CLEAR`<td>Clear text before cursor
<tr><td>`KILL`<td>Clear text after cursor
<tr><td>`KILL_WORD`<td>Delete previous word
<tr><td>`BACK`<td>Move cursor back by one character
<tr><td>`FORWARD`<td>Move cursor forward by one character
<tr><td>`PREV_WORD`<td>Move cursor to the previous word by one character
<tr><td>`NEXT_WORD`<td>Move cursor to the previous word by one character
<tr><td>`BEGIN`<td>Move cursor to the previous word by one character
<tr><td>`END`<td>Move cursor to the previous word by one character
<tr><td>`ESC`<td>Ignore keybindings for next character
</table>
