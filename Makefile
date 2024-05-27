NIMC ?= nim c
OBJDIR ?= .obj
OUTDIR ?= target
# These paths are quoted in recipes.
PREFIX ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man
MANPREFIX1 ?= $(MANPREFIX)/man1
MANPREFIX5 ?= $(MANPREFIX)/man5
TARGET ?= release
# This must be single-quoted, because it is not a real shell substitution.
# The default setting is at {the binary's path}/../libexec/chawan.
# You may override it with any path if your system does not have a libexec
# directory, but make sure to surround it with quotes if it contains spaces.
# (This way, the cha binary can be directly executed without installation.)
LIBEXECDIR ?= '$${%CHA_BIN_DIR}/../libexec/chawan'
# If overridden, take libexecdir that was specified.
# Otherwise, just install to libexec/chawan.
ifeq ($(LIBEXECDIR),'$${%CHA_BIN_DIR}/../libexec/chawan')
LIBEXECDIR_CHAWAN = "$(DESTDIR)$(PREFIX)/libexec/chawan"
else
LIBEXECDIR_CHAWAN = $(LIBEXECDIR)
endif

# These paths are quoted in recipes.
OUTDIR_TARGET = $(OUTDIR)/$(TARGET)
OUTDIR_BIN = $(OUTDIR_TARGET)/bin
OUTDIR_LIBEXEC = $(OUTDIR_TARGET)/libexec/chawan
OUTDIR_CGI_BIN = $(OUTDIR_LIBEXEC)/cgi-bin
OUTDIR_MAN = $(OUTDIR_TARGET)/share/man

# I won't take this from the environment for obvious reasons. Please override it
# in the make command if you must, or (preferably) fix your environment so it's
# not needed.
DANGER_DISABLE_SANDBOX = 0

# Nim compiler flags
ifeq ($(TARGET),debug)
FLAGS += -d:debug --debugger:native
else ifeq ($(TARGET),release)
FLAGS += -d:release -d:strip -d:lto
else ifeq ($(TARGET),release0)
FLAGS += -d:release --stacktrace:on
else ifeq ($(TARGET),release1)
FLAGS += -d:release --debugger:native
endif

QJSOBJ = $(OBJDIR)/quickjs

.PHONY: all
all: $(OUTDIR_BIN)/cha $(OUTDIR_BIN)/mancha $(OUTDIR_CGI_BIN)/http \
	$(OUTDIR_CGI_BIN)/gmifetch $(OUTDIR_LIBEXEC)/gmi2html \
	$(OUTDIR_CGI_BIN)/gopher $(OUTDIR_LIBEXEC)/gopher2html \
	$(OUTDIR_CGI_BIN)/cha-finger $(OUTDIR_CGI_BIN)/about \
	$(OUTDIR_CGI_BIN)/data $(OUTDIR_CGI_BIN)/file $(OUTDIR_CGI_BIN)/ftp \
	$(OUTDIR_CGI_BIN)/man $(OUTDIR_CGI_BIN)/spartan \
	$(OUTDIR_LIBEXEC)/urldec $(OUTDIR_LIBEXEC)/urlenc \
	$(OUTDIR_LIBEXEC)/md2html $(OUTDIR_LIBEXEC)/ansi2html

$(OUTDIR_BIN)/cha: lib/libquickjs.a src/*.nim src/**/*.nim src/**/*.c res/* \
		res/**/* res/map/idna_gen.nim nim.cfg
	@mkdir -p "$(OUTDIR_BIN)"
	$(NIMC) --nimcache:"$(OBJDIR)/$(TARGET)/cha" -d:libexecPath=$(LIBEXECDIR) \
                -d:disableSandbox=$(DANGER_DISABLE_SANDBOX) $(FLAGS) \
		-o:"$(OUTDIR_BIN)/cha" src/main.nim
	ln -sf "$(OUTDIR)/$(TARGET)/bin/cha" cha

$(OUTDIR_BIN)/mancha: adapter/tools/mancha.nim
	@mkdir -p "$(OUTDIR_BIN)"
	$(NIMC) --nimcache:"$(OBJDIR)/$(TARGET)/mancha" $(FLAGS) \
		-o:"$(OUTDIR_BIN)/mancha" $(FLAGS) adapter/tools/mancha.nim

$(OBJDIR)/genidna: res/genidna.nim
	$(NIMC) --nimcache:"$(OBJDIR)/idna_gen_cache" -d:danger \
		-o:"$(OBJDIR)/genidna" res/genidna.nim

res/map/idna_gen.nim: $(OBJDIR)/genidna
	$(OBJDIR)/genidna > res/map/idna_gen.nim

$(OBJDIR)/gencharwidth: res/gencharwidth.nim
	$(NIMC) --nimcache:"$(OBJDIR)/charwidth_gen_cache" -d:danger \
		-o:"$(OBJDIR)/gencharwidth" res/gencharwidth.nim

res/map/charwidth_gen.nim: $(OBJDIR)/gencharwidth
	$(OBJDIR)/gencharwidth > res/map/charwidth_gen.nim

src/utils/strwidth.nim: res/map/charwidth_gen.nim src/utils/proptable.nim

