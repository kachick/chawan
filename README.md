# Chawan - a web browser for your terminal

[Project page](https://sr.ht/~bptato/chawan)

![Screenshot of Chawan displaying its SourceHut page](doc/showcase.png)

## What is this?

A text-mode web browser. It displays websites in your terminal and allows
you to navigate on them.

It can also be used as a terminal pager.

## Compiling

Note: a POSIX-compliant operating system is required. (Windows is not
supported yet.)

1. Clone the Chawan repository:
   `git clone https://git.sr.ht/~bptato/chawan && cd chawan`
2. Install the Nim compiler: <https://nim-lang.org/install.html>
	* Please use 1.6.14 or newer, ideally 2.0.2. Versions older than 1.6.14
	  will not work. (You can check your Nim compiler's version using
	  `nim -v`.)
3. Install the following dependencies:
	* libcurl: <https://curl.se/libcurl/>
	* zlib: <https://zlib.net/>
	* pkg-config, pkgconf, or similar (must be found as "pkg-config" in your
	  `$PATH`)
	* (Linux only) libseccomp: <https://github.com/seccomp/libseccomp>
	* If you are using a system where the default make program is not GNU
	  make (e.g. BSD), install gmake and use that in the following steps.
	* Optional: a termcap library; e.g. ncurses comes with one.
	* TLDR for Debian:
	  `apt install libcurl4-openssl-dev zlib1g-dev pkg-config make ncurses-base libseccomp-dev`
4. Download parts of Chawan found in other repositories: `make submodule`
5. Run `make`. (By default, this will build the whole project in release mode;
   for details, see [doc/build.md](doc/build.md).)
6. If you want manpages, run `make manpage`. (This requires
   [pandoc](https://pandoc.org).)
7. Finally, install using `make install` (e.g. `sudo make install`).

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
* a CSS-capable layout engine
	* flow layout is supported (now with floats!)
	* table layout is supported, except for fixed tables
	* the box model is mostly implemented, except for borders
	* flexbox layout is supported (some parts are still a WIP)
* forms
* incremental loading of various kinds of documents (plain text, HTML, etc.)
* JavaScript based navigation
* JavaScript support in documents
	* some basic DOM manipulation APIs are supported
        * off by default; use is discouraged until sandboxing is implemented
* cookies
* supports several protocols: HTTP(S), FTP, Gopher, Gemini, Finger, etc.
* can load user-defined protocols/file formats using [local CGI](doc/localcgi.md),
  [urimethodmap](doc/urimethodmap.md) and [mailcap](doc/mailcap.md)
* markdown viewer
* man page viewer (like w3mman)
* mouse support

...with a lot more [planned](todo).

## Documentation

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

### Why does Chawan use strange/incorrect/ugly colors?

Chawan's display capabilities depend on what your terminal reports. In
particular:

* if it does not respond to querying XTGETTCAP, and the `$COLORTERM` environment
  variable is not set, then Chawan falls back to ANSI colors
* if it does not respond to querying the background color, then Chawan's color
  contrast correction will likely malfunction

You can fix this manually by adjusting the `display.default-background-color`,
`display.default-foreground-color`, and `display.color-mode` variables. See
[doc/config.md](doc/config.md#display) for details.

### Can I view Markdown files using Chawan?

Yes; Chawan now has a built-in markdown converter. If you don't like it, you
can always [replace it](doc/mailcap.md) with e.g. pandoc.

### I set Chawan as my PAGER and now man pages are unreadable.

TLDR: use mancha.

Long explanation:

Most `man` implementations print formatted manual pages by default, which
Chawan *can* in fact automatically parse, *if* they are passed through standard
input. Unfortunately, some `man` implementations (mandoc in particular) pass us
the formatted document as a *file*, which Chawan reasonably interprets as plain
text without formatting. (mandoc does not even set a useful file extension to
guide us.)

At this point you have two options:

* Set PAGER='cha -T text/x-ansi', and see that man suddenly works as expected.
* alias man=mancha in your bashrc, and see that man suddenly works better than
  expected.

It may be best to do both, to deal with annoying cases like git help which
shells out to man directly.

### Where are the keybindings?

Please run `cha about:chawan` for a list of default keybindings. (By default,
this is equivalent to `cha -V`.)

### Where are the w3m keybindings?

At [bonus/w3m.toml](bonus/w3m.toml). Note that not every w3m feature is
implemented yet, so it's not 100% compatible.

I use vi for editing text, and I prefer my pager to function similarly to
my editor. Hence the default vi-like keybindings.

### How do I view text files with wrapping?

By default, text files are not auto-wrapped. This is useful in some cases, but
viewing plain text files that were not wrapped properly by the authors becomes
slightly annoying.

A simple workaround is to add this to your [config](doc/config.md#keybindings)'s
`[page]` section:

```toml
' f' = "pager.externFilterSource('fmt')"
```

and then press `<space> f` to view a wrapped version of the current text
file. (This assumes your system has an `fmt` program - if not, `fold -s` may
be an alternative.)

Alternatively, you can add this to your [user style](doc/config.md#stylesheets):

```css
plaintext { white-space: pre-wrap }
```

and then all plain text files will automatically wrap. To do the same for HTML
and ANSI text, use `plaintext, pre`.

### Why does `$WEBSITE` look awful?

Usually, this is because it uses some CSS features that are not yet implemented
in Chawan. The most common offenders are grid and CSS variables.

There are three ways of dealing with this:

1. The hacky solution: if the website's contents are mostly text, install
   [rdrview](https://github.com/eafer/rdrview). Then bind the following command
   to a key of your choice in the [config](doc/config.md#keybindings)
   (e.g. `<space> r`):<br>
   `' r' = "pager.externFilterSource('rdrview -H -u \"$CHA_URL\"')"`<br>
   This does not fix the core problem, but will significantly improve your
   reading experience anyway.
2. The slow solution: complain [here](https://todo.sr.ht/~bptato/chawan),
   and wait until the problem goes away.
3. If you're feeling adventurous: write a patch to fix the problem, and send it
   [here](https://lists.sr.ht/~bptato/chawan-devel).

### `$WEBSITE`'s interactive features don't work!

Some potential fixes:

* Usually logging in to websites requires cookies. Some websites also require
  cookie sharing across domains. For security reasons, Chawan does not allow
  any of this by default, so you will have to fiddle with siteconf to fix
  it. (i.e. on all target hostnames, set `cookie` to true, `share-cookie-jar`
  to the main host, and `third-party-cookie` to all target hosts. See
  [doc/config.md#siteconf](doc/config.md#siteconf) for details.)
* Set the `referer-from` siteconf value to true; this will cause Chawan to send
  a `Referer` header when navigating to other URLs from the target URL.
* Enable JavaScript. If something broke, type M-c M-c to check the browser
  console, then follow step 3. of the previous answer.<br>
  Warning: remote JavaScript execution is inherently unsafe; more so in Chawan,
  which lacks proper sandboxing of buffer processes. Please only enable
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
