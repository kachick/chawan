# twt - a web browser in your terminal

## What is this?

A terminal web browser. It displays websites in your terminal and allows you to navigate on them.

## How to compile?

1. Install the nim compiler.
2. Use one of the following:
	- `make release` - normal release build
	- `make small` - small release build
	- `make` - debug build

## Why make another web browser?

I've found other terminal web browsers insufficient for my needs, so I thought
it'd be a fun excercise to write one myself.  

I don't really want a standard-compliant browser, or one that displays pages
perfectly - the only way you could do that in a terminal is to work like
browsh, which kinda defeats the point of a terminal web browser. I want one
that is good enough for daily use, something like lynx or w3m.  

So the aim is to implement HTML rendering, some degree of JS support, and a
very limited subset of CSS. Plus some other things.

## So what can this do?

Currently implemented features are:

* basic html rendering (very much WIP)
* custom keybindings

Planned features (roughly in order of importance):

* stylesheets
* JavaScript
* improved html rendering (i.e. actually functioning)
* form
* table
* cookie
* SOCKS proxy
* HTTP proxy
* image (sixel/kitty)
* audio
* video (sixel/kitty)
* frame?
* extension API?
* non-unicode charsets?
* async?
* markdown? (with built-in parser)
* gopher?
* gemini??

## How do I configure stuff?

Currently only keybindings can be configured. See the res/config file for the default (built-in) configuration.
