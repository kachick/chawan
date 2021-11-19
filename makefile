NIMC = nim c
FLAGS = -d:ssl -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) -d:debug $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:strip -d:lto $(FILES)
profile:
	$(NIMC) $(FLAGS) --profiler:on --stacktrace:on -d:profile $(FILES)
install:
	cp twt /usr/local/bin/
clean:
	rm ./twt
