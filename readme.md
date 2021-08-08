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
Chromium (so forget PWAs I guess), but I'd like it to be at least somewhat more
functional on the "modern web" than w3m or lynx.

While the original idea was to implement something similar to w3m's rendering
with JS and minimal CSS support, I've got a bit carried away with my CSS parser
so the new plan is to mostly implement basic CSS stuff and then JS with the
most important APIs. Plus some other things.

## So what can this do?

Currently implemented features are:

* basic html rendering (very much WIP)
* custom keybindings
* compose (basically a mini-IME, I might get rid of it later)

Planned features (roughly in order of importance):

* improved html rendering (i.e. actually functioning)
* anchor
* html generator (for source view)	
* loading author stylesheets (i.e. ones in web pages)
* markdown (with built-in parser)
* form (w/ input etc)
* JavaScript
* table
* cookie
* adblock (use uBO?)
* SOCKS proxy
* HTTP proxy
* image (sixel/kitty)
* audio
* video (sixel/kitty)
* frame?
* extension API?
* non-unicode charsets?
* tabs (async?)
* gopher?
* gemini??

## How do I configure stuff?

Currently only keybindings and compose key combinations can be configured. See
the res/config file for the default (built-in) configuration.

twt will look for a config file in the ~/.config/twt/ directory, so you can
just copy the one from res/ there and customize that to your liking.
