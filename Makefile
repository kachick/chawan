NIMC = nim c
OBJDIR = .obj
FLAGS = -o:cha
FILES = src/main.nim
prefix = /usr/local
QJSOBJ = $(OBJDIR)/quickjs
CFLAGS = -g -Wall -O2 -DCONFIG_VERSION=\"$(shell cat lib/quickjs/VERSION)\"

.PHONY: debug
debug: lib/libquickjs.a $(OBJDIR)/debug/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/debug -d:debug $(FILES)

.PHONY: debug0
debug0: lib/libquickjs.a $(OBJDIR)/debug0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release1 -d:debug --stacktrace:off --linetrace:off --opt:speed $(FILES)

.PHONY: release
release: lib/libquickjs.a $(OBJDIR)/release/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release -d:release -d:strip -d:lto $(FILES)

.PHONY: release0
release0: lib/libquickjs.a $(OBJDIR)/release0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release0 -d:release --stacktrace:on $(FILES)

.PHONY: profile
profile: lib/libquickjs.a $(OBJDIR)/profile/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/profile --profiler:on --stacktrace:on -d:profile $(FILES)

.PHONY: profile0
profile0: lib/libquickjs.a $(OBJDIR)/profile0/
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release1 -d:release --passC:"-pg" --passL:"-pg" $(FILES)

$(OBJDIR)/%/:
	mkdir -p $@

$(QJSOBJ)/%.o: lib/quickjs/%.c | $(QJSOBJ)/
	$(CC) $(CFLAGS) -c -o $@ $<

lib/libquickjs.a: $(QJSOBJ)/quickjs.o $(QJSOBJ)/libregexp.o \
		$(QJSOBJ)/libunicode.o $(QJSOBJ)/cutils.o | $(QJSOBJ)/
	$(AR) rcs $@ $^

.PHONY: clean
clean:
	rm -f cha
	rm -rf $(OBJDIR)
	rm -f lib/libquickjs.a

.PHONY: install
install:
	mkdir -p "$(DESTDIR)$(prefix)/bin"
	install -m755 cha "$(DESTDIR)$(prefix)/bin"

.PHONY: uninstall
uninstall:
	rm -f "$(DESTDIR)$(prefix)/bin/cha"


.PHONY: submodule
submodule:
	git submodule update --init
