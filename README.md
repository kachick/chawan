# Chawan - a web browser for your terminal

## What is this?

A text-mode web browser. It displays websites in your terminal and allows
you to navigate on them.

It also functions as a pager, similarly to w3m.

## Compiling

1. Install the nim compiler: <https://nim-lang.org/install.html>
	* Please use 1.6+, older versions will probably not work. (You
	  can check your nim compiler's version using `nim -v`.)
2. Install the following dependencies:
	* libcurl: <https://curl.se/libcurl/>
	* zlib: <http://zlib.net/>
	* (QuickJS is included in the repository.)
3. Use one of the following:
	* `make release` - optimized release build
	* `make` - debug build (slow, for development)

## Features

Currently implemented features are:

* a multi-charset, double-width capable, multi-processing pager
* a CSS-capable layout engine (with forms, tables...)
* incremental loading of plain text streams
* JavaScript based navigation, (very) basic JS support in documents
* cookies

...with a lot more planned.

## Caveats

Chawan is still an experimental web browser with some serious limitations:

* The browser engine is still missing many features, both in JavaScript and
  CSS. In particular, events haven't been implemented yet, and the layout
  engine can't handle CSS floats.
* Chawan has no incremental layouting capabilities yet, so it is rather slow
  on large websites with a complicated layout.
* While buffers run as separate processes, Chawan does not do any actual
  sandboxing. I would strongly advise against enabling scripting until this
  problem is resolved.

## Configuration

See [doc/config.md](doc/config.md).

## Neighbors

Many other text-based web browsers exist. Here's some recommendations if you
want to try more established ones:

* [w3m](https://github.com/tats/w3m) - A text-mode browser, extensible using
  local-cgi. Also has inline image display and very good table support. Heavily
  inspired Chawan.
* [elinks](https://github.com/rkd77/elinks) - Has CSS and JavaScript support,
  and incremental rendering (it's pretty fast.)
* [lynx](https://lynx.invisible-island.net/) - "THE text-based web browser."
* [edbrowse](http://edbrowse.org/) - This one looks more like `ed` than
  `less` or `vi`. Mainly designed for blind users.
* [browsh](https://www.brow.sh/) - Firefox in your terminal.

## FAQ

### Why does Chawan use strange/incorrect/ugly colors?

Chawan assumes the terminal's default background/foreground colors are
black and white. If this is not true for your terminal, make sure to set
the display.default-background-color and display.default-foreground-color
properties in your Chawan configuration file.

Also, by default, Chawan uses the eight ANSI colors to display colored
text. To use true colors, either export COLORTERM=truecolor or set the
display.color-mode to "24bit". To use 256 colors, set display.color-mode to
"8bit" instead. (You can also turn off colors and/or styling altogether in
the configuration; please consult [doc/config.md](doc/config.md) for details.)

### Why write another web browser?

I've found other text-based web browsers insufficient for my needs, so
I thought it'd be a fun excercise to write one by myself, for myself.

Generally, I'm happy if Chawan works on websites I use frequently. If it
also works on other websites, that's a bonus.

### Where are the w3m keybindings?

At [bonus/w3m.toml](bonus/w3m.toml). Note that not every w3m feature is
implemented yet, so it's not 100% compatible.

I use vi for editing text, and I prefer my pager to function similarly to
my editor. Hence the default vi-like keybindings.

### Why does *website X* look awful in Chawan?

As mentioned above, the layout engine is still very much a work in progress. At
this point, it's more interesting if a website works as intended in Chawan
than if it doesn't.

### Where are the tabs?

Chawan does not have browser tabs. Instead, each website is opened in a new
buffer, which is added to the buffer tree. This is very similar to how w3m
handles buffers, except a) source files are stored in memory, not on the disk,
and b) instead of a linked list of buffers, they are stored in a tree. (And
of course, c) there are no tabs.)

This model has the advantage of allowing the user to instantly view the
previous page in all cases, without any complicated caching mechanism. It
also opens up many interesting possibilities concering buffer organization;
unfortunately, not much of that is implemented yet (except for basic tree
traversal commands.)

## License

Chawan is dedicated to the public domain. See the UNLICENSE file for details.
