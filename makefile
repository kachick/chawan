NIMC = nim compile
FLAGS = -d:ssl -o:twt
FILES = src/main.nim

debug:
	$(NIMC) $(FLAGS) $(FILES)
release:
	$(NIMC) $(FLAGS) -d:release $(FILES)
danger:
	$(NIMC) $(FLAGS) -d:danger $(FILES)
clean:
	rm ./twt
