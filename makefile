NIMC = nim c
OBJDIR = .obj
FLAGS = --nimcache:$(OBJDIR) -o:cha
FILES = src/main.nim
prefix = /usr/local

$(OBJDIR):
	mkdir -p $(OBJDIR)

debug: $(OBJDIR)
	$(NIMC) $(FLAGS) -d:debug $(FILES)

release: $(OBJDIR)
	$(NIMC) $(FLAGS) -d:release -d:strip -d:lto $(FILES)

release0: $(OBJDIR)
	$(NIMC) $(FLAGS) -d:release $(FILES)

profile: $(OBJDIR)
	$(NIMC) $(FLAGS) --profiler:on --stacktrace:on -d:profile $(FILES)

clean:
	rm -f cha
	rm -rf $(OBJDIR)

install:
	mkdir -p "$(DESTDIR)$(prefix)/bin"
	install -m755 cha "$(DESTDIR)$(prefix)/bin"
