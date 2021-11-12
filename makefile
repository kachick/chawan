NIMC = nim c
FLAGS = -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:strip -d:ssl -d:lto $(FILES)
install:
	cp twt /usr/local/bin/
clean:
	rm ./twt
