NIMC = nim compile
FLAGS = -d:ssl -o:twt -p:src/ -p:. --import:utils/eprint
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release -d:strip $(FILES)
danger:
	$(NIMC) $(FLAGS) -d:danger -d:strip $(FILES)
clean:
	rm ./twt
