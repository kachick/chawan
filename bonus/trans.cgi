#!/bin/sh
# Needs https://github.com/soimort/translate-shell to work.
# Usage: cgi-bin:trans.cgi?word

TEXT="$(echo "$QUERY_STRING" | sed 's/+/ /g;s/%/\\x/g' | xargs -0 printf "%b")"
printf 'Content-Type: text/plain\n'

type trans || {
	printf "\n\nERROR: translator not found"
	exit
}

printf '\n%s\n' "$(trans "$TEXT")"
