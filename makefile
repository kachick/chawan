NIMC = nim c
OBJDIR = .obj
FLAGS = -o:cha
FILES = src/main.nim
prefix = /usr/local

$(OBJDIR):
	mkdir -p $(OBJDIR)/debug
	mkdir -p $(OBJDIR)/release
	mkdir -p $(OBJDIR)/profile

debug: $(OBJDIR)
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/debug -d:debug $(FILES)

release: $(OBJDIR)
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release -d:release -d:strip -d:lto $(FILES)

release0: $(OBJDIR)
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/release -d:release --stacktrace:on $(FILES)

profile: $(OBJDIR)
	$(NIMC) $(FLAGS) --nimcache:$(OBJDIR)/profile --profiler:on --stacktrace:on -d:profile $(FILES)

clean:
	rm -f cha
	rm -rf $(OBJDIR)

install:
	mkdir -p "$(DESTDIR)$(prefix)/bin"
	install -m755 cha "$(DESTDIR)$(prefix)/bin"

uninstall:
	rm -f "$(DESTDIR)$(prefix)/bin/cha"
