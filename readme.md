# chawan - a web browser in your terminal

## What is this?

A terminal web browser. It displays websites in your terminal and allows you to
navigate on them.

It includes its own parsers, pager, and layout engine.

## Compiling

1. Install the nim compiler.
2. Use one of the following:
	- `make release` - normal release build
	- `make` - debug build

## Features

Currently implemented features are:

* an unicode, double-width capable pager
* a (basic) CSS-capable layout engine
* incomplete support for forms
* incomplete support for remote resources (i.e. css)

**Planned** features, roughly in order of importance:

* partial re-rendering of page layout
* full support for forms
* unicode normalization
* non-unicode charsets (they currently crash the browser)
* fast streams (aka pipes; use library?)
* standard-compliant support for remote resources
* incremental page loading (to function as a proper pager)
* table
* iframe
* ruby
* separate threads for io, fetching resources and rendering pages
* cookies
* external viewers (for audio, video, image, etc)
* image (sixel & kitty?)
* markdown (built-in parser)
* color contrast correction
* terminal color mode
* JavaScript
* config editor
* user stylesheet editor
* SOCKS proxy
* HTTP proxy
* firefox request imitation (might avoid being classified as a bot)
* adblock (use uBO?)
* html-only renderer?
* extension API? (or just cgi like in w3m?)
* gopher?
* gemini??

## Motivation

I've found other terminal web browsers insufficient for my needs, so I thought
it'd be a fun excercise to write one by myself, for myself.

The end result will of course not support nearly as many websites as Firefox or
Chromium, but I'd like it to be at least somewhat more functional on the
"modern web" than w3m or lynx.

In one way this is supposed to be a spiritual successor of w3m, with lots of
features but a completely different architecture. Meaning this browser should
be able to function as a replacement of w3m, just better. (I am still quite far
from reaching that goal however.)

## Configuration

See [doc/config.md](doc/config.md).
