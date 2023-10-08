#!/bin/sh
# Needs https://github.com/soimort/translate-shell to work.
# Usage: cgi-bin:trans.cgi?word

decode() {
	# URL-decode the string passed as the first parameter
	printf '%s\n' "$1" | \
		sed 's/+/ /g;s/%/\\x/g' | \
		xargs -0 printf "%b"
}

# QUERY_STRING is URL-encoded. We decode it using the decode() function.
TEXT="$(decode "$QUERY_STRING")"

# Write a Content-Type HTTP header. The `trans' command outputs plain text,
# so we use text/plain.
printf 'Content-Type: text/plain\n'

# We must write a newline here, so Chawan knows that all headers have been
# written and incoming data from now on belongs to the body.
printf '\n'

# Check if the `trans' program exists, and if not, die.
type trans >/dev/null || {
	printf "ERROR: translator not found"
	exit 1
}

# Call the `trans' program. It writes its output to standard out, which
# Chawan's local CGI will read in as the content body.
trans "$TEXT"
