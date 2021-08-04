NIMC = nim compile
FLAGS = -d:ssl -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) -d:small $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release $(FILES)
small:
	$(NIMC) $(FLAGS) -d:danger -d:small $(FILES)
danger:
	$(NIMC) $(FLAGS) -d:danger $(FILES)
clean:
	rm ./twt
