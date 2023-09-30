CFLAGS = -Wall -Wextra -std=c89 -pedantic -g -O2 -fsanitize=address
prefix = /usr/local

gmi2html: gmi2html.c
	$(CC) $(CFLAGS) gmi2html.c -o gmi2html

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(prefix)/bin"
	install -m755 gmi2html "$(DESTDIR)$(prefix)/bin"
