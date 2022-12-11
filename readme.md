# chawan - a web browser in your terminal

## What is this?

A terminal web browser. It displays websites in your terminal and allows you to
navigate on them.

It also functions as a pager, similarly to w3m.

## Compiling

1. Install the nim compiler.
2. Install the following dependencies:
	- curl
	- quickjs
3. Use one of the following:
	- `make release` - normal release build
	- `make` - debug build

## Features

Currently implemented features are:

* a multi-charset, double-width capable pager
* a CSS-capable layout engine
* forms, tables
* incremental loading of plain text streams
* JavaScript based navigation

**Planned** features, roughly in order of importance:

* cookies
* JavaScript in html documents
* partial re-rendering of page layout
* unicode normalization
* standard-compliant support for remote resources
* iframe
* ruby
* external viewers (for audio, video, image, etc)
* image (sixel & kitty?)
* markdown (built-in parser)
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

## Configuration

See [doc/config.md](doc/config.md).

## FAQ

### Why did you write this?

I've found other terminal web browsers insufficient for my needs, so I thought
it'd be a fun excercise to write one by myself, for myself.

The end result will of course not support nearly as many websites as Firefox or
Chromium, but I'd like it to be at least somewhat more functional on the
"modern" web than w3m or lynx.

In one way this is supposed to be a spiritual successor of w3m, with a roughly
similar set of features but on a completely different architecture. Meaning
this browser should be able to function as a replacement of w3m, just "better"
(YMMV).