$(OUTDIR_LIBEXEC)/gopher2html: adapter/format/gopher2html.nim \
		src/utils/twtstr.nim adapter/gophertypes.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/gopher2html" \
		-o:"$(OUTDIR_LIBEXEC)/gopher2html" adapter/format/gopher2html.nim

$(OUTDIR_LIBEXEC)/md2html: adapter/format/md2html.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/md2html" \
		-o:"$(OUTDIR_LIBEXEC)/md2html" adapter/format/md2html.nim

$(OUTDIR_LIBEXEC)/ansi2html: adapter/format/ansi2html.nim src/types/color.nim \
		src/utils/twtstr.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/ansi2html" \
		-o:"$(OUTDIR_LIBEXEC)/ansi2html" adapter/format/ansi2html.nim

GMIFETCH_CFLAGS = -Wall -Wextra -std=c89 -pedantic -g -O2 $$(pkg-config --cflags libssl) $$(pkg-config --cflags libcrypto)
GMIFETCH_LDFLAGS = $$(pkg-config --libs libssl) $$(pkg-config --libs libcrypto)
$(OUTDIR_CGI_BIN)/gmifetch: adapter/protocol/gmifetch.c
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(CC) $(GMIFETCH_CFLAGS) adapter/protocol/gmifetch.c -o "$(OUTDIR_CGI_BIN)/gmifetch" $(GMIFETCH_LDFLAGS)

$(OUTDIR_LIBEXEC)/gmi2html: adapter/format/gmi2html.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/gmi2html" \
		-o:"$(OUTDIR_LIBEXEC)/gmi2html" adapter/format/gmi2html.nim

$(OUTDIR_CGI_BIN)/cha-finger: adapter/protocol/cha-finger
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	cp adapter/protocol/cha-finger $(OUTDIR_CGI_BIN)

$(OUTDIR_CGI_BIN)/man: adapter/protocol/man.nim $(QJSOBJ)/libregexp.o \
		$(QJSOBJ)/libunicode.o $(QJSOBJ)/cutils.o src/js/jsregex.nim \
		src/bindings/libregexp.nim src/types/opt.nim src/utils/twtstr.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/man" \
		--passL:"$(QJSOBJ)/libregexp.o $(QJSOBJ)/cutils.o $(QJSOBJ)/libunicode.o" \
		-o:"$(OUTDIR_CGI_BIN)/man" adapter/protocol/man.nim

$(OUTDIR_CGI_BIN)/spartan: adapter/protocol/spartan
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	cp adapter/protocol/spartan $(OUTDIR_CGI_BIN)

$(OUTDIR_CGI_BIN)/http: adapter/protocol/http.nim adapter/protocol/curlwrap.nim \
		adapter/protocol/curlerrors.nim adapter/protocol/curl.nim \
		src/utils/twtstr.nim src/utils/sandbox.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/http" -d:curlLibName:$(CURLLIBNAME) \
                -d:disableSandbox=$(DANGER_DISABLE_SANDBOX) \
                -o:"$(OUTDIR_CGI_BIN)/http" adapter/protocol/http.nim

$(OUTDIR_CGI_BIN)/about: adapter/protocol/about.nim res/chawan.html \
		res/license.md
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/about" -o:"$(OUTDIR_CGI_BIN)/about" adapter/protocol/about.nim

$(OUTDIR_CGI_BIN)/data: adapter/protocol/data.nim src/utils/twtstr.nim \
		src/types/opt.nim src/utils/map.nim src/utils/charcategory.nim \
		src/loader/connecterror.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/data" -o:"$(OUTDIR_CGI_BIN)/data" adapter/protocol/data.nim

$(OUTDIR_CGI_BIN)/file: adapter/protocol/file.nim adapter/protocol/dirlist.nim \
		src/utils/twtstr.nim src/utils/strwidth.nim \
		res/map/EastAsianWidth.txt src/loader/connecterror.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/file" -o:"$(OUTDIR_CGI_BIN)/file" adapter/protocol/file.nim

$(OUTDIR_CGI_BIN)/ftp: adapter/protocol/ftp.nim adapter/protocol/dirlist.nim \
		src/utils/twtstr.nim src/utils/strwidth.nim \
		res/map/EastAsianWidth.txt src/loader/connecterror.nim \
		src/types/opt.nim adapter/protocol/curl.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) -d:curlLibName:$(CURLLIBNAME) --nimcache:"$(OBJDIR)/$(TARGET)/ftp" \
		-o:"$(OUTDIR_CGI_BIN)/ftp" adapter/protocol/ftp.nim

$(OUTDIR_CGI_BIN)/gopher: adapter/protocol/gopher.nim adapter/protocol/curlwrap.nim \
		adapter/protocol/curlerrors.nim adapter/gophertypes.nim \
		adapter/protocol/curl.nim src/loader/connecterror.nim \
		src/utils/twtstr.nim
	@mkdir -p "$(OUTDIR_CGI_BIN)"
	$(NIMC) $(FLAGS) -d:curlLibName:$(CURLLIBNAME) --nimcache:"$(OBJDIR)/$(TARGET)/gopher" \
		-o:"$(OUTDIR_CGI_BIN)/gopher" adapter/protocol/gopher.nim

