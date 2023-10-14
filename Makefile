NIMC = nim c
OBJDIR = .obj
FLAGS = -o:cha -d:curlLibName:$(CURLLIBNAME)
FILES = src/main.nim
prefix = /usr/local
manprefix = /usr/local/share/man
manprefix1 = $(manprefix)/man1
manprefix5 = $(manprefix)/man5
QJSOBJ = $(OBJDIR)/quickjs
CFLAGS = -g -Wall -O2 -DCONFIG_VERSION=\"$(shell cat lib/quickjs/VERSION)\" -DCONFIG_BIGNUM=1

.PHONY: debug
debug: lib/libquickjs.a $(OBJDIR)/debug/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/debug --debugger:native -d:debug $(FILES)

.PHONY: debug0
debug0: lib/libquickjs.a $(OBJDIR)/debug0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/debug0 -d:debug --stacktrace:off --linetrace:off --opt:speed $(FILES)

.PHONY: release
release: lib/libquickjs.a $(OBJDIR)/release/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release -d:release -d:strip -d:lto $(FILES)

.PHONY: release0
release0: lib/libquickjs.a $(OBJDIR)/release0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release0 -d:release --stacktrace:on $(FILES)

.PHONY: release1
release1: lib/libquickjs.a $(OBJDIR)/release1/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release1 --debugger:native -d:release $(FILES)

.PHONY: profile
profile: lib/libquickjs.a $(OBJDIR)/profile/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/profile --profiler:on --stacktrace:on -d:profile $(FILES)

.PHONY: profile0
profile0: lib/libquickjs.a $(OBJDIR)/profile0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/profile0 -d:release --passC:"-pg" --passL:"-pg" $(FILES)

$(OBJDIR)/%/:
	mkdir -p $@

$(QJSOBJ)/%.o: lib/quickjs/%.c | $(QJSOBJ)/
	$(CC) $(CFLAGS) -c -o $@ $<

lib/libquickjs.a: $(QJSOBJ)/quickjs.o $(QJSOBJ)/libregexp.o \
		$(QJSOBJ)/libunicode.o $(QJSOBJ)/cutils.o \
		$(QJSOBJ)/libbf.o | $(QJSOBJ)/
	$(AR) rcs $@ $^

.PHONY: clean
clean:
	rm -f cha
	rm -rf $(OBJDIR)
	rm -f lib/libquickjs.a

$(OBJDIR)/man/cha-%.md: doc/%.md | $(OBJDIR)/man/
	./md2manpreproc $< > $@

$(OBJDIR)/man/cha-%.5: $(OBJDIR)/man/cha-%.md | $(OBJDIR)/man/
	pandoc --standalone --to man $< -o $@

$(OBJDIR)/man/cha.1: doc/cha.1 | $(OBJDIR)/man/
	cp doc/cha.1 "$(OBJDIR)/man/cha.1"

.PHONY: manpage
manpage:  $(OBJDIR)/man/cha-config.5 $(OBJDIR)/man/cha-mailcap.5 \
	$(OBJDIR)/man/cha-mime.types.5 $(OBJDIR)/man/cha-localcgi.5 \
	$(OBJDIR)/man/cha-urimethodmap.5 \
	$(OBJDIR)/man/cha.1

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(prefix)/bin"
	install -m755 cha "$(DESTDIR)$(prefix)/bin"
	if test -d "$(OBJDIR)/man"; then \
	mkdir -p "$(DESTDIR)$(manprefix5)"; \
	mkdir -p "$(DESTDIR)$(manprefix1)"; \
	install -m644 "$(OBJDIR)/man/cha-config.5" "$(DESTDIR)$(manprefix5)"; \
	install -m644 "$(OBJDIR)/man/cha-mailcap.5" "$(DESTDIR)$(manprefix5)"; \
	install -m644 "$(OBJDIR)/man/cha-mime.types.5" "$(DESTDIR)$(manprefix5)"; \
	install -m644 "$(OBJDIR)/man/cha-localcgi.5" "$(DESTDIR)$(manprefix5)"; \
	install -m644 "$(OBJDIR)/man/cha-urimethodmap.5" "$(DESTDIR)$(manprefix5)"; \
	install -m644 "$(OBJDIR)/man/cha.1" "$(DESTDIR)$(manprefix1)"; \
	fi

.PHONY: uninstall
uninstall:
	rm -f "$(DESTDIR)$(prefix)/bin/cha"


.PHONY: submodule
submodule:
	git submodule update --init
