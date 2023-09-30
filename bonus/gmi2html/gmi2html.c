/* This file is dedicated to the public domain.
 *
 * Convert gemtext to HTML. Only accepts input on stdin.
 */

#include <stdio.h>
#include <stdlib.h>

typedef enum {
	STATE_NORMAL,
	STATE_BLOCKQUOTE,
	STATE_NEWLINE,
	STATE_NEWLINE_EQUALS,
	STATE_NEWLINE_EQUALS_ARROW,
	STATE_BEFORE_URL,
	STATE_IN_URL,
	STATE_BEFORE_URL_NAME,
	STATE_URL_NAME,
	STATE_SINGLE_BACKTICK,
	STATE_DOUBLE_BACKTICK,
	STATE_PRE_START,
	STATE_IN_PRE,
	STATE_PRE_SINGLE_BACKTICK,
	STATE_PRE_DOUBLE_BACKTICK,
	STATE_SKIP_LINE,
	STATE_HASH,
	STATE_DOUBLE_HASH,
	STATE_AFTER_HASH,
	STATE_AFTER_DOUBLE_HASH,
	STATE_AFTER_TRIPLE_HASH
} ParseState;

static ParseState state = STATE_NEWLINE;
static ParseState prev_state = STATE_NORMAL;

int main() {
	int c;
#define BUFSIZE 4096
	char urlbuf[BUFSIZE + 1];
	char *urlp;

	urlp = urlbuf;
	printf("<!DOCTYPE html>");
#define SET_STATE(s) do { \
		prev_state = state; \
		state = s; \
	} while (0)
#define REDO_NORMAL do { \
		SET_STATE(STATE_NORMAL); \
		goto normal; \
	} while (0)
	while ((c = getc(stdin)) != EOF) {
		switch (state) {
		case STATE_NORMAL:
		case STATE_BLOCKQUOTE:
		case STATE_IN_PRE:
		case STATE_PRE_START:
		case STATE_SKIP_LINE:
		case STATE_URL_NAME:
		case STATE_AFTER_HASH:
		case STATE_AFTER_DOUBLE_HASH:
		case STATE_AFTER_TRIPLE_HASH:
normal:			switch (c) {
			case '\r': break;
			case '\n':
				if (state == STATE_BLOCKQUOTE) {
					fputs("</blockquote>", stdout);
				} else if (state == STATE_PRE_START) {
					fputs("\">", stdout);
					SET_STATE(STATE_IN_PRE);
				} else if (state == STATE_URL_NAME) {
					fputs("</a>", stdout);
					fputs("<br>", stdout);
				} else if (state == STATE_AFTER_HASH) {
					fputs("</h1>", stdout);
				} else if (state == STATE_AFTER_DOUBLE_HASH) {
					fputs("</h2>", stdout);
				} else if (state == STATE_AFTER_TRIPLE_HASH) {
					fputs("</h3>", stdout);
				} else if (state == STATE_SKIP_LINE) {
				} else {
					fputs("<br>", stdout);
				}
				SET_STATE(STATE_NEWLINE);
				break;
			case '<':
				fputs("&lt;", stdout);
				break;
			case '>':
				fputs("&gt;", stdout);
				break;
			case '&':
				fputs("&amp;", stdout);
				break;
			default:
				if (state != STATE_SKIP_LINE)
					putchar(c);
				break;
			}
			break;
		case STATE_NEWLINE:
			if (prev_state == STATE_IN_PRE) {
				if (c == '`') {
					SET_STATE(STATE_PRE_SINGLE_BACKTICK);
					break;
				} else {
					SET_STATE(STATE_IN_PRE);
					goto normal;
				}
			}
			switch (c) {
			case '=':
				SET_STATE(STATE_NEWLINE_EQUALS);
				break;
			case '>':
				SET_STATE(STATE_BLOCKQUOTE);
				printf("<blockquote>");
				break;
			case '`':
				SET_STATE(STATE_SINGLE_BACKTICK);
				break;
			case '#':
				SET_STATE(STATE_HASH);
				break;
			default:
				REDO_NORMAL;
			}
			break;
		case STATE_NEWLINE_EQUALS:
			if (c == '>') {
				SET_STATE(STATE_NEWLINE_EQUALS_ARROW);
			} else {
				putchar('=');
				REDO_NORMAL;
			}
			break;
		case STATE_NEWLINE_EQUALS_ARROW:
			if (c == ' ') {
				state = STATE_BEFORE_URL;
			} else {
				putchar('=');
				REDO_NORMAL;
			}
			break;
		case STATE_BEFORE_URL:
			if (c == ' ') {
				continue;
				break;
			} else {
				fputs("<a href=\"", stdout);
				SET_STATE(STATE_IN_URL);
				urlp = urlbuf;
			}
			/* fall through */
		case STATE_IN_URL:
			switch (c) {
			case '"':
				fputs("%22", stdout);
				if (urlp < &urlbuf[BUFSIZE])
					*urlp++ = '"';
				break;
			case ' ':
			case '\t':
				fputs("\">", stdout);
				*urlp = '\0';
				SET_STATE(STATE_BEFORE_URL_NAME);
				break;
			case '\n':
				*urlp = '\0';
				fputs("\">", stdout);
				fputs(urlbuf, stdout);
				fputs("</a><br>", stdout);
				SET_STATE(STATE_NEWLINE);
				break;
			default:
				if (urlp < &urlbuf[BUFSIZE] && c != '>'
						&& c != '<')
					*urlp++ = c;
				putchar(c);
			}
			break;
		case STATE_BEFORE_URL_NAME:
			if (c != ' ' && c != '\t') {
				SET_STATE(STATE_URL_NAME);
				goto normal;
			}
			break;
		case STATE_SINGLE_BACKTICK:
		case STATE_PRE_SINGLE_BACKTICK:
			if (c == '`') {
				SET_STATE(state == STATE_SINGLE_BACKTICK ?
					STATE_DOUBLE_BACKTICK :
					STATE_PRE_DOUBLE_BACKTICK);
			} else {
				putchar('`');
				REDO_NORMAL;
			}
			break;
		case STATE_DOUBLE_BACKTICK:
		case STATE_PRE_DOUBLE_BACKTICK:
			if (c == '`') {
				if (state == STATE_DOUBLE_BACKTICK) {
					SET_STATE(STATE_PRE_START);
					fputs("<pre title=\"", stdout);
				} else {
					fputs("</pre>", stdout);
					SET_STATE(STATE_SKIP_LINE);
				}
			} else {
				fputs("``", stdout);
				if (state == STATE_DOUBLE_BACKTICK) {
					REDO_NORMAL;
				} else {
					SET_STATE(STATE_IN_PRE);
					goto normal;
				}
			}
			break;
		case STATE_HASH:
			if (c == '#') {
				SET_STATE(STATE_DOUBLE_HASH);
			} else {
				fputs("<h1>", stdout);
				SET_STATE(STATE_AFTER_HASH);
				goto normal;
			}
			break;
		case STATE_DOUBLE_HASH:
			if (c == '#') {
				fputs("<h3>", stdout);
				SET_STATE(STATE_AFTER_TRIPLE_HASH);
			} else {
				fputs("<h2>", stdout);
				SET_STATE(STATE_AFTER_DOUBLE_HASH);
				goto normal;
			}
			break;
		}
	}
	exit(0);
}
