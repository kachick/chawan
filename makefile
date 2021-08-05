NIMC = nim compile
FLAGS = -d:ssl -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) -d:small $(FILES)
small:
	$(NIMC) $(FLAGS) -d:danger $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:full $(FILES)
danger:
	$(NIMC) $(FLAGS) -d:danger -d:full $(FILES)
clean:
	rm ./twt
