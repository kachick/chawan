# twt - a web browser in your terminal

## What is this?

A terminal web browser. It displays websites in your terminal and allows you to
navigate on them.

## How to compile?

1. Install the nim compiler.
2. Use one of the following:
	- `make release` - normal release build
	- `make` - debug build

## Why make another web browser?

I've found other terminal web browsers insufficient for my needs, so I thought
it'd be a fun excercise to write one by myself, for myself.

The end result will of course not support nearly as many websites as Firefox or
Chromium, but I'd like it to be at least somewhat more functional on the
"modern web" than w3m or lynx.

The plan is to mostly implement basic CSS stuff and then JS with the most
important APIs. Plus some other things.

## So what can this do?

Currently implemented features are:

* pager with custom keybindings
* css rules (with user-agent, user, non-remote author stylesheets)
* html display with CSS-capable layout engine (very much WIP)

Planned features (roughly in order of importance):

* refactored and improved layout engine (with inline blocks etc)
* anchor
* html generator (for source view)	
* load external/remote resources (e.g. css)
* markdown (with built-in parser)
* form (w/ input etc)
* JavaScript
* table
* config (& user stylesheet) editor
* cookie
* SOCKS proxy
* HTTP proxy
* image (sixel/kitty)
* audio
* video (sixel/kitty)
* adblock (use uBO?)
* frame?
* extension API?
* non-unicode charsets?
* tabs (async?)
* gopher?
* gemini??

## How do I configure stuff?

See [doc/config.md](doc/config.md).
