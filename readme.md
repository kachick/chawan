# twt - a web browser in your terminal

## What is this?
A terminal web browser. It displays websites in your terminal and allows you to navigate on them.

## Why make another web browser?
I've found other terminal web browsers insufficient for my needs, so I thought it'd be a fun excercise to write one myself.  
I don't really want a standard-compliant browser, or one that displays pages perfectly - the only way you could do that in a terminal is to work like browsh, which kinda defeats the point of a terminal web browser. I want one that is good enough for daily use - something like lynx or w3m, but better.  
So the aim is to implement HTML rendering, some degree of JS support, and a very limited subset of CSS. Plus some other things I'd add to w3m if it weren't 50k lines of incomprehensible ancient C code.

## So what can this do?
Currently implemented features are:

* basic html rendering (very much WIP)
* custom keybindings

Planned features (roughly in order of importance):

* improved html rendering and parsing
* form
* table
* cookie
* SOCKS proxy
* HTTP proxy
* image (sixel/kitty)
* audio
* JavaScript
* extension API (adblock support?)
* video (sixel/kitty)
* custom charsets?
* async?
* markdown? (with pandoc or built-in parser?)
* gopher?
* gemini?

## How do I configure stuff?
Currently only keybindings can be configured. See the keymap file for the default (built-in) configuration.
