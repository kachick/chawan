NIMC = nim c
FLAGS = -o:cha
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) -d:debug $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:strip -d:lto $(FILES)
release0:
	$(NIMC) $(FLAGS) -d:release $(FILES)
profile:
	$(NIMC) $(FLAGS) --profiler:on --stacktrace:on -d:profile $(FILES)
install:
	cp cha /usr/local/bin/
clean:
	rm ./cha
