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

* a pager
* a (basic) CSS-capable layout engine
* configuration

**Planned** features (roughly in order of importance):

* incremental page loading (to function as a proper pager)
* tables
* forms
* markdown (with built-in parser)
* load external/remote resources (e.g. css)
* image (sixel/kitty)
* external viewers (for audio, video)
* color contrast correction
* non-unicode charsets
* multi-processing
* JavaScript
* config (& user stylesheet) editor
* cookie
* SOCKS proxy
* HTTP proxy
* adblock (use uBO?)
* frame?
* extension API?
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
from that goal however.)

## How to configure stuff

See [doc/config.md](doc/config.md).