$(OUTDIR_LIBEXEC)/urldec: adapter/tools/urldec.nim src/utils/twtstr.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/urldec" \
		-o:"$(OUTDIR_LIBEXEC)/urldec" adapter/tools/urldec.nim

$(OUTDIR_LIBEXEC)/urlenc: adapter/tools/urlenc.nim src/utils/twtstr.nim
	@mkdir -p "$(OUTDIR_LIBEXEC)"
	$(NIMC) $(FLAGS) --nimcache:"$(OBJDIR)/$(TARGET)/urlenc" \
		-o:"$(OUTDIR_LIBEXEC)/urlenc" adapter/tools/urlenc.nim

CFLAGS = -fwrapv -g -Wall -O2 -DCONFIG_VERSION=\"$(shell cat lib/quickjs/VERSION)\"

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

$(OBJDIR)/man/cha-%.md: doc/%.md md2manpreproc
	@mkdir -p "$(OBJDIR)/man"
	./md2manpreproc $< > $@

doc/cha-%.5: $(OBJDIR)/man/cha-%.md
	pandoc --standalone --to man $< -o $@

.PHONY: clean
clean:
	rm -rf "$(OBJDIR)/$(TARGET)"
	rm -rf "$(QJSOBJ)"
	rm -f lib/libquickjs.a

MANPAGES1 = doc/cha.1 doc/mancha.1
MANPAGES5 = doc/cha-config.5 doc/cha-mailcap.5 doc/cha-mime.types.5 \
	doc/cha-localcgi.5 doc/cha-urimethodmap.5 doc/cha-protocols.5 \
	doc/cha-api.5

MANPAGES = $(MANPAGES1) $(MANPAGES5)

.PHONY: manpage
manpage: $(MANPAGES)

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	install -m755 "$(OUTDIR_BIN)/cha" "$(DESTDIR)$(PREFIX)/bin"
	install -m755 "$(OUTDIR_BIN)/mancha" "$(DESTDIR)$(PREFIX)/bin"
	@# intentionally not quoted
	mkdir -p $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/http" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/about" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/data" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/file" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/ftp" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/gopher" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_LIBEXEC)/gopher2html" $(LIBEXECDIR_CHAWAN)
	install -m755 "$(OUTDIR_LIBEXEC)/md2html" $(LIBEXECDIR_CHAWAN)
	install -m755 "$(OUTDIR_LIBEXEC)/ansi2html" $(LIBEXECDIR_CHAWAN)
	install -m755 "$(OUTDIR_LIBEXEC)/gmi2html" $(LIBEXECDIR_CHAWAN)
	install -m755 "$(OUTDIR_CGI_BIN)/gmifetch" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/cha-finger" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/man" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_CGI_BIN)/spartan" $(LIBEXECDIR_CHAWAN)/cgi-bin
	install -m755 "$(OUTDIR_LIBEXEC)/urldec" $(LIBEXECDIR_CHAWAN)/urldec
	install -m755 "$(OUTDIR_LIBEXEC)/urlenc" $(LIBEXECDIR_CHAWAN)/urlenc
	mkdir -p "$(DESTDIR)$(MANPREFIX1)"
	for f in $(MANPAGES1); do install -m644 "$$f" "$(DESTDIR)$(MANPREFIX1)"; done
	mkdir -p "$(DESTDIR)$(MANPREFIX5)"
	for f in $(MANPAGES5); do install -m644 "$$f" "$(DESTDIR)$(MANPREFIX5)"; done

.PHONY: uninstall
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/cha"
	rm -f "$(DESTDIR)$(PREFIX)/bin/mancha"
	@# intentionally not quoted
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/http
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/about
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/data
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/file
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/ftp
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/gopher
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/gmifetch
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/cha-finger
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/man
	rm -f $(LIBEXECDIR_CHAWAN)/cgi-bin/spartan
	rmdir $(LIBEXECDIR_CHAWAN)/cgi-bin || true
	rm -f $(LIBEXECDIR_CHAWAN)/gopher2html
	rm -f $(LIBEXECDIR_CHAWAN)/md2html
	rm -f $(LIBEXECDIR_CHAWAN)/ansi2html
	rm -f $(LIBEXECDIR_CHAWAN)/gmi2html
	rm -f $(LIBEXECDIR_CHAWAN)/urldec
	rm -f $(LIBEXECDIR_CHAWAN)/urlenc
	rmdir $(LIBEXECDIR_CHAWAN) || true
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-config.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-mailcap.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-mime.types.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-localcgi.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-urimethodmap.5"
	rm -f "$(DESTDIR)$(MANPREFIX5)/cha-cha-protocols.5"
	rm -f "$(DESTDIR)$(MANPREFIX1)/cha.1"
	rm -f "$(DESTDIR)$(MANPREFIX1)/mancha.1"

.PHONY: submodule
submodule:
	git submodule update --init

.PHONY: test
test:
	(cd test/js; ./run_js_tests.sh)
	(cd test/layout; ./run_layout_tests.sh)
