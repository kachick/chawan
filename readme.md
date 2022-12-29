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
* JavaScript based navigation, (very) basic JS support in documents
* cookies

...and a lot more planned.

## Caveats

Chawan is still very much an experimental browser engine with some serious
limitations:

* Chawan uses uses its own browser engine, implemented from scratch. Expect
  bugs and missing features.
* Chawan has no incremental layouting capabilities yet, so it may be
  rather slow on large websites with complicated layout.
* While buffers run as separate processes, Chawan does not have any actual
  sandboxing. I would strongly advise against enabling scripting until this
  problem is resolved.

## Configuration

See [doc/config.md](doc/config.md).

## Neighbors

Many other text-based web browsers exist. Here's some recommendations if you
want to try more established ones:

* w3m - Infinitely extensible with local-cgi and some creativity. Also
  has inline image support. Heavily inspired Chawan.
* elinks - Has CSS and JavaScript support, and incremental rendering
  (it's pretty fast.)
* lynx - "THE text-based web browser."
* edbrowse - This one looks more like `ed` than `less` or `vi`. Mainly
  designed for blind users.
* browsh - Firefox in your terminal.

## Why write another web browser?

I've found other text-based web browsers insufficient for my needs, so
I thought it'd be a fun excercise to write one by myself, for myself.

Generally, I'm happy if Chawan works on websites I use frequently. If it
also works on other websites, that's a bonus.
