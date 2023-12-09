NIMC ?= nim c
OBJDIR ?= .obj
OUTDIR ?= target
PREFIX ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man
MANPREFIX1 ?= $(MANPREFIX)/man1
MANPREFIX5 ?= $(MANPREFIX)/man5
TARGET ?= release

ifeq ($(TARGET),debug)
FLAGS += --debugger:native
else ifeq ($(TARGET),release)
FLAGS += -d:strip -d:lto
else ifeq ($(TARGET),release0)
FLAGS += -d:release --stacktrace:on
else ifeq ($(TARGET),release1)
FLAGS += -d:release --debugger:native
endif

$(OUTDIR)/$(TARGET)/bin/cha: lib/libquickjs.a src/*.nim src/**/*.nim res/* res/**/*
	@mkdir -p "$(OUTDIR)/$(TARGET)/bin"
	$(NIMC) -d:curlLibName:$(CURLLIBNAME) -o:"$(OUTDIR)/$(TARGET)/bin/cha" \
		--nimcache:"$(OBJDIR)/$(TARGET)" -d:$(TARGET) $(FLAGS) \
		src/main.nim
	ln -sf "$(OUTDIR)/$(TARGET)/bin/cha" cha

CFLAGS = -g -Wall -O2 -DCONFIG_VERSION=\"$(shell cat lib/quickjs/VERSION)\"
QJSOBJ = $(OBJDIR)/quickjs

# Dependencies
$(QJSOBJ)/cutils.o: lib/quickjs/cutils.h
$(QJSOBJ)/libbf.o: lib/quickjs/cutils.h lib/quickjs/libbf.h
$(QJSOBJ)/libregexp.o: lib/quickjs/cutils.h lib/quickjs/libregexp.h \
	lib/quickjs/libunicode.h lib/quickjs/libregexp-opcode.h
$(QJSOBJ)/libunicode.o: lib/quickjs/cutils.h lib/quickjs/libunicode.h \
	lib/quickjs/libunicode-table.h
$(QJSOBJ)/quickjs.o: lib/quickjs/cutils.h lib/quickjs/list.h \
	lib/quickjs/quickjs.h lib/quickjs/libregexp.h \
	lib/quickjs/libunicode.h lib/quickjs/libbf.h \
	lib/quickjs/quickjs-atom.h lib/quickjs/quickjs-opcode.h

$(QJSOBJ)/%.o: lib/quickjs/%.c
	@mkdir -p "$(QJSOBJ)"
	$(CC) $(CFLAGS) -c -o $@ $<

lib/libquickjs.a: $(QJSOBJ)/quickjs.o $(QJSOBJ)/libregexp.o \
		$(QJSOBJ)/libunicode.o $(QJSOBJ)/cutils.o \
		$(QJSOBJ)/libbf.o
	@mkdir -p "$(QJSOBJ)"
	$(AR) rcs $@ $^

$(OBJDIR)/man/cha-%.md: doc/%.md
	@mkdir -p "$(OBJDIR)/man"
	./md2manpreproc $< > $@

$(OBJDIR)/man/cha-%.5: $(OBJDIR)/man/cha-%.md
	pandoc --standalone --to man $< -o $@

$(OBJDIR)/man/cha.1: doc/cha.1
	@mkdir -p "$(OBJDIR)/man"
	cp doc/cha.1 "$(OBJDIR)/man/cha.1"

.PHONY: clean
clean:
	rm -rf "$(OUTDIR)"
	rm -rf "$(OBJDIR)"
	rm -f lib/libquickjs.a

.PHONY: manpage
manpage: $(OBJDIR)/man/cha-config.5 $(OBJDIR)/man/cha-mailcap.5 \
	$(OBJDIR)/man/cha-mime.types.5 $(OBJDIR)/man/cha-localcgi.5 \
	$(OBJDIR)/man/cha-urimethodmap.5 \
	$(OBJDIR)/man/cha.1

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	install -m755 "$(OUTDIR)/$(TARGET)/bin/cha" "$(DESTDIR)$(PREFIX)/bin"
	if test -d "$(OBJDIR)/man"; then \
	mkdir -p "$(DESTDIR)$(MANPREFIX5)"; \
	mkdir -p "$(DESTDIR)$(MANPREFIX1)"; \
	install -m644 "$(OBJDIR)/man/cha-config.5" "$(DESTDIR)$(MANPREFIX5)"; \
	install -m644 "$(OBJDIR)/man/cha-mailcap.5" "$(DESTDIR)$(MANPREFIX5)"; \
	install -m644 "$(OBJDIR)/man/cha-mime.types.5" "$(DESTDIR)$(MANPREFIX5)"; \
	install -m644 "$(OBJDIR)/man/cha-localcgi.5" "$(DESTDIR)$(MANPREFIX5)"; \
	install -m644 "$(OBJDIR)/man/cha-urimethodmap.5" "$(DESTDIR)$(MANPREFIX5)"; \
	install -m644 "$(OBJDIR)/man/cha.1" "$(DESTDIR)$(MANPREFIX1)"; \
	fi

.PHONY: uninstall
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/cha"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-config.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-mailcap.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-mime.types.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-localcgi.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-urimethodmap.5"
	rm -f "$(DESTDIR)$(MANPREFIX1)/cha.1"

.PHONY: submodule
submodule:
	git submodule update --init
