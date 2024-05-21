# Chawan - a web browser for your terminal

[Project page](https://sr.ht/~bptato/chawan)

![Screenshot of Chawan displaying its SourceHut page](doc/showcase.png)

## What is this?

A text-mode web browser. It displays websites in your terminal and allows
you to navigate on them.

It can also be used as a terminal pager.

## Compiling

Note: a POSIX-compliant operating system is required.

1. Clone the Chawan repository:
   `git clone https://git.sr.ht/~bptato/chawan && cd chawan`
2. Install the Nim compiler: <https://nim-lang.org/install.html>
	* Please use 1.6.14 or newer, ideally 2.0.4. Versions older than 1.6.14
	  will not work. (You can check your Nim compiler's version using
	  `nim -v`.)
3. Install the following dependencies:
	* libcurl: <https://curl.se/libcurl/>
	* zlib: <https://zlib.net/>
	* pkg-config, pkgconf, or similar (must be found as "pkg-config" in your
	  `$PATH`)
	* (Linux only) libseccomp: <https://github.com/seccomp/libseccomp>
	* GNU make. On systems where it is not the default make, install and use
	  `gmake` in the following steps.
	* Recommended: a termcap library. e.g. ncurses comes with one.
	* TL;DR for Debian:
	  `apt install libcurl4-openssl-dev zlib1g-dev pkg-config make ncurses-base libseccomp-dev`
4. Download parts of Chawan found in other repositories: `make submodule`
5. Run `make`.
6. Install using `make install` (e.g. `sudo make install`).

Then, try:

```bash
$ cha -V # open in visual mode for a list of default keybindings
$ cha example.org # open your favorite website directly from the shell
$ mancha cha # read the cha(1) man page using `mancha'
```

## Features

Currently implemented features are:

* multi-processing (several buffers can be loaded at once)
* multi-charset, double-width aware text display (but no bi-di yet)
* HTML5 support
* CSS-capable layout engine
	* flow layout (with floats!), automatic table layout, flexbox layout
	  (some flex attributes still WIP)
* forms
* incremental loading of documents
* JavaScript based navigation (i.e. programmable keybindings)
* JavaScript support in documents
	* some basic DOM manipulation APIs are supported
	* disabled by default; enable it at your own risk.
* cookies
* supports several protocols: HTTP(S), FTP, Gopher, Gemini, Finger, etc.
* can load user-defined protocols/file formats using [local CGI](doc/localcgi.md),
  [urimethodmap](doc/urimethodmap.md) and [mailcap](doc/mailcap.md)
* markdown viewer
* man page viewer (like w3mman)
* mouse support
* OS-level sandboxing on FreeBSD, OpenBSD and Linux (through Capsicum, pledge
  and libseccomp)

...with a lot more [planned](todo).

## Documentation

* build/compilation options: [doc/build.md](doc/build.md)
* manpage: [doc/cha.1](doc/cha.1)
* configuration options: [doc/config.md](doc/config.md)
* API description (for keybindings): [doc/api.md](doc/api.md)
* mailcap: [doc/mailcap.md](doc/mailcap.md)
* mime.types: [doc/mime.types.md](doc/mime.types.md)
* urimethodmap: [doc/urimethodmap.md](doc/urimethodmap.md)
* local CGI: [doc/localcgi.md](doc/localcgi.md)
* protocols: [doc/protocols.md](doc/protocols.md)

## Neighbors

Many other text-based web browsers exist. Here's some recommendations if you
want to try more established ones:

* [w3m](https://github.com/tats/w3m) - A text-mode browser, extensible using
  local-cgi. Also has inline image display and very good table support.
  Inspired many features of Chawan.
* [elinks](https://github.com/rkd77/elinks) - Has CSS and JavaScript support,
  and incremental rendering (it's pretty fast.)
* [lynx](https://lynx.invisible-island.net/) - "THE text-based web browser."
* [edbrowse](http://edbrowse.org/) - This one looks more like `ed` than
  `less` or `vi`. Mainly designed for blind users.
* [browsh](https://www.brow.sh/) - Firefox in your terminal.

## FAQ

### I can't select/copy text with my mouse?

Your options are:

* Use `v` (and copy with `y`). Drawback: requires keyboard
* Hold down the shift key while selecting. Drawback: can only select text
  currently on the screen
* Disable mouse support (`input.use-mouse = false` in config.toml). Drawback:
  see above (plus now you can't use the mouse to move on the screen)

### Why do I get strange/incorrect/ugly colors?

Chawan's display capabilities depend on what your terminal reports. In
particular:

* if the `$COLORTERM` variable is not set, then it may fall back to 8-bit or
  ANSI colors
* if it does not respond to querying the background color, then Chawan's color
  contrast correction will likely malfunction

You can fix this manually by adjusting the `display.default-background-color`,
`display.default-foreground-color`, and `display.color-mode` variables. See
[doc/config.md](doc/config.md#display) for details.

### Can I view Markdown files using Chawan?

Yes; Chawan now has a built-in markdown converter. If you don't like it, you
can always [replace it](doc/mailcap.md) with e.g. pandoc.

### I set my `$PAGER` to `cha` and now man pages are unreadable.

Most `man` implementations print formatted manual pages by default, which
Chawan *can* parse if they are passed through standard input.

Unfortunately, mandoc passes us the formatted document as a *file*, which Chawan
reasonably interprets as plain text without formatting.

At this point you have two options:

* `export PAGER='cha -T text/x-ansi'` and see that man suddenly works as
  expected.
* `alias man=mancha` and see that man suddenly works better than expected.

Ideally you should do both, to deal with cases like git help which shells out to
man directly.

### Where are the keybindings?

Please run `cha about:chawan` for a list of default keybindings. Users familiar
with *vi*, *vim*, etc. should find these defaults familiar.

A w3m-like keymap also exists at [bonus/w3m.toml](bonus/w3m.toml). Note that not
every w3m feature is implemented yet, so it's not 100% compatible.

### How do I view text files with wrapping?

By default, text files are not auto-wrapped, so viewing plain text files that
were not wrapped properly by the authors is somewhat annoying.

A workaround is to add this to your [config](doc/config.md#keybindings)'s
`[page]` section:

```toml
' f' = "pager.externFilterSource('fmt')"
```

and then press `<space> f` to view a wrapped version of the current text
file. (This assumes your system has an `fmt` program - if not, `fold -s` may
be an alternative.)

To always automatically wrap, you can add this to your
[user style](doc/config.md#stylesheets):

```css
plaintext { white-space: pre-wrap }
```

To do the same for HTML and ANSI text, use `plaintext, pre`.

### Why does `$WEBSITE` look awful?

Usually, this is because it uses some CSS features that are not yet implemented
in Chawan. The most common offenders are grid and CSS variables.

There are three ways of dealing with this:

1. If the website's contents are mostly text, install
   [rdrview](https://github.com/eafer/rdrview). Then bind the following command
   to a key of your choice in the [config](doc/config.md#keybindings)
   (e.g. `<space> r`):<br>
   `' r' = "pager.externFilterSource('rdrview -H -u \"$CHA_URL\"')"`<br>
   This does not fix the core problem, but will significantly improve your
   reading experience anyway.
2. Complain [here](https://todo.sr.ht/~bptato/chawan), and wait until the
   problem goes away.
3. Write a patch to fix the problem, and send it
   [here](https://lists.sr.ht/~bptato/chawan-devel).

### `$WEBSITE`'s interactive features don't work!

Some potential fixes:

* Logging in to websites requires cookies. Some websites also require cookie
  sharing across domains. For security reasons, Chawan does not allow any of
  this by default, so you will have to fiddle with siteconf to fix it. See
  [doc/config.md#siteconf](doc/config.md#siteconf) for details.
* Set the `referer-from` siteconf value to true; this will cause Chawan to send
  a `Referer` header when navigating to other URLs from the target URL.
* Enable JavaScript. If something broke, type M-c M-c to check the browser
  console, then follow step 3. of the previous answer.<br>
  Warning: remote JavaScript execution is inherently unsafe. Please only enable
  JavaScript on websites you trust.

### I'm interested in the technical details of Chawan.

Here's some:

* Written in Nim
* Uses QuickJS for JavaScript execution. (The QuickJS regex engine, libregexp,
  is also used for in-document searches.)
* Uses multi-processing provided by POSIX. (No threads.) Each buffer gets
  its own process; as a result, buffers can be duplicated by simply forking
  their process. File loading is done in yet another process. IPC happens
  through UNIX domain sockets.
* Layout, CSS cascading, HTML parsing, etc. are handled by built-in modules, not
  external libraries. (However, the HTML parser and the character coding library
  are available as separate libraries as well.)
* Uses termcap for basic terminal capability querying, and notcurses-style
  terminal queries for detecting "modern" features (like true color).

For further details, ~~you will have to read the source code~~ please read
[this](doc/architecture.md).

### Why write another web browser?

I've found other text-based web browsers insufficient for my needs, so
I thought it'd be a fun excercise to write one by myself, for myself.

Generally, I'm happy if Chawan works on websites I use frequently. If it
also works on other websites, that's a bonus.

## License

Chawan is dedicated to the public domain. See the UNLICENSE file for details.

Chawan also includes and depends on several other libraries. For further
details, see [license.html](res/license.html) or check the about:license
page in Chawan.
