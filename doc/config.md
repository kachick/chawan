<!-- % cha-config(5) | Configuration of Chawan -->

# Configuration of Chawan

Chawan supports configuration of various options like keybindings, user
stylesheets, site preferences, etc. The configuration format is very similar
to toml, with the following exceptions:

* Inline tables may span across multiple lines.
* Table arrays can be cleared by setting a variable by the same to the
  empty array. This allows users to disable default table array rules.

Example:
```
omnirule = [] # note: this must be placed at the beginning of the file.

[[omnirule]] # this is legal. all default omni-rules are now disabled.
```

Chawan will look for a config file in the $XDG_CONFIG_HOME/chawan/ directory
called `config.toml`. (Chawan defaults to ~/.config if the XDG_CONFIG_HOME
environment variable is not set.) See the default configuration file in the
res/ folder, and bonus configuration files in the bonus/ folder for further
examples.

<!-- TOCSTART -->
**Table of contents**

* [Start](#start)
* [Search](#search)
* [Encoding](#encoding)
* [External](#external)
* [Network](#network)
* [Display](#display)
* [Omnirule](#omnirule)
* [Siteconf](#siteconf)
* [Stylesheets](#stylesheets)
* [Keybindings](#keybindings)
   * [Pager actions](#pager-actions)
   * [Line-editing actions](#line-editing-actions)
* [Appendix](#appendix)
   * [Regex handling](#regex-handling)

<!-- TOCEND -->
## Start

Start-up options are to be placed in the `[start]` section.

Following is a list of start-up options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>visual-home</td>
<td>url</td>
<td>Page opened when Chawan is called with the -V option (and no other
pages are passed as arguments.)</td>
</tr>

<tr>
<td>startup-script</td>
<td>JavaScript code</td>
<td>Script Chawan runs on start-up. Pages will not be loaded until this
function exits. (Note however that asynchronous functions like setTimeout
do not block loading.)</td>
</tr>

<tr>
<td>headless</td>
<td>boolean</td>
<td>Whether Chawan should always start in headless mode. Automatically
enabled when Chawan is called with -r.</td>
</tr>

</table>

## Search

Search options are to be placed in the `[search]` section.

Following is a list of search options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>wrap</td>
<td>boolean</td>
<td>When set to true, searchNext/searchPrev wraps around the document.</td>
</tr>

</table>

## Encoding

Encoding options are to be placed in the `[encoding]` section.

Following is a list of encoding options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>document-charset</td>
<td>string/array</td>
<td>List of character sets for loading documents.<br>
All listed character sets are enumerated until the document has been decoded
without errors. In HTML, meta tags and the BOM may override this with a
different charset, so long as the specified charset can decode the document
correctly.
</td>
</tr>

<tr>
<td>display-charset</td>
<td>string</td>
<td>Character set for keyboard input and displaying documents.<br>
Used in dump mode as well.<br>
(This means that e.g. `cha -I EUC-JP -O UTF-8 a > b` is equivalent to `iconv
-f EUC-JP -t UTF-8.)</td>
</tr>

</table>

## External

External options are to be placed in the `[external]` section.

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

<tr>
<td>mailcap</td>
<td>array of paths</td>
<td>Search path for [mailcap](mailcap.md) files.</td>
</tr>

<tr>
<td>mime-types</td>
<td>array of paths</td>
<td>Search path for [mime.types](mime.types.md) files.</td>
</tr>

</table>

## Input

Input options are to be placed in the `[input]` section.

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>vi-numeric-prefix</td>
<td>boolean</td>
<td>Whether vi-style numeric prefixes to commands should be accepted.<br>
When set to true, commands that return a function will be called with the
numeric prefix as their first argument.<br>
Note: this only applies for keybindings defined in [page].</td>
</tr>

</table>

Examples:
```
[input]
vi-numeric-prefix = true

[page]
# Here, the arrow function will be called with the vi numbered prefix if
# one was input, and with no argument otherwise.
# The numeric prefix can never be zero, so it is safe to test for undefined
# using the ternary operator.
G = 'n => n ? pager.gotoLine(n) : pager.cursorLastLine()'
```

## Network

Network options are to be placed in the `[network]` section.

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>max-redirect</td>
<td>number</td>
<td>Maximum number of redirections to follow.</td>
</tr>

<tr>
<td>prepend-https</td>
<td>boolean</td>
<td>Whether or not Chawan should attempt loading "raw" URLs without a scheme as
https (e.g. wikipedia.org as https://wikipedia.org.)</td>
</tr>

<tr>
<td>proxy</td>
<td>URL</td>
<td>Specify a proxy for all network requests Chawan makes. All proxies
supported by cURL may be used. Can be overridden by siteconf.</td>
</tr>

<tr>
<td>default-headers</td>
<td>Table</td>
<td>Specify a list of default headers for all HTTP(S) network requests.</td>

</table>

## Display

Display options are to be placed in the `[display]` section.

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
<td>Set the color mode. "auto" for automatic detection, "monochrome"
for black on white, "ansi" for ansi colors, "24bit" for true colors. "8bit"
is currently unimplemented (and falls back to ansi).</td>
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
<td>no-format-mode</td>
<td>["bold", "italic", "underline", "reverse", "strike", "overline", "blink"]</td>
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
<td>Specify the minimum difference between the luminance (Y) of the background
and the foreground. -1 disables this function (i.e. allows black letters on
black background, etc).</td>
</tr>

<tr>
<td>force-clear</td>
<td>boolean</td>
<td>Force the screen to be completely cleared every time it is redrawn.</td>
</tr>

<tr>
<td>set-title</td>
<td>boolean</td>
<td>Set the terminal emulator's window title to that of the current page.</td>
</tr>

<tr>
<td>default-background-color</td>
<td>color</td>
<td>Sets the assumed background color of the terminal.</td>
</tr>

<tr>
<td>default-foreground-color</td>
<td>color</td>
<td>Sets the assumed foreground color of the terminal.</td>
</tr>

</table>

## Omnirule

The omni-bar (by default opened with C-l) can be used to perform searches using
omni-rules. These are to be placed in the table array `[[omnirule]]`.

Examples:
```
# Search using DuckDuckGo Lite. (Bound to C-k by default.)
[[omnirule]]
match = '^ddg:'
substitute-url = '(x) => "https://lite.duckduckgo.com/lite/?kp=-1&kd=-1&q=" + encodeURIComponent(x.split(":").slice(1).join(":"))'

# Search using Wikipedia, Firefox-style.
[[omnirule]]
match = '^@wikipedia'
substitute-url = '(x) => "https://en.wikipedia.org/wiki/Special:Search?search=" + encodeURIComponent(x.replace(/@wikipedia/, ""))'
```

Omnirule options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>match</td>
<td>regex</td>
<td>Regular expression used to match the input string. Note that websites
passed as arguments are matched as well.<br>
Note: regexes are handled according to the [regex handling](#regex-handling)
rules.</td>
</tr>

<tr>
<td>substitute-url</td>
<td>JavaScript function</td>
<td>A JavaScript function Chawan will pass the input string to. If a new string is
returned, it will be parsed instead of the old one.</td>
</tr>

</table>

## Siteconf

Configuration options can be specified for individual sites. Entries are to be
placed in the table array `[[siteconf]]`.

Examples:
```
# Enable cookies on the orange website for log-in.
[[siteconf]]
url = 'https://news\.ycombinator\.com/.*'
cookie = true

# Redirect npr.org to text.npr.org.
[[siteconf]]
host = '(www\.)?npr\.org'
rewrite-url = '''
(x) => {
	x.host = "text.npr.org";
	x.pathname = x.pathname.replace(/(.*)\/.*/, "$1").replace(/.*\//, "");
	/* No need to return; URL objects are passed by reference. */
}
'''

# Allow cookie sharing on *sr.ht domains.
[[siteconf]]
host = '.*sr\.ht'
cookie = true
share-cookie-jar = 'sr.ht'
third-party-cookie = '.*\.sr.ht'
```

Siteconf options:

<table>

<tr>
<th>**Name**</th>
<th>**Value**</th>
<th>**Function**</th>
</tr>

<tr>
<td>url</td>
<td>regex</td>
<td>Regular expression used to match the URL. Either this or the `host` option
must be specified.<br>
Note: regexes are handled according to the [regex handling](#regex-handling)
rules.</td>
</tr>

<tr>
<td>host</td>
<td>regex</td>
<td>Regular expression used to match the host part of the URL (i.e. domain
name/ip address.) Either this or the `url` option must be specified.<br>
Note: regexes are handled according to the [regex handling](#regex-handling)
rules.</td>
</tr>

<tr>
<td>rewrite-url</td>
<td>JavaScript function</td>
<td>A JavaScript function Chawan will pass the URL to. If a new URL is
returned, it will replace the old one.</td>
</tr>

<tr>
<td>cookie</td>
<td>boolean</td>
<td>Whether loading cookies should be allowed for this URL. By default, this is
false for all websites.</td>
</tr>

<tr>
<td>third-party-cookie</td>
<td>regex/array of regexes</td>
<td>Domains for which third-party cookies are allowed on this domain. Note:
this only works for buffers which share the same cookie jar.<br>
Note: regexes are handled according to the [regex handling](#regex-handling)
rules.</td>
</tr>

<tr>
<td>share-cookie-jar</td>
<td>host</td>
<td>Cookie jar to use for this domain. Useful for e.g. sharing cookies with
subdomains.</td>
</tr>

<tr>
<td>referer-from</td>
<td>boolean</td>
<td>Whether or not we should send a Referer header when opening requests
originating from this domain. Simplified example: if you click a link on a.com
that refers to b.com, and referer-from is true, b.com is sent "a.com" as the
Referer header.  
Defaults to false.
</td>
</tr>

<tr>
<td>scripting</td>
<td>boolean</td>
<td>Enable/disable JavaScript execution on this site.</td>
</tr>

<tr>
<td>document-charset</td>
<td>boolean</td>
<td>Specify the default encoding for this site. Overrides document-charset
in [encoding].</td>
</tr>

<tr>
<td>stylesheet</td>
<td>CSS stylesheet</td>
<td>Specify an additional user-stylesheet for this site.  
Note: other user-stylesheets (specified under [css] or additional matching
siteconfs) are not overridden. (In other words, they will be concatenated
with this stylesheet to get the final user stylesheet.)</td>
</tr>

<tr>
<td>proxy</td>
<td>URL</td>
<td>Specify a proxy for network requests fetching contents of this buffer.</td>
</tr>


</table>

## Stylesheets

User stylesheets are to be placed in the `[css]` section.

There are two ways to import user stylesheets:

1. Include a user stylesheet using the format `include = 'path-to-user.css'`.
   To include multiple stylesheets, use `include = ['first-stylesheet.css,
   second-stylesheet.css']`.  
   Relative paths are interpreted relative to the config directory.

2. Place your stylesheet directly in your configuration file using `inline =
   """your-style"""`.  

## Keybindings

Keybindings are to be placed in these sections:

* for pager interaction: `[page]`
* for line editing: `[line]`

Keybindings are configured using the syntax

	'<keybinding>' = '<action>'

Where `<keybinding>` is a combination of unicode characters with or without
modifiers. Modifiers are the prefixes `C-` and `M-`, which add control or
escape to the keybinding respectively (essentially making `M-` the same as
`C-[`). Modifiers can be escaped with the `\` sign.

```
Examples:
'C-M-j' = 'pager.load()' # change URL when Control, Escape and j are pressed
'gg' = 'pager.cursorFirstLine()' # go to the first line of the page when g is pressed twice
```

An action is a JavaScript expression called by Chawan every time the keybinding
is typed in. If an action returns a function, Chawan will also call the
returned function automatically. So this works too:

```
U = '() => pager.load()' # works
```

Note however, that JavaScript functions must be called with an appropriate
this value. Unfortunately, this also means that the following does not work:

```
q = 'pager.load' # broken!!!
```

A list of built-in pager functions can be found below.

### Browser actions

<table>

<tr>
<th>**Name**</th>
<th>**Function**</th>
</tr>

<tr>
<td>`quit()`</td>
<td>Exit the browser.</td>
</tr>

<tr>
<td>`suspend()`</td>
<td>Temporarily suspend the browser (by delivering the client process a
SIGSTOP signal.)<br>
Note: this does not suspend buffer processes.</td>
</tr>

</table>

### Pager actions

<table>

<tr>
<th>**Name**</th>
<th>**Function**</th>
</tr>

<tr>
<td>`pager.cursorUp(n = 1)`</td>
<td>Move the cursor upwards by n lines, or if n is unspecified, by 1.</td>
</tr>
<tr>
<td>`pager.cursorDown(n = 1)`</td>
<td>Move the cursor downwards by n lines, or if n is unspecified, by 1.</td>
</tr>

<tr>
<td>`pager.cursorLeft(n = 1)`</td>
<td>Move the cursor to the left by n cells, or if n is unspecified, by 1.</td>
</tr>

<tr>
<td>`pager.cursorRight(n = 1)`</td>
<td>Move the cursor to the right by n cells, or if n is unspecified, by 1.</td>
</tr>

<tr>
<td>`pager.cursorLineBegin()`</td>
<td>Move the cursor to the first cell of the line.</td>
</tr>

<tr>
<td>`pager.cursorLineTextStart()`</td>
<td>Move the cursor to the first non-blank character of the line.</td>
</tr>

<tr>
<td>`pager.cursorLineEnd()`</td>
<td>Move the cursor to the last cell of the line.</td>
</tr>

<tr>
<td>`pager.cursorNextWord()`</td>
<td>Move the cursor to the beginning of the next word.</td>
</tr>

<tr>
<td>`pager.cursorPrevWord()`</td>
<td>Move the cursor to the end of the previous word.</td>
</tr>

<tr>
<td>`pager.cursorNextLink()`</td>
<td>Move the cursor to the beginning of the next clickable element.</td>
</tr>

<tr>
<td>`pager.cursorPrevLink()`</td>
<td>Move the cursor to the beginning of the previous clickable element.</td>
</tr>

<tr>
<td>`pager.pageDown()`</td>
<td>Scroll down by one page.</td>
</tr>

<tr>
<td>`pager.pageUp()`</td>
<td>Scroll up by one page.</td>
</tr>

<tr>
<td>`pager.pageLeft()`</td>
<td>Scroll to the left by one page.</td>
</tr>

<tr>
<td>`pager.pageRight()`</td>
<td>Scroll to the right by one page.</td>
</tr>

<tr>
<td>`pager.halfPageDown()`</td>
<td>Scroll forwards by half a page.</td>
</tr>

<tr>
<td>`pager.halfPageUp()`</td>
<td>Scroll backwards by half a page.</td>
</tr>

<tr>
<td>`pager.scrollDown()`</td>
<td>Scroll forwards by one line.</td>
</tr>

<tr>
<td>`pager.scrollUp()`</td>
<td>Scroll backwards by one line.</td>
</tr>

<tr>
<td>`pager.scrollLeft()`</td>
<td>Scroll to the left by one column.</td>
</tr>

<tr>
<td>`pager.scrollRight()`</td>
<td>Scroll to the right by one column.</td>
</tr>

<tr>
<td>`pager.click()`</td>
<td>Click the HTML element currently under the cursor.</td>
</tr>

<tr>
<td>`pager.load(url)`</td>
<td>Go to the specified URL. Opens a prompt with the current URL when no
parameters are specified; otherwise, the string passed is displayed in
the prompt. If this string ends with a newline
(e.g. `pager.load("about:chawan\n")`), the URL is loaded directly.</td>
</tr>

<tr>
<td>`pager.dupeBuffer()`</td>
<td>Duplicate the current buffer by loading its source to a new buffer.</td>
</tr>

<tr>
<td>`pager.discardBuffer()`</td>
<td>Discard the current buffer, and move back to its previous sibling buffer,
or if that doesn't exist, to its parent. If the current buffer is a root buffer
(i.e. it has no parent), move to the next sibling buffer instead.</td>
</tr>

<tr>
<td>`pager.discardTree()`</td>
<td>Discard all child buffers of the current buffer.</td>
</tr>

<tr>
<td>`pager.reload()`</td>
<td>Open a new buffer with the current buffer's URL, replacing the current
buffer.</td>
</tr>

<tr>
<td>`pager.reshape()`</td>
<td>Reshape the current buffer (=render the current page anew.)</td>
</tr>

<tr>
<td>`pager.redraw()`</td>
<td>Redraw screen contents. Useful if something messed up the display.</td>
</tr>

<tr>
<td>`pager.toggleSource()`</td>
<td>If viewing a HTML buffer, open a new buffer with its source. Otherwise,
open the current buffer's contents as HTML.</td>
</tr>

<tr>
<td>`pager.cursorFirstLine()`</td>
<td>Move to the beginning in the buffer.</td>
</tr>

<tr>
<td>`pager.cursorLastLine()`</td>
<td>Move to the last line in the buffer.</td>
</tr>

<tr>
<td>`pager.cursorTop()`</td>
<td>Move to the first line on the screen. (Equivalent to H in vi.)</td>
</tr>

<tr>
<td>`pager.cursorMiddle()`</td>
<td>Move to the line in the middle of the screen. (Equivalent to M in vi.)</td>
</tr>

<tr>
<td>`pager.cursorBottom()`</td>
<td>Move to the last line on the screen. (Equivalent to L in vi.)</td>
</tr>

<tr>
<td>`pager.centerLine()`</td>
<td>Center screen around the current line.</td>
</tr>

<tr>
<td>`pager.cursorLeftEdge()`</td>
<td>Move to the first column on the screen.</td>
</tr>

<tr>
<td>`pager.cursorMiddleColumn()`</td>
<td>Move to the column in the middle of the screen.</td>
</tr>

<tr>
<td>`pager.cursorRightEdge()`</td>
<td>Move to the last column on the screen.</td>
</tr>

<tr>
<td>`pager.centerColumn()`</td>
<td>Center screen around the current column.</td>
</tr>

<tr>
<td>`pager.lineInfo()`</td>
<td>Display information about the current line.</td>
</tr>

<tr>
<td>`pager.searchForward()`</td>
<td>Search for a string in the current buffer.</td>
</tr>

<tr>
<td>`pager.searchBackward()`</td>
<td>Search for a string, backwards.</td>
</tr>

<tr>
<td>`pager.isearchForward()`</td>
<td>Incremental-search for a string, highlighting the first result.</td>
</tr>

<tr>
<td>`pager.isearchBackward()`</td>
<td>Incremental-search and highlight the first result, backwards.</td>
</tr>

<tr>
<td>`pager.gotoLine(n?)`</td>
<td>Go to the line passed as the first argument.<br>
If no arguments were specified, an input window for entering a line is
shown.</td>
</tr>

<tr>
<td>`pager.searchNext()`</td>
<td>Jump to the next search result.</td>
</tr>

<tr>
<td>`pager.searchPrev()`</td>
<td>Jump to the previous search result.</td>
</tr>

<tr>
<td>`pager.peek()`</td>
<td>Display an alert message of the current URL.</td>
</tr>

<tr>
<td>`pager.peekCursor()`</td>
<td>Display an alert message of the URL or title under the cursor. Multiple
calls allow cycling through the two. (i.e. by default, press u once -> title,
press again -> URL)</td>
</tr>

<tr>
<td>`pager.ask(prompt)`</td>
<td>Ask the user for confirmation. Returns a promise which resolves to a
boolean value indicating whether the user responded with yes.<br>
Can be used to implement an exit prompt like this:
```
q = 'pager.ask("Do you want to exit Chawan?").then(x => x ? pager.quit() : void(0))'
```
</td>
</tr>

<tr>
<td>`pager.extern(cmd, options = {setenv: true, suspend: true, wait: false})`
</td>
<td>Run an external command `cmd`. The `$CHA_URL` and `$CHA_CHARSET` variables
are set when `options.setenv` is true. `options.suspend` suspends the pager
while the command is being executed, and `options.wait` makes it so the user
must press a key before the pager is resumed.<br>
Returns true if the command exit successfully, false otherwise.<br>
Warning: this has a bug where the output is written to stdout even if suspend
is true. Redirect to /dev/null in the command if this is not desired. (This
will be fixed in the future.)</td>
</tr>

</table>


### Line-editing actions

<table>

<tr>
<th>**Name**</th>
<th>**Function**</th>
</tr>

<tr>
<td>`line.submit()`</td>
<td>Submit line</td>
</tr>

<tr>
<td>`line.cancel()`</td>
<td>Cancel operation</td>
</tr>

<tr>
<td>`line.backspace()`</td>
<td>Delete character before cursor</td>
</tr>

<tr>
<td>`line.delete()`</td>
<td>Delete character after cursor</td>
</tr>

<tr>
<td>`line.clear()`</td>
<td>Clear text before cursor</td>
</tr>

<tr>
<td>`line.kill()`</td>
<td>Clear text after cursor</td>
</tr>

<tr>
<td>`line.clearWord(bounds)`</td>
<td>Delete word before cursor</td>
</tr>

<tr>
<td>`line.killWord(bounds)`</td>
<td>Delete word after cursor</td>
</tr>

<tr>
<td>`line.backward()`</td>
<td>Move cursor back by one character</td>
</tr>

<tr>
<td>`line.forward()`</td>
<td>Move cursor forward by one character</td>
</tr>

<tr>
<td>`line.prevWord(bounds)`</td>
<td>Move cursor to the previous word by one character</td>
</tr>

<tr>
<td>`line.nextWord(bounds)`</td>
<td>Move cursor to the previous word by one character</td>
</tr>

<tr>
<td>`line.begin()`</td>
<td>Move cursor to the previous word by one character</td>
</tr>

<tr>
<td>`line.end()`</td>
<td>Move cursor to the previous word by one character</td>
</tr>

<tr>
<td>`line.escape()`</td>
<td>Ignore keybindings for next character</td>
</tr>

<tr>
<td>`line.prevHist()`</td>
<td>Jump to the previous history entry</td>
</tr>

<tr>
<td>`line.nextHist()`</td>
<td>Jump to the next history entry</td>
</tr>

</table>

Some of these entries have an optional `bounds` parameter. If passed, this
must be a JavaScript function that expects one parameter (the current
unicode character), and returns true if the passed character should count
as a word boundary.

```Examples:
# Control+A moves the cursor to the beginning of the line.
'C-a' = 'line.begin()'

# Escape+D deletes everything after the cursor until it reaches a word-breaking
# character.
'M-d' = 'line.killWord()'

# Control+W deletes everything before the cursor until it reaches a space. 
'C-w' = 'line.clearWord(x => x == " ")'
```

## Appendix

### Regex handling

Regular expressions are assumed to be exact matches, except when they start
with a caret (^) sign or end with an unescaped dollar ($) sign.

In other words, the following transformations occur:

```
^abcd -> ^abcd
efgh$ -> efgh$
^ijkl$ -> ^ijkl$
mnop -> ^mnop$
```
