NIMC = nim c
FLAGS = -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:strip -d:lto $(FILES)
clean:
	rm ./twt
