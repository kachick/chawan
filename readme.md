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

* a multi-charset, double-width capable, multi-processing pager
* a CSS-capable layout engine (with forms, tables...)
* incremental loading of plain text streams
* JavaScript based navigation, basic JS support in documents
* cookies

...and a lot more planned.

## Caveats

Chawan is still very much an experimental browser engine with some serious
limitations:

* Chawan uses its own browser engine, implemented from scratch (and the whatwg
  standards...) Expect bugs and missing features.
* Chawan has no incremental layouting capabilities yet, so the entire layout
  needs to be recomputed every time an element is invalidated. This makes
  Chawan unusable on large websites with a complicated layout. (I plan to fix
  this as soon as possible, but it will involve quite a few changes to the
  layout engine.)
* While buffers run as separate processes, Chawan does not have any actual
  sandboxing. I would strongly advise against enabling scripting until this
  problem is resolved.

## Configuration

See [doc/config.md](doc/config.md).

## Neighbors

Many other text-based web browsers exist. Here's some recommendations if you
want to try more established ones:

* w3m – I'm partial to w3m. Infinitely extensible with local-cgi and some
  creativity. Also has inline image support. Heavily inspired Chawan.
* elinks – Probably the one with the most "modern" features. Has CSS and
  JavaScript support, and incremental rendering (it's pretty fast.)
* lynx – "THE text-based web browser." What more to say.
* browsh – Firefox in your terminal. Probably the most practical out of the
  ones I listed.

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
